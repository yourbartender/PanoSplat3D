import CoreGraphics
import Foundation

/// Fast 360°-wrap-safe RGB-Guided Joint Bilateral Filter for snapping soft monocular depth edges
/// cleanly onto sharp RGB object silhouettes (e.g. pine tree trunks, architectural edges) to eliminate flying pixels.
public enum DepthEdgeRefiner {
    /// Refines an `EquirectangularDepthMap` by running 2 passes of circular-wrap RGB-guided joint bilateral filtering
    /// on the relative disparity field, then recomputing bounded metric radius `R(u, v)` in `[1.5m, 60.0m]`.
    public static func refine(
        depthMap: EquirectangularDepthMap,
        guidedBy panoramaImage: CGImage,
        depthScaleMeters: Double,
        passes: Int = 2,
        radius: Int = 2,
        sigmaSpatial: Float = 1.6,
        sigmaColor: Float = 0.075
    ) -> EquirectangularDepthMap {
        let w = depthMap.width
        let h = depthMap.height
        guard w > 4, h > 4, depthMap.disparity.count == w * h else { return depthMap }

        // Downsample sharp RGB guide image to match the depth map dimensions (1024×512)
        guard let guideRGB = extractNormalizedRGBGuide(from: panoramaImage, width: w, height: h) else {
            return depthMap
        }

        // Precompute spatial Gaussian lookup table
        let kernelDim = radius * 2 + 1
        var spatialWeights = [Float](repeating: 0, count: kernelDim * kernelDim)
        let invTwoSigmaS2: Float = 1.0 / (2.0 * sigmaSpatial * sigmaSpatial)
        for dy in -radius...radius {
            for dx in -radius...radius {
                let d2 = Float(dx * dx + dy * dy)
                spatialWeights[(dy + radius) * kernelDim + (dx + radius)] = exp(-d2 * invTwoSigmaS2)
            }
        }

        let invTwoSigmaC2: Float = 1.0 / (2.0 * sigmaColor * sigmaColor)
        var current = depthMap.disparity
        var next = [Float](repeating: 0, count: w * h)

        for _ in 0..<max(passes, 1) {
            for y in 0..<h {
                let rowOffset = y * w
                for x in 0..<w {
                    let centerIdx = rowOffset + x
                    let cRGB = centerIdx * 3
                    let cr = guideRGB[cRGB]
                    let cg = guideRGB[cRGB + 1]
                    let cb = guideRGB[cRGB + 2]

                    var weightedSum: Float = 0
                    var totalWeight: Float = 0

                    for dy in -radius...radius {
                        let sy = min(max(y + dy, 0), h - 1)
                        let sRow = sy * w
                        let kRow = (dy + radius) * kernelDim

                        for dx in -radius...radius {
                            // Circular horizontal 360° wrap so no vertical seam is introduced at u = 0 / 1
                            var sx = x + dx
                            if sx < 0 { sx += w }
                            else if sx >= w { sx -= w }

                            let sIdx = sRow + sx
                            let sRGB = sIdx * 3
                            let dr = guideRGB[sRGB] - cr
                            let dg = guideRGB[sRGB + 1] - cg
                            let db = guideRGB[sRGB + 2] - cb
                            let colorDist2 = dr * dr + dg * dg + db * db

                            let wSpatial = spatialWeights[kRow + (dx + radius)]
                            let wColor = exp(-colorDist2 * invTwoSigmaC2)
                            let weight = wSpatial * wColor

                            weightedSum += weight * current[sIdx]
                            totalWeight += weight
                        }
                    }

                    next[centerIdx] = totalWeight > 1e-6 ? (weightedSum / totalWeight) : current[centerIdx]
                }
            }
            swap(&current, &next)
        }

        // Convert refined disparity back into bounded metric radius R(u, v) in [1.5m, 60.0m]
        let metricRadius = remapDisparityToMetricRadius(
            disparity: current,
            depthScaleMeters: depthScaleMeters
        )

        return EquirectangularDepthMap(
            width: w,
            height: h,
            disparity: current,
            metricRadiusMeters: metricRadius
        )
    }

    private static func extractNormalizedRGBGuide(from image: CGImage, width: Int, height: Int) -> [Float]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: cs,
                    bitmapInfo: info
                  ) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        let count = width * height
        var rgb = [Float](repeating: 0, count: count * 3)
        let inv255: Float = 1.0 / 255.0
        for i in 0..<count {
            let s = i * 4
            let d = i * 3
            rgb[d] = Float(rgba[s]) * inv255
            rgb[d + 1] = Float(rgba[s + 1]) * inv255
            rgb[d + 2] = Float(rgba[s + 2]) * inv255
        }
        return rgb
    }

    private static func remapDisparityToMetricRadius(
        disparity: [Float],
        depthScaleMeters: Double
    ) -> [Float] {
        guard !disparity.isEmpty else { return [] }

        let strideStep = max(1, disparity.count / 8192)
        var samples: [Float] = []
        samples.reserveCapacity(8192)
        var idx = 0
        while idx < disparity.count {
            let v = disparity[idx]
            if v.isFinite { samples.append(v) }
            idx += strideStep
        }
        samples.sort()

        let pLow = Double(samples.isEmpty ? 0 : samples[Int(Double(samples.count - 1) * 0.02)])
        let pHigh = Double(samples.isEmpty ? 1 : samples[Int(Double(samples.count - 1) * 0.98)])
        let span = max(pHigh - pLow, 1e-5)

        let rNear = min(max(depthScaleMeters * 0.22, DepthStitcher.minMetricRadiusMeters), 20.0)
        let rFar = min(max(depthScaleMeters * 3.8, rNear + 2.5), DepthStitcher.maxMetricRadiusMeters)
        let invNear = 1.0 / rNear
        let invFar = 1.0 / rFar
        let invSpan = invNear - invFar

        var radii = [Float](repeating: Float(depthScaleMeters), count: disparity.count)
        for i in 0..<disparity.count {
            let d = disparity[i].isFinite ? Double(disparity[i]) : pLow
            let t = min(max((d - pLow) / span, 0.0), 1.0)
            let invR = invFar + t * invSpan
            let radius = min(max(1.0 / max(invR, 1e-6), DepthStitcher.minMetricRadiusMeters), DepthStitcher.maxMetricRadiusMeters)
            radii[i] = Float(radius)
        }
        return radii
    }
}
