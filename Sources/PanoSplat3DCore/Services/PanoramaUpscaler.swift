import CoreGraphics
import CoreML
import CoreVideo
import Foundation

public enum UpscaleFactor: Int, Sendable {
    /// 2× output (native 2× for RealPLKSR 2×, or supersampled 4×→2× for 4× models for crisp, halo-free detail).
    case x2 = 2
    /// Full 4× output (capped at 8192px width).
    case x4 = 4
}

public enum PanoramaUpscalerError: LocalizedError, Sendable {
    case missingInputFeature
    case missingOutputFeature
    case pixelBufferCreationFailed
    case unsupportedFeatureFormat(String)
    case imageConstructionFailed

    public var errorDescription: String? {
        switch self {
        case .missingInputFeature:
            return "CoreML upscaler model has no recognized image/tensor input."
        case .missingOutputFeature:
            return "CoreML upscaler model returned no output image."
        case .pixelBufferCreationFailed:
            return "Failed to allocate CVPixelBuffer for CoreML upscaling."
        case .unsupportedFeatureFormat(let detail):
            return "Unsupported CoreML upscaler input/output format: \(detail)"
        case .imageConstructionFailed:
            return "Failed to construct upscaled panorama CGImage."
        }
    }
}

/// 360°-wrap-safe CoreML super-resolution tiled upscaler supporting `RealPLKSR 2× Natural`,
/// `4xNomosWebPhoto`, and `Real-ESRGAN x4+`, plus circular-wrapped original-grain blending.
///
/// Unlike standard 2D upscalers that create a visible vertical seam along the left/right `0°/360°` border
/// of equirectangular panoramas, `PanoramaUpscaler` wraps horizontal tile extraction, feathered tile
/// blending, and strength-blend bicubic resizing modulo the panorama width so the 360° seam stays seamless.
public final class PanoramaUpscaler: Sendable {
    public let modelManager: UpscalerModelManager

    public init(modelManager: UpscalerModelManager = UpscalerModelManager()) {
        self.modelManager = modelManager
    }

    /// Computes horizontal (circularly wrapped) and vertical (clamped) tile origins covering `(width, height)`.
    public static func computeTileOrigins(
        width: Int,
        height: Int,
        tileSize: Int,
        overlap: Int
    ) -> (xOrigins: [Int], yOrigins: [Int]) {
        let step = max(1, tileSize - overlap)

        // Horizontal origins wrap seamlessly around 360° (including a tile straddling x = 0 / x = width)
        var xOrigins: [Int] = []
        if width <= tileSize {
            xOrigins = [0]
        } else {
            let count = Int(ceil(Double(width) / Double(step)))
            let evenStep = Double(width) / Double(count)
            for i in 0..<count {
                xOrigins.append(Int((Double(i) * evenStep).rounded()))
            }
        }

        // Vertical origins clamp cleanly to [0, max(0, height - tileSize)]
        var yOrigins: [Int] = []
        if height <= tileSize {
            yOrigins = [0]
        } else {
            var y = 0
            while y + tileSize < height {
                yOrigins.append(y)
                y += step
            }
            let lastY = max(0, height - tileSize)
            if yOrigins.last != lastY {
                yOrigins.append(lastY)
            }
        }

        return (xOrigins, yOrigins)
    }

    /// Extracts a `tileSize × tileSize` RGBA8 tile from a `width × height` panorama with
    /// **circular horizontal 360° wrap** and vertical pole clamping.
    public static func extractWrappedTile(
        from srcRGBA: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        originX: Int,
        originY: Int,
        tileSize: Int
    ) -> [UInt8] {
        var tile = [UInt8](repeating: 255, count: tileSize * tileSize * 4)
        for ty in 0..<tileSize {
            let sy = min(max(originY + ty, 0), srcHeight - 1)
            let dstRow = ty * tileSize
            let srcRow = sy * srcWidth
            for tx in 0..<tileSize {
                let sx = ((originX + tx) % srcWidth + srcWidth) % srcWidth
                let srcOff = (srcRow + sx) * 4
                let dstOff = (dstRow + tx) * 4
                tile[dstOff] = srcRGBA[srcOff]
                tile[dstOff + 1] = srcRGBA[srcOff + 1]
                tile[dstOff + 2] = srcRGBA[srcOff + 2]
                tile[dstOff + 3] = 255
            }
        }
        return tile
    }

