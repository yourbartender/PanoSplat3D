import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Engine used to repaint the 180°-centered 360° wrap seam strip.
public enum SeamHealEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case manualShift180 = "manualShift180"
    case drawThings = "drawThings"
    case localLaMa = "localLaMa"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manualShift180: return "Shift 180° (Draw Things UI)"
        case .drawThings: return "Draw Things API"
        case .localLaMa: return "Local LaMa (~2s)"
        }
    }
}

/// Configurable width of the vertical seam strip repainted after rolling the panorama 180°.
public enum SeamStripWidth: String, CaseIterable, Identifiable, Codable, Sendable {
    case narrow = "narrow"
    case medium = "medium"
    case wide = "wide"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .narrow: return "Narrow (6%)"
        case .medium: return "Medium (10%)"
        case .wide: return "Wide (14%)"
        }
    }

    /// Fraction of total panorama width kept at full mask opacity (white = 255) around the seam.
    public var coreWidthFraction: Double {
        switch self {
        case .narrow: return 0.06
        case .medium: return 0.10
        case .wide: return 0.14
        }
    }

    /// Smooth raised-cosine feather width on each side of the core strip.
    public var featherFraction: Double {
        switch self {
        case .narrow: return 0.025
        case .medium: return 0.035
        case .wide: return 0.045
        }
    }
}

public enum SeamHealerError: LocalizedError, Sendable {
    case imageEncodingFailed
    case imageDecodingFailed
    case contextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode shifted panorama or seam mask as PNG."
        case .imageDecodingFailed:
            return "Failed to decode inpainted image returned by Draw Things."
        case .contextCreationFailed:
            return "Failed to allocate CoreGraphics buffer for 360° seam healing."
        }
    }
}

/// Prepared shifted panorama + white-center inpaint mask ready for Draw Things `POST /sdapi/v1/img2img`.
public struct PreparedSeamInpaint: Sendable {
    public let shiftedOriginal: CGImage
    public let initImagePNG: Data
    public let maskPNG: Data
    public let workingWidth: Int
    public let workingHeight: Int
    /// Optional crop metadata when a centered 1:1 square around the 180° seam was sent instead of the full 2:1 frame.
    public let cropX: Int?
    public let cropWidth: Int?

    public init(
        shiftedOriginal: CGImage,
        initImagePNG: Data,
        maskPNG: Data,
        workingWidth: Int,
        workingHeight: Int,
        cropX: Int? = nil,
        cropWidth: Int? = nil
    ) {
        self.shiftedOriginal = shiftedOriginal
        self.initImagePNG = initImagePNG
        self.maskPNG = maskPNG
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        self.cropX = cropX
        self.cropWidth = cropWidth
    }
}

/// Pure-Swift VFX 180°-shift 360° seam healer:
/// 1. Rolls the equirectangular panorama horizontally by `W / 2` so the `0° / 360°` seam moves to the dead center.
/// 2. Builds a raised-cosine vertical inpainting mask centered on the seam.
/// 3. Sends only the working-resolution shifted image + mask to Draw Things `/sdapi/v1/img2img`.
/// 4. Composites ONLY the healed center strip smoothly back onto the full-resolution shifted original
///    (leaving ~85–90% of original pixels untouched bit-for-bit!) and rolls back by `-W / 2`.
public enum SeamHealerService {

