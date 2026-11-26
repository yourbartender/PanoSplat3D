import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum PanoramaLoadError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case unreadableFile(URL)
    case imageDecodeFailed(URL)
    case emptyImage

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported image format '.\(ext)'. Please choose a .png, .jpg, or .exr panorama."
        case .unreadableFile(let url):
            return "Could not open panorama file '\(url.lastPathComponent)'."
        case .imageDecodeFailed(let url):
            return "Failed to decode image data from '\(url.lastPathComponent)'."
        case .emptyImage:
            return "The selected image has invalid zero dimensions."
        }
    }
}

/// Native ImageIO + CoreImage loader for `.png`, `.jpg`/`.jpeg`, and HDR `.exr` equirectangular panoramas.
public enum PanoramaLoader {
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "exr"]

    public static func load(from url: URL) throws -> PanoramaAsset {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw PanoramaLoadError.unsupportedFormat(ext)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let isEXR = (ext == "exr")

        let decodedCGImage: CGImage
        let isHDR: Bool

        if isEXR {
            decodedCGImage = try decodeHDRWithToneMapping(url: url)
            isHDR = true
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw PanoramaLoadError.unreadableFile(url)
            }
            guard let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PanoramaLoadError.imageDecodeFailed(url)
            }

            let floatComponents = rawImage.bitmapInfo.contains(.floatComponents)
            isHDR = floatComponents || rawImage.bitsPerComponent > 8

            if floatComponents {
                decodedCGImage = try decodeHDRWithToneMapping(url: url)
            } else {
                decodedCGImage = try normalizeToRGBA8SRGB(rawImage)
            }
        }

        let width = decodedCGImage.width
        let height = decodedCGImage.height
        guard width > 0 && height > 0 else {
            throw PanoramaLoadError.emptyImage
        }

        let thumbnail = makeThumbnail(from: decodedCGImage, maxWidth: 1024) ?? decodedCGImage

        return PanoramaAsset(
            sourceURL: url.standardizedFileURL,
            width: width,
            height: height,
            isHDR: isHDR,
            fileSizeBytes: fileSize,
            cgImage: decodedCGImage,
            thumbnail: thumbnail
        )
    }

    /// Decodes an HDR OpenEXR / float image via CoreImage and applies smooth photographic tone mapping to sRGB RGBA8.
    private static func decodeHDRWithToneMapping(url: URL) throws -> CGImage {
        guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw PanoramaLoadError.imageDecodeFailed(url)
        }

        let extent = ciImage.extent
        guard extent.width > 0 && extent.height > 0 else {
            throw PanoramaLoadError.emptyImage
        }

        // Apply gentle highlight compression / tone mapping for linear HDR values > 1.0
        var processed = ciImage
        if let toneMapFilter = CIFilter(name: "CIToneMapHeadroom") {
            toneMapFilter.setValue(processed, forKey: kCIInputImageKey)
            toneMapFilter.setValue(1.0, forKey: "inputTargetHeadroom")
            if let output = toneMapFilter.outputImage {
                processed = output
            }
        } else if let highlightFilter = CIFilter(name: "CIHighlightShadowAdjust") {
            highlightFilter.setValue(processed, forKey: kCIInputImageKey)
            highlightFilter.setValue(0.75, forKey: "inputHighlightAmount")
            highlightFilter.setValue(0.15, forKey: "inputShadowAmount")
            if let output = highlightFilter.outputImage {
                processed = output
            }
        }

        let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .outputColorSpace: srgbColorSpace
        ])

        guard let cgImage = context.createCGImage(
            processed,
            from: extent,
            format: .RGBA8,
            colorSpace: srgbColorSpace
        ) else {
            throw PanoramaLoadError.imageDecodeFailed(url)
        }

        return cgImage
    }

    /// Ensures consistent 8-bit RGBA sRGB pixel layout for Metal uploads and fast CPU pixel reads.
    private static func normalizeToRGBA8SRGB(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw PanoramaLoadError.emptyImage
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let normalized = context.makeImage() else {
            throw PanoramaLoadError.emptyImage
        }
        return normalized
    }

    private static func makeThumbnail(from image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let targetWidth = maxWidth
        let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Extracts tightly packed `width * height * 4` RGBA8 bytes (row-major, top-to-bottom) from a `CGImage`.
    public static func extractRGBA8Bytes(from image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        buffer.withUnsafeMutableBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress,
               let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
               ) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }
}
