import CoreGraphics
import Foundation

/// Seamless 2:1 equirectangular 360° relative disparity & bounded metric radius buffer.
public struct EquirectangularDepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Seamless aligned relative disparity `D(u, v)` (higher = closer).
    public let disparity: [Float]
    /// Bounded metric radius `R(u, v)` in meters, strictly clamped to `[1.5m, 60.0m]`.
    public let metricRadiusMeters: [Float]
    public let minRadiusMeters: Float
    public let maxRadiusMeters: Float
    public let medianRadiusMeters: Float

    public init(
        width: Int,
        height: Int,
        disparity: [Float],
        metricRadiusMeters: [Float]
    ) {
        self.width = width
        self.height = height
        self.disparity = disparity
        self.metricRadiusMeters = metricRadiusMeters

        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = 0
        for r in metricRadiusMeters {
            if r < minVal { minVal = r }
            if r > maxVal { maxVal = r }
        }
        self.minRadiusMeters = minVal.isFinite ? minVal : 1.5
        self.maxRadiusMeters = maxVal > 0 ? maxVal : 60.0

        // Sampled median for fast UI reporting
        if metricRadiusMeters.isEmpty {
            self.medianRadiusMeters = 12.0
        } else {
            let strideStep = max(1, metricRadiusMeters.count / 4096)
            var samples: [Float] = []
            samples.reserveCapacity(4096)
            var idx = 0
            while idx < metricRadiusMeters.count {
                samples.append(metricRadiusMeters[idx])
                idx += strideStep
            }
            samples.sort()
            self.medianRadiusMeters = samples[samples.count / 2]
        }
    }

    /// Bilinearly samples the metric radius `R(u, v)` in meters with horizontal 360° wrap and vertical pole clamp.
    public func radius(u: Double, v: Double) -> Double {
        guard width > 0, height > 0, metricRadiusMeters.count == width * height else {
            return 12.0
        }

        let fx = u * Double(width) - 0.5
        let fy = v * Double(height) - 0.5

        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let tx = fx - Double(x0)
        let ty = fy - Double(y0)

        let wx0 = ((x0 % width) + width) % width
        let wx1 = (wx0 + 1) % width
        let cy0 = min(max(y0, 0), height - 1)
        let cy1 = min(max(y0 + 1, 0), height - 1)

        let r00 = Double(metricRadiusMeters[cy0 * width + wx0])
        let r10 = Double(metricRadiusMeters[cy0 * width + wx1])
        let r01 = Double(metricRadiusMeters[cy1 * width + wx0])
        let r11 = Double(metricRadiusMeters[cy1 * width + wx1])

        let top = r00 * (1.0 - tx) + r10 * tx
        let bottom = r01 * (1.0 - tx) + r11 * tx
        return top * (1.0 - ty) + bottom * ty
    }

    /// Generates an Inferno-inspired colorized preview `CGImage` (warm bright = near, deep indigo = far).
    public func makeColorizedPreviewCGImage() -> CGImage? {
        guard width > 0, height > 0, metricRadiusMeters.count == width * height else { return nil }

        let invMin = 1.0 / max(maxRadiusMeters, 1.5)
        let invMax = 1.0 / max(minRadiusMeters, 1.5)
        let invSpan = max(invMax - invMin, 1e-5)

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let invR = 1.0 / max(metricRadiusMeters[i], 1.5)
            let t = min(max((invR - invMin) / invSpan, 0.0), 1.0)
            let (r, g, b) = Self.infernoColor(t)
            let offset = i * 4
            rgba[offset] = r
            rgba[offset + 1] = g
            rgba[offset + 2] = b
            rgba[offset + 3] = 255
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        return CGImage(
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
        )
    }

    /// 6-stop perceptual Inferno ramp (`t = 0` far/dark purple -> `t = 1` near/bright warm yellow).
    private static func infernoColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 0.05, 0.03, 0.16),
            (0.22, 0.28, 0.06, 0.43),
            (0.45, 0.62, 0.16, 0.39),
            (0.68, 0.89, 0.35, 0.19),
            (0.86, 0.98, 0.65, 0.12),
            (1.00, 0.99, 0.96, 0.64)
        ]

        let clamped = min(max(t, 0), 1)
        for idx in 0..<(stops.count - 1) {
            let a = stops[idx]
            let b = stops[idx + 1]
            if clamped >= a.0 && clamped <= b.0 {
                let f = (clamped - a.0) / max(b.0 - a.0, 1e-5)
                let r = a.1 + (b.1 - a.1) * f
                let g = a.2 + (b.2 - a.2) * f
                let bl = a.3 + (b.3 - a.3) * f
                return (
                    UInt8(min(max((r * 255).rounded(), 0), 255)),
                    UInt8(min(max((g * 255).rounded(), 0), 255)),
                    UInt8(min(max((bl * 255).rounded(), 0), 255))
                )
            }
        }
        return (252, 245, 163)
    }
}