    /// Blends an upscaled tile (`outTileSize × outTileSize`) into an `outWidth × outHeight`
    /// floating-point RGBA accumulator with **circular horizontal 360° wrap** and raised-cosine edge feathering.
    public static func blendWrappedTile(
        tileRGBA: [UInt8],
        outTileSize: Int,
        originOutX: Int,
        originOutY: Int,
        outWidth: Int,
        outHeight: Int,
        featherPixels: Int,
        isTopBoundary: Bool,
        isBottomBoundary: Bool,
        accumRGB: inout [Float],
        accumWeight: inout [Float]
    ) {
        let feather = Float(max(featherPixels, 1))

        var wx = [Float](repeating: 1.0, count: outTileSize)
        var wy = [Float](repeating: 1.0, count: outTileSize)

        for i in 0..<outTileSize {
            let distLeft = Float(i) + 0.5
            let distRight = Float(outTileSize - 1 - i) + 0.5
            let edgeX = min(distLeft, distRight)
            if edgeX < feather {
                let t = edgeX / feather
                wx[i] = max(0.01, 0.5 - 0.5 * cos(t * .pi))
            }

            let distTop = isTopBoundary ? feather : (Float(i) + 0.5)
            let distBottom = isBottomBoundary ? feather : (Float(outTileSize - 1 - i) + 0.5)
            let edgeY = min(distTop, distBottom)
            if edgeY < feather {
                let t = edgeY / feather
                wy[i] = max(0.01, 0.5 - 0.5 * cos(t * .pi))
            }
        }

        for ty in 0..<outTileSize {
            let dy = originOutY + ty
            guard dy >= 0 && dy < outHeight else { continue }
            let weightY = wy[ty]
            let tileRow = ty * outTileSize
            let dstRow = dy * outWidth

            for tx in 0..<outTileSize {
                let dx = ((originOutX + tx) % outWidth + outWidth) % outWidth
                let w = wx[tx] * weightY
                let tileOff = (tileRow + tx) * 4
                let dstIdx = dstRow + dx
                let dstRGB = dstIdx * 3

                accumRGB[dstRGB] += Float(tileRGBA[tileOff]) * w
                accumRGB[dstRGB + 1] += Float(tileRGBA[tileOff + 1]) * w
                accumRGB[dstRGB + 2] += Float(tileRGBA[tileOff + 2]) * w
                accumWeight[dstIdx] += w
            }
        }
    }

    /// Performs a **360°-wrap-safe** high-quality resize of `srcRGBA` (`srcWidth × srcHeight`) to
    /// `dstWidth × dstHeight` by horizontally padding modulo `srcWidth` before resampling and cropping back.
    public static func resizeWrappedRGBA(
        _ srcRGBA: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) throws -> [UInt8] {
        if srcWidth == dstWidth && srcHeight == dstHeight {
            return srcRGBA
        }

        let padSrc = min(16, max(4, srcWidth / 16))
        let paddedSrcW = srcWidth + 2 * padSrc
        var paddedSrc = [UInt8](repeating: 255, count: paddedSrcW * srcHeight * 4)

        for y in 0..<srcHeight {
            let srcRow = y * srcWidth
            let dstRow = y * paddedSrcW
            for px in 0..<paddedSrcW {
                let sx = ((px - padSrc) % srcWidth + srcWidth) % srcWidth
                let sOff = (srcRow + sx) * 4
                let dOff = (dstRow + px) * 4
                paddedSrc[dOff] = srcRGBA[sOff]
                paddedSrc[dOff + 1] = srcRGBA[sOff + 1]
                paddedSrc[dOff + 2] = srcRGBA[sOff + 2]
                paddedSrc[dOff + 3] = 255
            }
        }

        let scaleX = Double(dstWidth) / Double(srcWidth)
        let padDst = Int((Double(padSrc) * scaleX).rounded())
        let paddedDstW = dstWidth + 2 * padDst

        let paddedCG = try makeCGImage(rgbaBytes: paddedSrc, width: paddedSrcW, height: srcHeight)
        let resizedPaddedCG = try resizeCGImage(paddedCG, width: paddedDstW, height: dstHeight)
        let resizedPaddedRGBA = PanoramaLoader.extractRGBA8Bytes(from: resizedPaddedCG)

        var cropped = [UInt8](repeating: 255, count: dstWidth * dstHeight * 4)
        for y in 0..<dstHeight {
            let srcRowOffset = (y * paddedDstW + padDst) * 4
            let dstRowOffset = (y * dstWidth) * 4
            cropped.replaceSubrange(
                dstRowOffset..<(dstRowOffset + dstWidth * 4),
                with: resizedPaddedRGBA[srcRowOffset..<(srcRowOffset + dstWidth * 4)]
            )
        }
        return cropped
    }