    /// Circularly shifts an image horizontally by `shiftPixels` (positive shifts pixels to the right, wrapping around).
    public static func rollHorizontal(_ image: CGImage, shiftPixels: Int) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw SeamHealerError.contextCreationFailed
        }

        let normalizedShift = ((shiftPixels % width) + width) % width
        let src = PanoramaLoader.extractRGBA8Bytes(from: image)
        var dst = [UInt8](repeating: 0, count: width * height * 4)

        let rowBytes = width * 4
        let splitBytes = normalizedShift * 4
        let rightBytes = rowBytes - splitBytes

        src.withUnsafeBytes { srcRaw in
            dst.withUnsafeMutableBytes { dstRaw in
                guard let sBase = srcRaw.baseAddress, let dBase = dstRaw.baseAddress else { return }
                for y in 0..<height {
                    let sRow = sBase.advanced(by: y * rowBytes)
                    let dRow = dBase.advanced(by: y * rowBytes)
                    if splitBytes == 0 {
                        memcpy(dRow, sRow, rowBytes)
                    } else {
                        // src[0 ..< width-shift] -> dst[shift ..< width]
                        memcpy(dRow.advanced(by: splitBytes), sRow, rightBytes)
                        // src[width-shift ..< width] -> dst[0 ..< shift]
                        memcpy(dRow, sRow.advanced(by: rightBytes), splitBytes)
                    }
                }
            }
        }

        return try makeCGImage(fromRGBA8: dst, width: width, height: height)
    }

    /// Generates a grayscale inpaint mask (`white = 255` over the center seam strip, `black = 0` elsewhere)
    /// with raised-cosine feathered edges.
    public static func makeCenterSeamMask(
        width: Int,
        height: Int,
        coreWidthFraction: Double,
        featherFraction: Double
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw SeamHealerError.contextCreationFailed
        }

        let center = Double(width) * 0.5
        let coreHalf = Double(width) * coreWidthFraction * 0.5
        let feather = max(Double(width) * featherFraction, 2.0)

        var row = [UInt8](repeating: 0, count: width)
        for x in 0..<width {
            let alpha = centerStripWeight(
                x: Double(x) + 0.5,
                center: center,
                coreHalf: coreHalf,
                feather: feather
            )
            row[x] = UInt8(clamping: Int((alpha * 255.0).rounded()))
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { dstRaw in
            row.withUnsafeBytes { rowRaw in
                guard let dBase = dstRaw.baseAddress, let rBase = rowRaw.baseAddress else { return }
                for y in 0..<height {
                    memcpy(dBase.advanced(by: y * width), rBase, width)
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
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
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw SeamHealerError.contextCreationFailed
        }
        return cgImage
    }

    /// Prepares the 180°-shifted panorama, working-resolution init PNG, and matching center-seam mask PNG for Draw Things.
    public static func prepareForDrawThings(
        panorama: CGImage,
        targetWorkingSize: (width: Int, height: Int)?,
        stripWidth: SeamStripWidth
    ) throws -> PreparedSeamInpaint {
        let halfShift = panorama.width / 2
        let shiftedOriginal = try rollHorizontal(panorama, shiftPixels: halfShift)

        let workingW: Int
        let workingH: Int
        if let explicit = targetWorkingSize {
            workingW = max(256, (explicit.width / 64) * 64)
            workingH = max(128, (explicit.height / 64) * 64)
        } else {
            // Match input aspect ratio, capped cleanly at 2048px wide and rounded to 64px multiples
            let cappedW = min(panorama.width, 2048)
            workingW = max(512, (cappedW / 64) * 64)
            let rawH = Int((Double(workingW) * (Double(panorama.height) / Double(max(panorama.width, 1)))).rounded())
            workingH = max(256, (rawH / 64) * 64)
        }

        let workingInitRaw = (workingW == shiftedOriginal.width && workingH == shiftedOriginal.height)
            ? shiftedOriginal
            : try resizeImage(shiftedOriginal, width: workingW, height: workingH)

        // Smoothly bridge the hard vertical seam at x = W/2 before sending to Draw Things img2img
        // (since Draw Things' HTTP /sdapi/v1/img2img does not accept a separate `mask` key, removing
        // the sharp discontinuity prevents diffusion from copying the seam line while keeping outer context locked).
        let workingInit = try preBridgeCenterSeam(workingInitRaw, stripWidth: stripWidth)

        let maskImage = try makeCenterSeamMask(
            width: workingW,
            height: workingH,
            coreWidthFraction: stripWidth.coreWidthFraction,
            featherFraction: stripWidth.featherFraction
        )

        let initPNG = try encodePNG(workingInit)
        let maskPNG = try encodePNG(maskImage)

        return PreparedSeamInpaint(
            shiftedOriginal: shiftedOriginal,
            initImagePNG: initPNG,
            maskPNG: maskPNG,
            workingWidth: workingW,
            workingHeight: workingH,
            cropX: nil,
            cropWidth: nil
        )
    }

    /// Prepares a fast, high-detail `1:1` square crop (`squareSize × squareSize`, default `768×768`) centered
    /// directly over the 180°-shifted seam for Draw Things `/sdapi/v1/img2img`.
    /// Runs 2–4× faster than a full 2:1 frame and keeps 100% of outer pixels outside the seam strip bit-exact.
    public static func prepareCenterSquareForDrawThings(
        panorama: CGImage,
        squareSize: Int = 768,
        stripWidth: SeamStripWidth
    ) throws -> PreparedSeamInpaint {
        let halfShift = panorama.width / 2
        let shiftedOriginal = try rollHorizontal(panorama, shiftPixels: halfShift)

        let cropWidth = min(shiftedOriginal.width, shiftedOriginal.height)
        let cropX = (shiftedOriginal.width - cropWidth) / 2
        guard let centerCrop = shiftedOriginal.cropping(
            to: CGRect(x: cropX, y: 0, width: cropWidth, height: shiftedOriginal.height)
        ) else {
            throw SeamHealerError.contextCreationFailed
        }

        let targetDim = max(512, (squareSize / 64) * 64)
        let resizedCrop = (centerCrop.width == targetDim && centerCrop.height == targetDim)
            ? centerCrop
            : try resizeImage(centerCrop, width: targetDim, height: targetDim)

        // Physical seam strip fraction inside the 1:1 crop (2× the full-panorama width fraction for 2:1 panos)
        let cropScaleRatio = Double(shiftedOriginal.width) / Double(max(cropWidth, 1))
        let cropCoreFrac = min(0.45, stripWidth.coreWidthFraction * cropScaleRatio)
        let bridgedCrop = try preBridgeCenterSeam(resizedCrop, coreWidthFraction: cropCoreFrac)

        let maskImage = try makeCenterSeamMask(
            width: targetDim,
            height: targetDim,
            coreWidthFraction: cropCoreFrac,
            featherFraction: min(0.12, stripWidth.featherFraction * cropScaleRatio)
        )

        let initPNG = try encodePNG(bridgedCrop)
        let maskPNG = try encodePNG(maskImage)

        return PreparedSeamInpaint(
            shiftedOriginal: shiftedOriginal,
            initImagePNG: initPNG,
            maskPNG: maskPNG,
            workingWidth: targetDim,
            workingHeight: targetDim,
            cropX: cropX,
            cropWidth: cropWidth
        )
    }

    /// Replaces the sharp vertical seam discontinuity along `x = W/2` with a smooth horizontal
    /// cosine bridge between left and right anchor bands so unmasked `img2img` re-synthesizes crisp,
    /// continuous scenery across the center strip instead of preserving the seam edge.
    public static func preBridgeCenterSeam(
        _ image: CGImage,
        stripWidth: SeamStripWidth
    ) throws -> CGImage {
        try preBridgeCenterSeam(image, coreWidthFraction: stripWidth.coreWidthFraction)
    }

    public static func preBridgeCenterSeam(
        _ image: CGImage,
        coreWidthFraction: Double
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width >= 16, height > 0 else { return image }

        var rgba = PanoramaLoader.extractRGBA8Bytes(from: image)
        let center = Double(width) * 0.5
        let halfCore = max(4, Int((Double(width) * coreWidthFraction * 0.5).rounded()))
        let leftAnchorX = max(2, Int(center) - halfCore)
        let rightAnchorX = min(width - 3, Int(center) + halfCore)
        let span = max(1, rightAnchorX - leftAnchorX)

        for y in 0..<height {
            let row = y * width
            // Average a 5px horizontal anchor window just outside the seam on left & right
            var lr = 0.0, lg = 0.0, lb = 0.0
            var rr = 0.0, rg = 0.0, rb = 0.0
            for dx in -2...2 {
                let lx = min(max(leftAnchorX + dx, 0), width - 1)
                let rx = min(max(rightAnchorX + dx, 0), width - 1)
                let lOff = (row + lx) * 4
                let rOff = (row + rx) * 4
                lr += Double(rgba[lOff]); lg += Double(rgba[lOff + 1]); lb += Double(rgba[lOff + 2])
                rr += Double(rgba[rOff]); rg += Double(rgba[rOff + 1]); rb += Double(rgba[rOff + 2])
            }
            lr /= 5.0; lg /= 5.0; lb /= 5.0
            rr /= 5.0; rg /= 5.0; rb /= 5.0

            for x in leftAnchorX...rightAnchorX {
                let u = Double(x - leftAnchorX) / Double(span) // 0 at left anchor -> 1 at right anchor
                let smoothU = 0.5 - 0.5 * cos(u * .pi)
                let br = lr * (1.0 - smoothU) + rr * smoothU
                let bg = lg * (1.0 - smoothU) + rg * smoothU
                let bb = lb * (1.0 - smoothU) + rb * smoothU

                // Raised-cosine envelope: 0 at anchors, 0.96 right on the seam line
                let distNorm = abs(u - 0.5) * 2.0 // 0 at seam -> 1 at anchor
                let bridgeWeight = 0.96 * (0.5 + 0.5 * cos(distNorm * .pi))
                let origWeight = 1.0 - bridgeWeight

                let off = (row + x) * 4
                rgba[off] = UInt8(clamping: Int((Double(rgba[off]) * origWeight + br * bridgeWeight).rounded()))
                rgba[off + 1] = UInt8(clamping: Int((Double(rgba[off + 1]) * origWeight + bg * bridgeWeight).rounded()))
                rgba[off + 2] = UInt8(clamping: Int((Double(rgba[off + 2]) * origWeight + bb * bridgeWeight).rounded()))
                rgba[off + 3] = 255
            }
        }

        return try makeCGImage(fromRGBA8: rgba, width: width, height: height)
    }

    /// Composites ONLY the healed center strip from `inpaintedShifted` back onto the full-resolution `shiftedOriginal`
    /// using a raised-cosine feather curve, leaving all outer pixels 100% untouched.
    public static func compositeHealedCenterStrip(
        shiftedOriginal: CGImage,
        inpaintedShifted: CGImage,
        stripWidth: SeamStripWidth
    ) throws -> CGImage {
        let width = shiftedOriginal.width
        let height = shiftedOriginal.height

        let alignedInpainted = (inpaintedShifted.width == width && inpaintedShifted.height == height)
            ? inpaintedShifted
            : try resizeImage(inpaintedShifted, width: width, height: height)

        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: shiftedOriginal)
        let healBytes = PanoramaLoader.extractRGBA8Bytes(from: alignedInpainted)
        var outBytes = origBytes

        let center = Double(width) * 0.5
        let coreHalf = Double(width) * stripWidth.coreWidthFraction * 0.5
        let feather = max(Double(width) * stripWidth.featherFraction, 2.0)

        // Precompute horizontal blend weights once per column
        var weights = [Double](repeating: 0.0, count: width)
        var minAffectedX = width
        var maxAffectedX = 0
        for x in 0..<width {
            let w = centerStripWeight(x: Double(x) + 0.5, center: center, coreHalf: coreHalf, feather: feather)
            weights[x] = w
            if w > 0 {
                if x < minAffectedX { minAffectedX = x }
                if x > maxAffectedX { maxAffectedX = x }
            }
        }

        if minAffectedX <= maxAffectedX {
            for y in 0..<height {
                let rowOffset = y * width * 4
                for x in minAffectedX...maxAffectedX {
                    let w = weights[x]
                    let idx = rowOffset + x * 4
                    if w >= 1.0 - 1e-6 {
                        outBytes[idx] = healBytes[idx]
                        outBytes[idx + 1] = healBytes[idx + 1]
                        outBytes[idx + 2] = healBytes[idx + 2]
                        outBytes[idx + 3] = 255
                    } else if w > 1e-6 {
                        let inv = 1.0 - w
                        outBytes[idx] = UInt8(clamping: Int((Double(origBytes[idx]) * inv + Double(healBytes[idx]) * w).rounded()))
                        outBytes[idx + 1] = UInt8(clamping: Int((Double(origBytes[idx + 1]) * inv + Double(healBytes[idx + 1]) * w).rounded()))
                        outBytes[idx + 2] = UInt8(clamping: Int((Double(origBytes[idx + 2]) * inv + Double(healBytes[idx + 2]) * w).rounded()))
                        outBytes[idx + 3] = 255
                    }
                }
            }
        }

        return try makeCGImage(fromRGBA8: outBytes, width: width, height: height)
    }

    /// Decodes Draw Things' inpainted output, composites only the healed center strip onto the full-resolution
    /// shifted original (handling both full 2:1 frames and centered 1:1 square crops), and rolls horizontally
    /// back by `-W / 2` to restore exact original 360° orientation.
    public static func finalizeHealedPanorama(
        shiftedOriginal: CGImage,
        inpaintedImageData: Data,
        stripWidth: SeamStripWidth,
        cropX: Int? = nil,
        cropWidth: Int? = nil
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(inpaintedImageData as CFData, nil),
              let inpaintedCG = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SeamHealerError.imageDecodingFailed
        }

        let compositedShifted: CGImage
        if let cropX, let cropWidth {
            let scaledCrop = (inpaintedCG.width == cropWidth && inpaintedCG.height == shiftedOriginal.height)
                ? inpaintedCG
                : try resizeImage(inpaintedCG, width: cropWidth, height: shiftedOriginal.height)
            compositedShifted = try compositeHealedCenterCrop(
                shiftedOriginal: shiftedOriginal,
                healedCenterCrop: scaledCrop,
                cropX: cropX,
                stripWidth: stripWidth
            )
        } else {
            compositedShifted = try compositeHealedCenterStrip(
                shiftedOriginal: shiftedOriginal,
                inpaintedShifted: inpaintedCG,
                stripWidth: stripWidth
            )
        }

        // Exact inverse of `shiftPixels = width / 2` even when width is odd
        let inverseShift = shiftedOriginal.width - (shiftedOriginal.width / 2)
        return try rollHorizontal(compositedShifted, shiftPixels: inverseShift)
    }

    /// Shifts a 360° panorama horizontally by 180° (`width / 2`) so the `0° / 360°` seam moves to the dead center,
    /// ready for native masked Eraser inpainting inside Draw Things (zero Photoshop needed).
    public static func shift180(_ panorama: CGImage) throws -> CGImage {
        try rollHorizontal(panorama, shiftPixels: panorama.width / 2)
    }

    /// Rolls a 180°-shifted (inpainted) panorama back by `width - width / 2` to its exact original 360° orientation.
    public static func rollBack180(_ shiftedPanorama: CGImage) throws -> CGImage {
        let inverseShift = shiftedPanorama.width - (shiftedPanorama.width / 2)
        return try rollHorizontal(shiftedPanorama, shiftPixels: inverseShift)
    }

    /// Fast 100% local 360° seam healer (~2 seconds on Apple Silicon, zero Draw Things required):
    /// 1. Rolls the panorama horizontally by `W / 2` so the `0° / 360°` seam moves to the center.
    /// 2. Extracts a `1:1` square (`H × H`) crop centered on the seam so CoreML `LaMa` (`800×800`) runs
    ///    with zero 2:1 aspect-ratio squishing and 2× sharper horizontal detail.
    /// 3. Runs CoreML `LaMa` over only the centered seam strip, composites the healed strip back into the
    ///    full-resolution shifted panorama with raised-cosine feathering (leaving ~85–90% of pixels bit-exact),
    ///    and rolls back by `-W / 2`.
    public static func healWithLocalLaMa(
        panorama: CGImage,
        stripWidth: SeamStripWidth,
        inpainter: ParallaxHoleInpainter = ParallaxHoleInpainter(),
        onModelStateChange: @Sendable (LaMaModelState) -> Void = { _ in }
    ) async throws -> CGImage {
        let width = panorama.width
        let height = panorama.height
        let halfShift = width / 2
        let shiftedOriginal = try rollHorizontal(panorama, shiftPixels: halfShift)

        // Square 1:1 crop centered on x = width / 2 for undistorted 800×800 LaMa inference
        let cropWidth = min(width, height)
        let cropX = (width - cropWidth) / 2
        guard let centerCrop = shiftedOriginal.cropping(to: CGRect(x: cropX, y: 0, width: cropWidth, height: height)) else {
            throw SeamHealerError.contextCreationFailed
        }

        // Physical seam strip width in panorama pixels, centered inside the 1:1 crop
        let seamCorePixels = max(6.0, Double(width) * stripWidth.coreWidthFraction)
        let cropValidMask = try makeCropValidityMask(
            cropWidth: cropWidth,
            cropHeight: height,
            holeWidthPixels: seamCorePixels
        )

        let loadedModel = try await inpainter.prepareModel(onStateChange: onModelStateChange)
        let (healedCrop, _) = try await inpainter.fillDisoccludedHoles(
            in: centerCrop,
            validMask: cropValidMask,
            using: loadedModel,
            dilationRadius: 1,
            maxFillHoleFraction: 0.45
        )

        let compositedShifted = try compositeHealedCenterCrop(
            shiftedOriginal: shiftedOriginal,
            healedCenterCrop: healedCrop,
            cropX: cropX,
            stripWidth: stripWidth
        )

        let inverseShift = width - halfShift
        return try rollHorizontal(compositedShifted, shiftPixels: inverseShift)
    }

    /// Creates a Brush/LaMa validity mask (`255 = valid`, `0 = centered vertical seam strip to inpaint`)
    /// matching the 1:1 square center crop.
    public static func makeCropValidityMask(
        cropWidth: Int,
        cropHeight: Int,
        holeWidthPixels: Double
    ) throws -> CGImage {
        guard cropWidth > 0, cropHeight > 0 else {
            throw SeamHealerError.contextCreationFailed
        }
        let center = Double(cropWidth) * 0.5
        let halfHole = holeWidthPixels * 0.5
        var row = [UInt8](repeating: 255, count: cropWidth)
        for x in 0..<cropWidth {
            if abs((Double(x) + 0.5) - center) <= halfHole {
                row[x] = 0
            }
        }
        var pixels = [UInt8](repeating: 255, count: cropWidth * cropHeight)
        pixels.withUnsafeMutableBytes { dstRaw in
            row.withUnsafeBytes { rowRaw in
                guard let dBase = dstRaw.baseAddress, let rBase = rowRaw.baseAddress else { return }
                for y in 0..<cropHeight {
                    memcpy(dBase.advanced(by: y * cropWidth), rBase, cropWidth)
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: cropWidth,
                height: cropHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: cropWidth,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw SeamHealerError.contextCreationFailed
        }
        return cgImage
    }

    /// Blends ONLY the healed center seam strip from `healedCenterCrop` back into `shiftedOriginal`
    /// using raised-cosine horizontal feathering, leaving all outer pixels 100% bit-exact.
    public static func compositeHealedCenterCrop(
        shiftedOriginal: CGImage,
        healedCenterCrop: CGImage,
        cropX: Int,
        stripWidth: SeamStripWidth
    ) throws -> CGImage {
        let width = shiftedOriginal.width
        let height = shiftedOriginal.height
        let cropW = healedCenterCrop.width
        guard healedCenterCrop.height == height, cropX >= 0, cropX + cropW <= width else {
            throw SeamHealerError.contextCreationFailed
        }

        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: shiftedOriginal)
        let cropBytes = PanoramaLoader.extractRGBA8Bytes(from: healedCenterCrop)
        var outBytes = origBytes

        let center = Double(width) * 0.5
        let coreHalf = Double(width) * stripWidth.coreWidthFraction * 0.5
        let feather = max(Double(width) * stripWidth.featherFraction, 2.0)

        var weights = [Double](repeating: 0.0, count: width)
        var minX = width
        var maxX = 0
        for x in cropX..<(cropX + cropW) {
            let w = centerStripWeight(x: Double(x) + 0.5, center: center, coreHalf: coreHalf, feather: feather)
            weights[x] = w
            if w > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }

        if minX <= maxX {
            for y in 0..<height {
                let dstRow = y * width * 4
                let srcRow = y * cropW * 4
                for x in minX...maxX {
                    let w = weights[x]
                    let dstIdx = dstRow + x * 4
                    let srcIdx = srcRow + (x - cropX) * 4
                    if w >= 1.0 - 1e-6 {
                        outBytes[dstIdx] = cropBytes[srcIdx]
                        outBytes[dstIdx + 1] = cropBytes[srcIdx + 1]
                        outBytes[dstIdx + 2] = cropBytes[srcIdx + 2]
                        outBytes[dstIdx + 3] = 255
                    } else if w > 1e-6 {
                        let inv = 1.0 - w
                        outBytes[dstIdx] = UInt8(clamping: Int((Double(origBytes[dstIdx]) * inv + Double(cropBytes[srcIdx]) * w).rounded()))
                        outBytes[dstIdx + 1] = UInt8(clamping: Int((Double(origBytes[dstIdx + 1]) * inv + Double(cropBytes[srcIdx + 1]) * w).rounded()))
                        outBytes[dstIdx + 2] = UInt8(clamping: Int((Double(origBytes[dstIdx + 2]) * inv + Double(cropBytes[srcIdx + 2]) * w).rounded()))
                        outBytes[dstIdx + 3] = 255
                    }
                }
            }
        }

        return try makeCGImage(fromRGBA8: outBytes, width: width, height: height)
    }

    /// Generates a small preview thumbnail of the 180°-shifted panorama with a translucent mask band overlay
    /// so the user can visually verify the seam and strip width before running Draw Things.
    public static func makeShiftedSeamPreview(
        panorama: CGImage,
        stripWidth: SeamStripWidth,
        previewWidth: Int = 512
    ) -> CGImage? {
        let aspect = Double(panorama.height) / Double(max(panorama.width, 1))
        let pW = max(128, previewWidth)
        let pH = max(64, Int((Double(pW) * aspect).rounded()))

        guard let small = try? resizeImage(panorama, width: pW, height: pH),
              let shifted = try? rollHorizontal(small, shiftPixels: pW / 2) else {
            return nil
        }

        var bytes = PanoramaLoader.extractRGBA8Bytes(from: shifted)
        let center = Double(pW) * 0.5
        let coreHalf = Double(pW) * stripWidth.coreWidthFraction * 0.5
        let feather = max(Double(pW) * stripWidth.featherFraction, 2.0)

        for y in 0..<pH {
            let rowOff = y * pW * 4
            for x in 0..<pW {
                let w = centerStripWeight(x: Double(x) + 0.5, center: center, coreHalf: coreHalf, feather: feather)
                if w > 0.01 {
                    let idx = rowOff + x * 4
                    // Subtle warm orange highlight showing the inpaint zone
                    let tint = w * 0.38
                    let inv = 1.0 - tint
                    bytes[idx] = UInt8(clamping: Int((Double(bytes[idx]) * inv + 255.0 * tint).rounded()))
                    bytes[idx + 1] = UInt8(clamping: Int((Double(bytes[idx + 1]) * inv + 145.0 * tint).rounded()))
                    bytes[idx + 2] = UInt8(clamping: Int((Double(bytes[idx + 2]) * inv + 40.0 * tint).rounded()))
                }
            }
            // Crisp 1px amber center seam line
            let cx = pW / 2
            let cIdx = rowOff + cx * 4
            bytes[cIdx] = 255
            bytes[cIdx + 1] = 190
            bytes[cIdx + 2] = 40
        }

        return try? makeCGImage(fromRGBA8: bytes, width: pW, height: pH)
    }

    public static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SeamHealerError.imageEncodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SeamHealerError.imageEncodingFailed
        }
        return data as Data
    }

    // MARK: - Helpers

    private static func centerStripWeight(x: Double, center: Double, coreHalf: Double, feather: Double) -> Double {
        let dist = abs(x - center)
        if dist <= coreHalf {
            return 1.0
        }
        if dist >= coreHalf + feather {
            return 0.0
        }
        let t = (dist - coreHalf) / feather
        return 0.5 * (1.0 + cos(.pi * t))
    }

    private static func resizeImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw SeamHealerError.contextCreationFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else {
            throw SeamHealerError.contextCreationFailed
        }
        return out
    }

    private static func makeCGImage(fromRGBA8 bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
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
            throw SeamHealerError.contextCreationFailed
        }
        return cgImage
    }
}
