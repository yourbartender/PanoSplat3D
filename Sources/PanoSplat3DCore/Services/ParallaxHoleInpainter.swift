import CoreGraphics
import CoreML
import CoreVideo
import Foundation

public enum ParallaxInpainterError: LocalizedError, Sendable {
    case missingModelFeatures(String)
    case pixelBufferCreationFailed
    case invalidModelOutput

    public var errorDescription: String? {
        switch self {
        case .missingModelFeatures(let detail):
            return "CoreML LaMa model is missing expected input/output features: \(detail)"
        case .pixelBufferCreationFailed:
            return "Failed to allocate CVPixelBuffer for CoreML LaMa inpainting."
        case .invalidModelOutput:
            return "CoreML LaMa model returned an unexpected output format."
        }
    }
}

/// Fills disoccluded black voids behind foreground trees, rocks, and objects in offset parallax views
/// using Samsung AI's native Apple Silicon CoreML `LaMa` (`mlboydaisuke/LaMa-CoreML`, Apache-2.0).
///
/// Only the masked disoccluded holes (plus a 2px fringe cleanup dilation) are composited back onto the
/// original full-resolution perspective view, preserving 100% of sharp visible pixels untouched.
public final class ParallaxHoleInpainter: Sendable {
    public let modelManager: LaMaModelManager

    public init(modelManager: LaMaModelManager = LaMaModelManager()) {
        self.modelManager = modelManager
    }

    /// Preloads (or downloads & compiles) CoreML `LaMa` once before processing a batch of offset parallax views.
    public func prepareModel(
        onStateChange: @Sendable (LaMaModelState) -> Void = { _ in }
    ) async throws -> LoadedLaMaModel {
        try await modelManager.loadOrDownloadModel(onStateChange: onStateChange)
    }

    /// Inpaints all black disoccluded regions (`validMask == 0`) inside `viewImage`, returning a full-resolution
    /// filled RGB image where every valid pixel outside the hole remains bit-exact.
    ///
    /// - Parameters:
    ///   - viewImage: Re-projected offset perspective view (`W × H` RGB).
    ///   - validMask: Brush/COLMAP validity mask (`255 = valid visible pixel`, `0 = disoccluded void`).
    ///   - loadedModel: Preloaded `LoadedLaMaModel` handle.
    ///   - dilationRadius: Pixel dilation applied to the hole mask before LaMa inference so dark 1–2px
    ///     Z-buffer tearing fringes around foreground objects are cleanly replaced.
    /// - Returns: `(filledImage, didFillHoles)` — if the view has `< 0.1%` holes, skips inference cleanly.
    public func fillDisoccludedHoles(
        in viewImage: CGImage,
        validMask: CGImage,
        using loadedModel: LoadedLaMaModel,
        dilationRadius: Int = 1,
        maxFillHoleFraction: Double = 0.18
    ) async throws -> (image: CGImage, didFillHoles: Bool) {
        let width = viewImage.width
        let height = viewImage.height

        let validGray = Self.extractGrayscaleBytes(from: validMask, targetWidth: width, targetHeight: height)
        let (holeMask, holeFraction) = Self.buildDilatedHoleMask(
            validMaskBytes: validGray,
            width: width,
            height: height,
            dilationRadius: dilationRadius
        )

        // Skip LaMa cleanly if the view has practically no holes OR if the hole is too huge (>18% of frame),
        // preventing large multi-view hallucination smudges; huge holes remain safely masked out for Brush.
        guard holeFraction >= 0.001, holeFraction <= maxFillHoleFraction else {
            return (viewImage, false)
        }

        let model = loadedModel.model
        let (imageFeatureName, maskFeatureName, modelW, modelH, maskIsGrayscaleImage) = try Self.inspectInputs(model: model)
        let outputFeatureName = try Self.inspectOutput(model: model)

        let imagePB = try Self.makeRGBAPixelBuffer(from: viewImage, width: modelW, height: modelH)
        let maskFeatureValue: MLFeatureValue
        if maskIsGrayscaleImage {
            let maskPB = try Self.makeGrayscalePixelBuffer(
                fromMaskBytes: holeMask,
                srcWidth: width,
                srcHeight: height,
                dstWidth: modelW,
                dstHeight: modelH
            )
            maskFeatureValue = MLFeatureValue(pixelBuffer: maskPB)
        } else {
            let maskArray = try Self.makeMaskMultiArray(
                fromMaskBytes: holeMask,
                srcWidth: width,
                srcHeight: height,
                dstWidth: modelW,
                dstHeight: modelH
            )
            maskFeatureValue = MLFeatureValue(multiArray: maskArray)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            imageFeatureName: MLFeatureValue(pixelBuffer: imagePB),
            maskFeatureName: maskFeatureValue
        ])
        let prediction = try await model.prediction(from: provider)