    /// Blends an AI-upscaled panorama with a 360°-wrap-safe bicubic resize of the original panorama.
    /// `strength = 1.0` returns 100% AI output; `strength = 0.0` returns 100% bicubic original;
    /// `0.75–0.85` preserves AI sharpness while dialing back waxy/plastic smoothing.
    public static func blendWithOriginal(
        aiRGBA: [UInt8],
        originalRGBA: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int,
        strength: Double
    ) throws -> [UInt8] {
        let s = min(max(strength, 0.0), 1.0)
        if s >= 0.999 {
            return aiRGBA
        }

        let baseRGBA = try resizeWrappedRGBA(
            originalRGBA,
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            dstWidth: dstWidth,
            dstHeight: dstHeight
        )
        if s <= 0.001 {
            return baseRGBA
        }

        let sf = Float(s)
        let invSf = 1.0 - sf
        let count = dstWidth * dstHeight
        var blended = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            let off = i * 4
            blended[off] = UInt8(min(max((Float(aiRGBA[off]) * sf + Float(baseRGBA[off]) * invSf).rounded(), 0), 255))
            blended[off + 1] = UInt8(min(max((Float(aiRGBA[off + 1]) * sf + Float(baseRGBA[off + 1]) * invSf).rounded(), 0), 255))
            blended[off + 2] = UInt8(min(max((Float(aiRGBA[off + 2]) * sf + Float(baseRGBA[off + 2]) * invSf).rounded(), 0), 255))
            blended[off + 3] = 255
        }
        return blended
    }

    /// Upscales a `PanoramaAsset` using the selected CoreML `UpscalerModelVariant` with seamless 360°
    /// horizontal wrap tiling and optional original-grain strength blending.
    public func upscale(
        panorama: PanoramaAsset,
        variant: UpscalerModelVariant = .realPLKSR2xNatural,
        factor: UpscaleFactor = .x2,
        blendStrength: Double = 0.80,
        onModelStateChange: @Sendable (UpscalerModelState) -> Void = { _ in },
        onProgress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> PanoramaAsset {
        onProgress(0.02, "Loading \(variant.displayName)...")
        let loaded = try await modelManager.loadOrDownloadModel(
            variant: variant,
            onStateChange: onModelStateChange
        )
        let model = loaded.model

        let ioSpec = try inspectModelIO(model: model, fallbackScale: variant.nativeScale)
        let tileSize = ioSpec.inputSize
        let modelScale = ioSpec.scaleFactor
        let outTileSize = tileSize * modelScale
        let overlap = max(16, min(32, tileSize / 8))

        let srcW = panorama.width
        let srcH = panorama.height
        let srcRGBA = PanoramaLoader.extractRGBA8Bytes(from: panorama.cgImage)

        let fullOutW = srcW * modelScale
        let fullOutH = srcH * modelScale

        let (xOrigins, yOrigins) = Self.computeTileOrigins(
            width: srcW,
            height: srcH,
            tileSize: tileSize,
            overlap: overlap
        )

        let totalTiles = xOrigins.count * yOrigins.count
        var accumRGB = [Float](repeating: 0, count: fullOutW * fullOutH * 3)
        var accumWeight = [Float](repeating: 0, count: fullOutW * fullOutH)
        let featherOut = overlap * modelScale

        var completedTiles = 0
        for oy in yOrigins {
            let isTop = (oy == 0)
            let isBottom = (oy + tileSize >= srcH)

            for ox in xOrigins {
                try Task.checkCancellation()

                let tileRGBA = Self.extractWrappedTile(
                    from: srcRGBA,
                    srcWidth: srcW,
                    srcHeight: srcH,
                    originX: ox,
                    originY: oy,
                    tileSize: tileSize
                )

                let upscaledTileRGBA = try await runTileInference(
                    model: model,
                    ioSpec: ioSpec,
                    tileRGBA: tileRGBA,
                    tileSize: tileSize,
                    outTileSize: outTileSize
                )

                Self.blendWrappedTile(
                    tileRGBA: upscaledTileRGBA,
                    outTileSize: outTileSize,
                    originOutX: ox * modelScale,
                    originOutY: oy * modelScale,
                    outWidth: fullOutW,
                    outHeight: fullOutH,
                    featherPixels: featherOut,
                    isTopBoundary: isTop,
                    isBottomBoundary: isBottom,
                    accumRGB: &accumRGB,
                    accumWeight: &accumWeight
                )

                completedTiles += 1
                let frac = 0.05 + 0.83 * (Double(completedTiles) / Double(max(totalTiles, 1)))
                onProgress(frac, "\(variant.shortBadgeName) tile \(completedTiles) / \(totalTiles)...")
            }
        }

        try Task.checkCancellation()
        onProgress(0.90, "Finalizing seamless upscaled 360° panorama...")

        // Resolve normalized RGBA8 bytes at full native model resolution
        var outRGBA = [UInt8](repeating: 255, count: fullOutW * fullOutH * 4)
        for i in 0..<(fullOutW * fullOutH) {
            let w = max(accumWeight[i], 1e-5)
            let rgbOff = i * 3
            let dstOff = i * 4
            outRGBA[dstOff] = UInt8(min(max((accumRGB[rgbOff] / w).rounded(), 0), 255))
            outRGBA[dstOff + 1] = UInt8(min(max((accumRGB[rgbOff + 1] / w).rounded(), 0), 255))
            outRGBA[dstOff + 2] = UInt8(min(max((accumRGB[rgbOff + 2] / w).rounded(), 0), 255))
            outRGBA[dstOff + 3] = 255
        }

        // Target output dimensions (2× or 4× capped at 8192px wide)
        let targetWidth = min(srcW * factor.rawValue, 8192)
        let targetHeight = max(1, Int((Double(srcH) * (Double(targetWidth) / Double(srcW))).rounded()))

        let aiTargetRGBA: [UInt8]
        if targetWidth == fullOutW && targetHeight == fullOutH {
            aiTargetRGBA = outRGBA
        } else {
            onProgress(0.93, "Supersampling \(fullOutW)×\(fullOutH) → \(targetWidth)×\(targetHeight) (360° wrap-safe)...")
            aiTargetRGBA = try Self.resizeWrappedRGBA(
                outRGBA,
                srcWidth: fullOutW,
                srcHeight: fullOutH,
                dstWidth: targetWidth,
                dstHeight: targetHeight
            )
        }

        let clampedStrength = min(max(blendStrength, 0.0), 1.0)
        let finalRGBA: [UInt8]
        if clampedStrength < 0.999 {
            onProgress(0.96, "Blending \(Int((clampedStrength * 100).rounded()))% AI detail with natural base...")
            finalRGBA = try Self.blendWithOriginal(
                aiRGBA: aiTargetRGBA,
                originalRGBA: srcRGBA,
                srcWidth: srcW,
                srcHeight: srcH,
                dstWidth: targetWidth,
                dstHeight: targetHeight,
                strength: clampedStrength
            )
        } else {
            finalRGBA = aiTargetRGBA
        }

        let finalImage = try Self.makeCGImage(rgbaBytes: finalRGBA, width: targetWidth, height: targetHeight)

        let thumbnail = (try? Self.resizeCGImage(
            finalImage,
            width: min(targetWidth, 1024),
            height: max(1, Int((Double(targetHeight) * (Double(min(targetWidth, 1024)) / Double(targetWidth))).rounded()))
        )) ?? finalImage

        onProgress(1.0, "Upscaled to \(targetWidth) × \(targetHeight)")

        return PanoramaAsset(
            sourceURL: panorama.sourceURL,
            width: targetWidth,
            height: targetHeight,
            isHDR: panorama.isHDR,
            fileSizeBytes: panorama.fileSizeBytes,
            cgImage: finalImage,
            thumbnail: thumbnail
        )
    }

    // MARK: - CoreML Input/Output Introspection & Inference

    private struct ModelIOSpec {
        let inputName: String
        let inputIsImage: Bool
        let inputSize: Int
        let outputName: String
        let scaleFactor: Int
    }

    private func inspectModelIO(model: MLModel, fallbackScale: Int) throws -> ModelIOSpec {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName

        guard let outputEntry = outputs.first else {
            throw PanoramaUpscalerError.missingOutputFeature
        }
        let outputName = outputEntry.key
        let outputWidth: Int?
        if let imgConstraint = outputEntry.value.imageConstraint {
            outputWidth = imgConstraint.pixelsWide
        } else if let shape = outputEntry.value.multiArrayConstraint?.shape, shape.count >= 2 {
            let lastDim = shape.last!.intValue
            outputWidth = lastDim > 0 ? lastDim : nil
        } else {
            outputWidth = nil
        }

        if let imageInput = inputs.first(where: { $0.value.type == .image }) {
            let inW = imageInput.value.imageConstraint?.pixelsWide ?? 512
            let scale = outputWidth.map { max(1, $0 / max(inW, 1)) } ?? fallbackScale
            return ModelIOSpec(
                inputName: imageInput.key,
                inputIsImage: true,
                inputSize: inW,
                outputName: outputName,
                scaleFactor: scale
            )
        }

        if let arrayInput = inputs.first(where: { $0.value.type == .multiArray }) {
            let shape = arrayInput.value.multiArrayConstraint?.shape ?? []
            let rawW = shape.last?.intValue ?? 512
            let inW = rawW > 0 ? rawW : 512
            let scale = outputWidth.map { max(1, $0 / max(inW, 1)) } ?? fallbackScale
            return ModelIOSpec(
                inputName: arrayInput.key,
                inputIsImage: false,
                inputSize: inW,
                outputName: outputName,
                scaleFactor: scale
            )
        }

        throw PanoramaUpscalerError.missingInputFeature
    }

    private func runTileInference(
        model: MLModel,
        ioSpec: ModelIOSpec,
        tileRGBA: [UInt8],
        tileSize: Int,
        outTileSize: Int
    ) async throws -> [UInt8] {
        let inputFeature: MLFeatureValue
        if ioSpec.inputIsImage {
            let pb = try Self.makeBGRA32PixelBuffer(fromRGBA: tileRGBA, width: tileSize, height: tileSize)
            inputFeature = MLFeatureValue(pixelBuffer: pb)
        } else {
            let arr = try MLMultiArray(
                shape: [1, 3, NSNumber(value: tileSize), NSNumber(value: tileSize)],
                dataType: .float32
            )
            let strides = arr.strides.map(\.intValue)
            let cStride = strides[1]
            let yStride = strides[2]
            let xStride = strides[3]
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<tileSize {
                let rowBase = y * yStride
                let srcRow = y * tileSize
                for x in 0..<tileSize {
                    let sOff = (srcRow + x) * 4
                    let xy = rowBase + x * xStride
                    ptr[xy] = Float32(tileRGBA[sOff]) / 255.0
                    ptr[cStride + xy] = Float32(tileRGBA[sOff + 1]) / 255.0
                    ptr[2 * cStride + xy] = Float32(tileRGBA[sOff + 2]) / 255.0
                }
            }
            inputFeature = MLFeatureValue(multiArray: arr)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [ioSpec.inputName: inputFeature])
        let prediction = try await model.prediction(from: provider)

        guard let outFeature = prediction.featureValue(for: ioSpec.outputName) else {
            throw PanoramaUpscalerError.missingOutputFeature
        }

        if let outPB = outFeature.imageBufferValue {
            return try Self.extractRGBA8(fromPixelBuffer: outPB, expectedWidth: outTileSize, expectedHeight: outTileSize)
        }
        if let outArray = outFeature.multiArrayValue {
            return try Self.extractRGBA8(fromMultiArray: outArray, width: outTileSize, height: outTileSize)
        }

        throw PanoramaUpscalerError.unsupportedFeatureFormat("\(outFeature.type)")
    }

    private static func makeBGRA32PixelBuffer(fromRGBA rgba: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let pb = pbOut else {
            throw PanoramaUpscalerError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw PanoramaUpscalerError.pixelBufferCreationFailed
        }

        let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let dstRow = base.advanced(by: y * dstRowBytes).assumingMemoryBound(to: UInt8.self)
            let srcRowOffset = y * width * 4
            for x in 0..<width {
                let s = srcRowOffset + x * 4
                let d = x * 4
                dstRow[d] = rgba[s + 2]     // B
                dstRow[d + 1] = rgba[s + 1] // G
                dstRow[d + 2] = rgba[s]     // R
                dstRow[d + 3] = 255         // A
            }
        }
        return pb
    }

    private static func extractRGBA8(fromPixelBuffer pb: CVPixelBuffer, expectedWidth: Int, expectedHeight: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)

        guard w == expectedWidth, h == expectedHeight,
              let base = CVPixelBufferGetBaseAddress(pb) else {
            throw PanoramaUpscalerError.unsupportedFeatureFormat("PixelBuffer size \(w)x\(h) format \(format)")
        }

        var out = [UInt8](repeating: 255, count: w * h * 4)
        let isBGRA = (format == kCVPixelFormatType_32BGRA)
        let isARGB = (format == kCVPixelFormatType_32ARGB)

        for y in 0..<h {
            let srcRow = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            let dstRowOffset = y * w * 4
            for x in 0..<w {
                let s = x * 4
                let d = dstRowOffset + x * 4
                if isBGRA {
                    out[d] = srcRow[s + 2]
                    out[d + 1] = srcRow[s + 1]
                    out[d + 2] = srcRow[s]
                    out[d + 3] = 255
                } else if isARGB {
                    out[d] = srcRow[s + 1]
                    out[d + 1] = srcRow[s + 2]
                    out[d + 2] = srcRow[s + 3]
                    out[d + 3] = 255
                } else {
                    out[d] = srcRow[s]
                    out[d + 1] = srcRow[s + 1]
                    out[d + 2] = srcRow[s + 2]
                    out[d + 3] = 255
                }
            }
        }
        return out
    }

    private static func extractRGBA8(fromMultiArray arr: MLMultiArray, width: Int, height: Int) throws -> [UInt8] {
        let shape = arr.shape.map(\.intValue)
        let strides = arr.strides.map(\.intValue)

        let cStride: Int
        let yStride: Int
        let xStride: Int

        if shape.count == 4 && strides.count == 4 {
            cStride = strides[1]
            yStride = strides[2]
            xStride = strides[3]
        } else if shape.count == 3 && strides.count == 3 {
            cStride = strides[0]
            yStride = strides[1]
            xStride = strides[2]
        } else {
            throw PanoramaUpscalerError.unsupportedFeatureFormat("Unexpected MLMultiArray shape \(shape)")
        }

        var out = [UInt8](repeating: 255, count: width * height * 4)

        // Probe a coarse grid once to determine whether the tensor is normalized [0, 1] or [0, 255].
        func detectScaleFactor(read: (Int) -> Float) -> Float {
            var maxSeen: Float = 0
            let stepY = max(1, height / 16)
            let stepX = max(1, width / 16)
            for y in stride(from: 0, to: height, by: stepY) {
                let rowBase = y * yStride
                for x in stride(from: 0, to: width, by: stepX) {
                    let xy = rowBase + x * xStride
                    maxSeen = max(maxSeen, read(xy), read(cStride + xy), read(2 * cStride + xy))
                }
            }
            return maxSeen <= 2.5 ? 255.0 : 1.0
        }

        switch arr.dataType {
        case .float16:
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            let scale = detectScaleFactor { Float(ptr[$0]) }
            for y in 0..<height {
                let rowBase = y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    let xy = rowBase + x * xStride
                    let d = (dstRow + x) * 4
                    out[d] = UInt8(min(max((Float(ptr[xy]) * scale).rounded(), 0), 255))
                    out[d + 1] = UInt8(min(max((Float(ptr[cStride + xy]) * scale).rounded(), 0), 255))
                    out[d + 2] = UInt8(min(max((Float(ptr[2 * cStride + xy]) * scale).rounded(), 0), 255))
                    out[d + 3] = 255
                }
            }
        case .float32:
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            let scale = detectScaleFactor { ptr[$0] }
            for y in 0..<height {
                let rowBase = y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    let xy = rowBase + x * xStride
                    let d = (dstRow + x) * 4
                    out[d] = UInt8(min(max((ptr[xy] * scale).rounded(), 0), 255))
                    out[d + 1] = UInt8(min(max((ptr[cStride + xy] * scale).rounded(), 0), 255))
                    out[d + 2] = UInt8(min(max((ptr[2 * cStride + xy] * scale).rounded(), 0), 255))
                    out[d + 3] = 255
                }
            }
        default:
            let scale = detectScaleFactor { arr[$0].floatValue }
            for y in 0..<height {
                let rowBase = y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    let xy = rowBase + x * xStride
                    let d = (dstRow + x) * 4
                    out[d] = UInt8(min(max((arr[xy].floatValue * scale).rounded(), 0), 255))
                    out[d + 1] = UInt8(min(max((arr[cStride + xy].floatValue * scale).rounded(), 0), 255))
                    out[d + 2] = UInt8(min(max((arr[2 * cStride + xy].floatValue * scale).rounded(), 0), 255))
                    out[d + 3] = 255
                }
            }
        }
        return out
    }

    private static func makeCGImage(rgbaBytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let img = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        return img
    }

    private static func resizeCGImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info
        ) else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = ctx.makeImage() else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        return resized
    }
}
