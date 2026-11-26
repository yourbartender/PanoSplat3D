import CoreGraphics
import Foundation

/// Aspect-ratio validation result for 2:1 equirectangular panoramas.
public enum AspectRatioValidation: Equatable, Sendable {
    case valid(ratio: Double)
    case warning(ratio: Double)

    public var isExactEquirectangular: Bool {
        if case .valid = self { return true }
        return false
    }

    public var ratio: Double {
        switch self {
        case .valid(let r), .warning(let r): return r
        }
    }

    public var badgeText: String {
        let formatted = String(format: "%.2f:1", ratio)
        switch self {
        case .valid:
            return "2:1 Equirectangular (\(formatted))"
        case .warning:
            return "Non-2:1 Ratio (\(formatted))"
        }
    }
}

/// Loaded 360° equirectangular panorama ready for preview, slicing, and point cloud generation.
public struct PanoramaAsset: Sendable {
    public let sourceURL: URL
    public let width: Int
    public let height: Int
    public let isHDR: Bool
    public let fileSizeBytes: Int64
    public let aspectValidation: AspectRatioValidation
    /// Tone-mapped RGBA8 sRGB image (width × height) for Metal slicing & point cloud sampling.
    public let cgImage: CGImage
    /// Scaled preview thumbnail for smooth SwiftUI rendering.
    public let thumbnail: CGImage

    public init(
        sourceURL: URL,
        width: Int,
        height: Int,
        isHDR: Bool,
        fileSizeBytes: Int64,
        cgImage: CGImage,
        thumbnail: CGImage
    ) {
        self.sourceURL = sourceURL
        self.width = width
        self.height = height
        self.isHDR = isHDR
        self.fileSizeBytes = fileSizeBytes
        self.cgImage = cgImage
        self.thumbnail = thumbnail

        let ratio = height > 0 ? Double(width) / Double(height) : 0
        if abs(ratio - 2.0) <= 0.03 {
            self.aspectValidation = .valid(ratio: ratio)
        } else {
            self.aspectValidation = .warning(ratio: ratio)
        }
    }

    public var fileName: String {
        sourceURL.lastPathComponent
    }

    public var baseName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    public var resolutionBadge: String {
        "\(width) × \(height)" + (isHDR ? " HDR" : "")
    }
}