        guard let outputValue = prediction.featureValue(for: outputFeatureName) else {
            throw ParallaxInpainterError.invalidModelOutput
        }

        let inpaintedSmall = try Self.extractCGImage(from: outputValue)
        let composited = try Self.compositeInpaintedHoles(
            original: viewImage,
            inpainted: inpaintedSmall,
            holeMaskBytes: holeMask,
            width: width,
            height: height
        )
        return (composited, true)
    }

    // MARK: - Mask & Compositing Math (Unit-Tested Pure Helpers)

    /// Inverts a Brush validity mask (`255 = valid, 0 = hole`) into a LaMa hole mask (`255 = hole, 0 = valid`)
    /// and dilates the hole region by `dilationRadius` pixels using a fast separable Chebyshev box pass.
    public static func buildDilatedHoleMask(
        validMaskBytes: [UInt8],
        width: Int,
        height: Int,
        dilationRadius: Int
    ) -> (holeMask: [UInt8], holeFraction: Double) {
        let count = width * height
        guard count > 0, validMaskBytes.count >= count else {
            return ([], 0.0)
        }

        var rawHole = [UInt8](repeating: 0, count: count)
        var rawHoleCount = 0
        for i in 0..<count {
            if validMaskBytes[i] < 128 {
                rawHole[i] = 255
                rawHoleCount += 1
            }
        }

        let fraction = Double(rawHoleCount) / Double(count)
        guard dilationRadius > 0, rawHoleCount > 0 else {
            return (rawHole, fraction)
        }

        // Separable horizontal then vertical max-filter dilation (O(W*H*r) instead of O(W*H*r^2))
        var temp = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let x0 = max(0, x - dilationRadius)
                let x1 = min(width - 1, x + dilationRadius)
                var m: UInt8 = 0
                for sx in x0...x1 {
                    let v = rawHole[row + sx]
                    if v > m {
                        m = v
                        if m == 255 { break }
                    }
                }
                temp[row + x] = m
            }
        }

        var dilated = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            let y0 = max(0, y - dilationRadius)
            let y1 = min(height - 1, y + dilationRadius)
            let dstRow = y * width
            for x in 0..<width {
                var m: UInt8 = 0
                for sy in y0...y1 {
                    let v = temp[sy * width + x]
                    if v > m {
                        m = v
                        if m == 255 { break }
                    }
                }
                dilated[dstRow + x] = m
            }
        }

        return (dilated, fraction)
    }

    /// Composites ONLY pixels where `holeMaskBytes[i] > 0` from `inpainted` (upsampled smoothly to `width × height`)
    /// back into `original`, leaving every non-hole pixel 100% bit-exact to `original`.
    public static func compositeInpaintedHoles(
        original: CGImage,
        inpainted: CGImage,
        holeMaskBytes: [UInt8],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: original)
        let alignedInpainted = (inpainted.width == width && inpainted.height == height)
            ? inpainted
            : try resizeCGImage(inpainted, width: width, height: height)
        let fillBytes = PanoramaLoader.extractRGBA8Bytes(from: alignedInpainted)

        // Apply a tiny 1-pixel soft feather along the boundary of the dilated hole mask
        var outBytes = origBytes
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let idx = row + x
                let maskVal = holeMaskBytes[idx]
                if maskVal == 0 {
                    continue
                }
                // Soft blend on pixels touching a non-hole neighbor so edges melt smoothly
                let touchesValid =
                    (x > 0 && holeMaskBytes[idx - 1] == 0)
                    || (x + 1 < width && holeMaskBytes[idx + 1] == 0)
                    || (y > 0 && holeMaskBytes[idx - width] == 0)
                    || (y + 1 < height && holeMaskBytes[idx + width] == 0)

                let p = idx * 4
                if touchesValid {
                    // 75% inpainted + 25% original on boundary pixel
                    outBytes[p] = UInt8(clamping: (Int(fillBytes[p]) * 3 + Int(origBytes[p])) / 4)
                    outBytes[p + 1] = UInt8(clamping: (Int(fillBytes[p + 1]) * 3 + Int(origBytes[p + 1])) / 4)
                    outBytes[p + 2] = UInt8(clamping: (Int(fillBytes[p + 2]) * 3 + Int(origBytes[p + 2])) / 4)
                    outBytes[p + 3] = 255
                } else {
                    outBytes[p] = fillBytes[p]
                    outBytes[p + 1] = fillBytes[p + 1]
                    outBytes[p + 2] = fillBytes[p + 2]
                    outBytes[p + 3] = 255
                }
            }
        }

        return try makeRGBA8CGImage(bytes: outBytes, width: width, height: height)
    }

    /// Creates a solid white grayscale mask (`255` everywhere) for views whose holes have been filled by LaMa
    /// so Brush trains solid background Gaussians in those regions.
    public static func makeSolidWhiteMask(width: Int, height: Int) throws -> CGImage {
        let bytes = [UInt8](repeating: 255, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }
        return cgImage
    }

    // MARK: - CoreML Feature Inspection & Buffer Helpers

    private static func inspectInputs(model: MLModel) throws -> (
        imageName: String,
        maskName: String,
        width: Int,
        height: Int,
        maskIsImage: Bool
    ) {
        let inputs = model.modelDescription.inputDescriptionsByName
        let imageEntry = inputs["image"]
            .map { ("image", $0) }
            ?? inputs.first(where: { $0.value.type == .image && !$0.key.lowercased().contains("mask") })
        let maskEntry = inputs["mask"]
            .map { ("mask", $0) }
            ?? inputs.first(where: { $0.key.lowercased().contains("mask") })

        guard let imageEntry, let maskEntry else {
            throw ParallaxInpainterError.missingModelFeatures("Inputs found: \(Array(inputs.keys))")
        }

        let w = imageEntry.1.imageConstraint?.pixelsWide ?? 800
        let h = imageEntry.1.imageConstraint?.pixelsHigh ?? 800
        let maskIsImage = (maskEntry.1.type == .image)
        return (imageEntry.0, maskEntry.0, w, h, maskIsImage)
    }

    private static func inspectOutput(model: MLModel) throws -> String {
        let outputs = model.modelDescription.outputDescriptionsByName
        for preferred in ["output", "image", "inpainted", "out"] {
            if outputs[preferred] != nil { return preferred }
        }
        if let first = outputs.first {
            return first.key
        }
        throw ParallaxInpainterError.missingModelFeatures("No output features")
    }

    private static func extractGrayscaleBytes(from image: CGImage, targetWidth: Int, targetHeight: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress,
               let ctx = CGContext(
                data: base,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
               ) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            }
        }
        return bytes
    }

    private static func makeRGBAPixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut)
        guard status == kCVReturnSuccess, let pb = pbOut else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    private static func makeGrayscalePixelBuffer(
        fromMaskBytes maskBytes: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, dstWidth, dstHeight, kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &pbOut)
        guard status == kCVReturnSuccess, let pb = pbOut else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let dstPtr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<dstHeight {
            let sy = min(srcHeight - 1, Int((Double(y) + 0.5) * Double(srcHeight) / Double(dstHeight)))
            let srcRow = sy * srcWidth
            let dstRow = y * bytesPerRow
            for x in 0..<dstWidth {
                let sx = min(srcWidth - 1, Int((Double(x) + 0.5) * Double(srcWidth) / Double(dstWidth)))
                dstPtr[dstRow + x] = maskBytes[srcRow + sx] >= 128 ? 255 : 0
            }
        }
        return pb
    }

    private static func makeMaskMultiArray(
        fromMaskBytes maskBytes: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: dstHeight), NSNumber(value: dstWidth)], dataType: .float32)
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        for y in 0..<dstHeight {
            let sy = min(srcHeight - 1, Int((Double(y) + 0.5) * Double(srcHeight) / Double(dstHeight)))
            let srcRow = sy * srcWidth
            let dstRow = y * dstWidth
            for x in 0..<dstWidth {
                let sx = min(srcWidth - 1, Int((Double(x) + 0.5) * Double(srcWidth) / Double(dstWidth)))
                ptr[dstRow + x] = maskBytes[srcRow + sx] >= 128 ? 1.0 : 0.0
            }
        }
        return array
    }

    private static func extractCGImage(from value: MLFeatureValue) throws -> CGImage {
        if let pb = value.imageBufferValue {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else {
                throw ParallaxInpainterError.invalidModelOutput
            }

            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            if fmt == kCVPixelFormatType_32BGRA {
                for y in 0..<h {
                    let sRow = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let dRow = y * w * 4
                    for x in 0..<w {
                        let s = x * 4
                        let d = dRow + x * 4
                        rgba[d] = sRow[s + 2]
                        rgba[d + 1] = sRow[s + 1]
                        rgba[d + 2] = sRow[s]
                        rgba[d + 3] = 255
                    }
                }
            } else if fmt == kCVPixelFormatType_32ARGB {
                for y in 0..<h {
                    let sRow = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let dRow = y * w * 4
                    for x in 0..<w {
                        let s = x * 4
                        let d = dRow + x * 4
                        rgba[d] = sRow[s + 1]
                        rgba[d + 1] = sRow[s + 2]
                        rgba[d + 2] = sRow[s + 3]
                        rgba[d + 3] = 255
                    }
                }
            } else {
                // Fallback for 32RGBA or RGB formats
                for y in 0..<h {
                    let sRow = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let dRow = y * w * 4
                    for x in 0..<w {
                        let s = x * 4
                        let d = dRow + x * 4
                        rgba[d] = sRow[s]
                        rgba[d + 1] = sRow[s + 1]
                        rgba[d + 2] = sRow[s + 2]
                        rgba[d + 3] = 255
                    }
                }
            }
            return try makeRGBA8CGImage(bytes: rgba, width: w, height: h)
        }

        if let multiArray = value.multiArrayValue {
            let shape = multiArray.shape.map { $0.intValue }
            let strides = multiArray.strides.map { $0.intValue }
            guard shape.count >= 3 else {
                throw ParallaxInpainterError.invalidModelOutput
            }
            let cIdx = shape.count - 3
            let hIdx = shape.count - 2
            let wIdx = shape.count - 1
            let channels = shape[cIdx]
            let h = shape[hIdx]
            let w = shape[wIdx]
            guard channels >= 3 else { throw ParallaxInpainterError.invalidModelOutput }

            let cStride = strides[cIdx]
            let yStride = strides[hIdx]
            let xStride = strides[wIdx]

            // Probe max value to detect [0, 1] vs [0, 255] output range
            var maxProbe: Float = 0
            let readVal: (Int) -> Float
            switch multiArray.dataType {
            case .float16:
                let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
                readVal = { Float(ptr[$0]) }
            case .float32:
                let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
                readVal = { ptr[$0] }
            default:
                readVal = { multiArray[$0].floatValue }
            }

            let stepY = max(1, h / 16)
            let stepX = max(1, w / 16)
            for y in stride(from: 0, to: h, by: stepY) {
                for x in stride(from: 0, to: w, by: stepX) {
                    let v = readVal(y * yStride + x * xStride)
                    if v.isFinite && v > maxProbe { maxProbe = v }
                }
            }
            let scale: Float = maxProbe <= 2.0 ? 255.0 : 1.0

            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                let dRow = y * w * 4
                let yOff = y * yStride
                for x in 0..<w {
                    let baseOff = yOff + x * xStride
                    let r = readVal(baseOff) * scale
                    let g = readVal(baseOff + cStride) * scale
                    let b = readVal(baseOff + 2 * cStride) * scale
                    let d = dRow + x * 4
                    rgba[d] = UInt8(clamping: Int(r.rounded()))
                    rgba[d + 1] = UInt8(clamping: Int(g.rounded()))
                    rgba[d + 2] = UInt8(clamping: Int(b.rounded()))
                    rgba[d + 3] = 255
                }
            }
            return try makeRGBA8CGImage(bytes: rgba, width: w, height: h)
        }

        throw ParallaxInpainterError.invalidModelOutput
    }

    private static func resizeCGImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }
        return out
    }

    private static func makeRGBA8CGImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw ParallaxInpainterError.pixelBufferCreationFailed
        }
        return cgImage
    }
}
