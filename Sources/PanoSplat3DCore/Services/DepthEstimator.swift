import CoreGraphics
import CoreML
import CoreVideo
import Foundation

public enum DepthEstimatorError: LocalizedError, Sendable {
    case missingInputFeatureDescription
    case missingOutputFeatureDescription
    case pixelBufferCreationFailed
    case unsupportedOutputFeatureType(String)

    public var errorDescription: String? {
        switch self {
        case .missingInputFeatureDescription:
            return "CoreML depth model has no image input feature."
        case .missingOutputFeatureDescription:
            return "CoreML depth model returned no depth output."
        case .pixelBufferCreationFailed:
            return "Failed to allocate CVPixelBuffer for CoreML depth inference."
        case .unsupportedOutputFeatureType(let detail):
            return "Unsupported CoreML depth output format: \(detail)"
        }
    }
}

/// Runs seamless 360° monocular depth estimation on Apple Silicon using CoreML `DepthAnythingV2SmallF16.mlpackage`.
public final class DepthEstimator: Sendable {
    public let modelManager: DepthModelManager
    private let slicer: EquirectangularSlicer

    public init(
        modelManager: DepthModelManager = DepthModelManager(),
        slicer: EquirectangularSlicer = EquirectangularSlicer()
    ) {
        self.modelManager = modelManager
        self.slicer = slicer
    }

    /// Estimates a seamless 2:1 equirectangular metric depth map `R(u, v)` from an equirectangular panorama:
    /// 1. Slices 12 overlapping `105°` FOV horizon-anchored perspective faces via Metal.
    /// 2. Runs the selected CoreML depth model (`DepthAnythingV2Small`, `DepthAnythingV3Base`, or `AppleDepthPro`) on each face.
    /// 3. Converts direct-depth models (such as DA3) into disparity space, aligns scale/shift via global-mean least-squares,
    ///    and applies RGB-guided joint bilateral edge snapping.
    public func estimate360Depth(
        from panorama: PanoramaAsset,
        variant: DepthModelVariant = .depthAnythingV2Small,
        depthScaleMeters: Double,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        onModelStateChange: @Sendable (DepthModelState) -> Void = { _ in },
        onProgress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> EquirectangularDepthMap {
        let resolvedOutW = outputWidth ?? variant.recommendedStitchedSize.width
        let resolvedOutH = outputHeight ?? variant.recommendedStitchedSize.height

        // 1. Load (or auto-download & compile) selected CoreML depth model
        onProgress(0.05, "Loading \(variant.displayName)...")
        let loadedModel = try await modelManager.loadOrDownloadModel(variant: variant, onStateChange: onModelStateChange)
        let model = loadedModel.model

        // Inspect input image constraint dynamically (518×392 for V2, 504×504 for V3, 1536×1536 for Depth Pro)
        let (inputName, inputWidth, inputHeight) = try inspectInputDescription(model: model)
        let outputName = try inspectOutputName(model: model)

        // 2. Slice horizon-anchored overlapping perspective faces via Metal GPU
        let samplingFaces = variant.samplingFaces
        let faceFOV = samplingFaces.first?.fovDegrees ?? 105.0
        let faceRenderSize = max(inputWidth, inputHeight)
        let faceIntrinsics = PinholeCameraIntrinsics(
            cameraID: 100,
            width: faceRenderSize,
            height: faceRenderSize,
            fovDegrees: faceFOV
        )
        let facePoses = samplingFaces.map { $0.makeCameraPose(cameraID: 100) }

        onProgress(0.15, "Slicing \(samplingFaces.count) wide-overlap \(Int(faceFOV))° faces (\(faceRenderSize)×\(faceRenderSize))...")
        var slicedFaceImages: [CGImage] = []
        slicedFaceImages.reserveCapacity(samplingFaces.count)

        try slicer.sliceViews(
            from: panorama.cgImage,
            poses: facePoses,
            intrinsics: faceIntrinsics
        ) { _, _, image in
            try Task.checkCancellation()
            slicedFaceImages.append(image)
        }

        // 3. Run CoreML inference on each of the 12 overlapping faces
        var faceDisparities: [CubemapFaceDisparity] = []
        faceDisparities.reserveCapacity(samplingFaces.count)

        for index in 0..<samplingFaces.count {
            try Task.checkCancellation()
            let faceSpec = samplingFaces[index]
            let fraction = 0.22 + 0.58 * (Double(index) / Double(samplingFaces.count))
            onProgress(fraction, "\(variant.displayName): \(faceSpec.label) (\(index + 1)/\(samplingFaces.count))...")

            let pixelBuffer = try makePixelBuffer(
                from: slicedFaceImages[index],
                width: inputWidth,
                height: inputHeight
            )

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
            ])
            let prediction = try await model.prediction(from: provider)

            guard let outputValue = prediction.featureValue(for: outputName) else {
                throw DepthEstimatorError.missingOutputFeatureDescription
            }

            let (depthW, depthH, rawValues) = try extractFloatValues(from: outputValue)
            let disparityValues = Self.normalizeToDisparity(rawValues, polarity: variant.outputPolarity)

            faceDisparities.append(
                CubemapFaceDisparity(
                    faceIndex: faceSpec.index,
                    pose: facePoses[index],
                    fovDegrees: faceSpec.fovDegrees,
                    width: depthW,
                    height: depthH,
                    values: disparityValues
                )
            )
        }

        // 4. Least-squares edge alignment & seamless equirectangular blending
        try Task.checkCancellation()
        onProgress(0.84, "Aligning overlapping seams & stitching 360° metric depth...")
        let rawDepthMap = DepthStitcher.stitch(
            faces: faceDisparities,
            outputWidth: resolvedOutW,
            outputHeight: resolvedOutH,
            depthScaleMeters: depthScaleMeters
        )

        // 5. RGB-guided joint bilateral edge snapping (gentler 1-pass for 1536px Depth Pro, 2-pass for 504/518px models)
        try Task.checkCancellation()
        onProgress(0.93, "Snapping depth edges to RGB silhouettes...")
        let refinePasses = (variant == .appleDepthPro) ? 1 : 2
        let refineRadius = (variant == .appleDepthPro) ? 1 : 2
        let depthMap = DepthEdgeRefiner.refine(
            depthMap: rawDepthMap,
            guidedBy: panorama.cgImage,
            depthScaleMeters: depthScaleMeters,
            passes: refinePasses,
            radius: refineRadius
        )

        onProgress(1.0, String(
            format: "360° depth ready (%.1fm – %.1fm)",
            depthMap.minRadiusMeters,
            depthMap.maxRadiusMeters
        ))
        return depthMap
    }

    /// Converts raw model output into disparity (`higher = closer`) regardless of whether the model outputs
    /// disparity directly (DA2 Small, Apple Depth Pro Inverse Depth) or direct positive depth (DA3 Base).
    public static func normalizeToDisparity(_ rawValues: [Float], polarity: DepthOutputPolarity) -> [Float] {
        switch polarity {
        case .disparity:
            return rawValues
        case .depth:
            // Compute robust positive floor (1st percentile) so tiny near-zero depth noise doesn't explode 1/z
            let strideStep = max(1, rawValues.count / 2048)
            var positives: [Float] = []
            positives.reserveCapacity(2048)
            var idx = 0
            while idx < rawValues.count {
                let v = rawValues[idx]
                if v.isFinite && v > 1e-4 {
                    positives.append(v)
                }
                idx += strideStep
            }
            positives.sort()
            let floorDepth = max(positives.isEmpty ? 0.05 : positives[Int(Double(positives.count - 1) * 0.01)], 1e-3)

            var disp = [Float](repeating: 0, count: rawValues.count)
            for i in 0..<rawValues.count {
                let z = rawValues[i]
                if z.isFinite && z > 0 {
                    disp[i] = 1.0 / max(z, floorDepth)
                } else {
                    disp[i] = 0
                }
            }
            return disp
        }
    }

    private func inspectInputDescription(model: MLModel) throws -> (name: String, width: Int, height: Int) {
        let inputs = model.modelDescription.inputDescriptionsByName
        if let imageEntry = inputs.first(where: { $0.value.type == .image }) {
            let width = imageEntry.value.imageConstraint?.pixelsWide ?? 518
            let height = imageEntry.value.imageConstraint?.pixelsHigh ?? 392
            return (imageEntry.key, width, height)
        }
        throw DepthEstimatorError.missingInputFeatureDescription
    }

    private func inspectOutputName(model: MLModel) throws -> String {
        let outputs = model.modelDescription.outputDescriptionsByName
        for preferred in ["depth", "normalizedInverseDepth", "depthMeters", "disparity"] {
            if outputs[preferred] != nil {
                return preferred
            }
        }
        if let first = outputs.first {
            return first.key
        }
        throw DepthEstimatorError.missingOutputFeatureDescription
    }

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw DepthEstimatorError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthEstimatorError.pixelBufferCreationFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw DepthEstimatorError.pixelBufferCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func extractFloatValues(from featureValue: MLFeatureValue) throws -> (width: Int, height: Int, values: [Float]) {
        if let pixelBuffer = featureValue.imageBufferValue {
            return try extractFloatDisparity(from: pixelBuffer)
        }
        if let multiArray = featureValue.multiArrayValue {
            return try extractFloatDisparity(from: multiArray)
        }
        throw DepthEstimatorError.unsupportedOutputFeatureType("\(featureValue.type)")
    }

    private func extractFloatDisparity(from pixelBuffer: CVPixelBuffer) throws -> (width: Int, height: Int, values: [Float]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthEstimatorError.unsupportedOutputFeatureType("Empty CVPixelBuffer base address")
        }

        var output = [Float](repeating: 0, count: width * height)

        switch pixelFormat {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            for y in 0..<height {
                let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float16.self)
                let dstOffset = y * width
                for x in 0..<width {
                    output[dstOffset + x] = Float(rowPtr[x])
                }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            for y in 0..<height {
                let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let dstOffset = y * width
                for x in 0..<width {
                    output[dstOffset + x] = rowPtr[x]
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let dstOffset = y * width
                for x in 0..<width {
                    output[dstOffset + x] = Float(rowPtr[x]) / 255.0
                }
            }
        default:
            throw DepthEstimatorError.unsupportedOutputFeatureType("CVPixelFormat \(pixelFormat)")
        }

        return (width, height, output)
    }

    private func extractFloatDisparity(from multiArray: MLMultiArray) throws -> (width: Int, height: Int, values: [Float]) {
        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        guard shape.count >= 2, strides.count == shape.count else {
            throw DepthEstimatorError.unsupportedOutputFeatureType("Unexpected MLMultiArray shape \(shape)")
        }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2]
        let colStride = strides[strides.count - 1]
        var output = [Float](repeating: 0, count: width * height)

        switch multiArray.dataType {
        case .float16:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<height {
                let srcRow = y * rowStride
                let dstRow = y * width
                for x in 0..<width {
                    output[dstRow + x] = Float(ptr[srcRow + x * colStride])
                }
            }
        case .float32:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                let srcRow = y * rowStride
                let dstRow = y * width
                for x in 0..<width {
                    output[dstRow + x] = ptr[srcRow + x * colStride]
                }
            }
        case .double:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Double.self)
            for y in 0..<height {
                let srcRow = y * rowStride
                let dstRow = y * width
                for x in 0..<width {
                    output[dstRow + x] = Float(ptr[srcRow + x * colStride])
                }
            }
        default:
            for y in 0..<height {
                let srcRow = y * rowStride
                let dstRow = y * width
                for x in 0..<width {
                    output[dstRow + x] = multiArray[srcRow + x * colStride].floatValue
                }
            }
        }

        return (width, height, output)
    }
}
