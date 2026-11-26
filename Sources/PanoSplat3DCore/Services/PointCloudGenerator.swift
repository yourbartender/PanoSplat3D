import CoreGraphics
import Foundation
import simd

/// A colored 3D point in **+Y Up** right-handed world space (`init.ply`).
public struct ColoredPoint3D: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(position: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8) {
        self.position = position
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Fast deterministic SplitMix64 PRNG for reproducible importance sampling.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    mutating func nextDouble01() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / Double(1 << 53))
    }
}

/// Generates a gradient-importance-sampled 3D point cloud from a 2:1 equirectangular panorama.
/// Edges and architectural/foliage silhouettes receive dense points while uniform areas (such as sky)
/// receive sparser points, weighted by `sin(polarAngle)` so equirectangular poles do not clump.
public enum PointCloudGenerator {
    /// Samples `targetPointCount` 3D points in +Y Up world space.
    /// - Parameters:
    ///   - image: Source equirectangular `CGImage` (RGBA8 sRGB).
    ///   - targetPointCount: Number of points to generate (default ~150,000 per SPEC Section 2.B).
    ///   - radiusAtUV: Metric radius `R(u, v)` in meters for each `(u, v)` sample.
    ///     In Milestone 1 this is uniform `depthScaleMeters`; in Milestone 2 it reads the CoreML metric depth map.
    ///   - seed: Deterministic PRNG seed.
    public static func generate(
        from image: CGImage,
        targetPointCount: Int,
        radiusAtUV: (Double, Double) -> Double,
        seedBackgroundBehindOccluders: Bool = false,
        seed: UInt64 = 0x5041_4E4F_3344_0001
    ) -> [ColoredPoint3D] {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1, targetPointCount > 0 else { return [] }

        let rgba = PanoramaLoader.extractRGBA8Bytes(from: image)

        // Downsample luminance grid for fast CDF construction when source panorama is very large (e.g. 8K/16K)
        let gridWidth = min(width, 1024)
        let gridHeight = min(height, 512)
        let cellCount = gridWidth * gridHeight

        var luminance = [Float](repeating: 0, count: cellCount)
        var radiusGrid = [Double](repeating: 12.0, count: cellCount)
        for gy in 0..<gridHeight {
            let sy = min(height - 1, (gy * height) / gridHeight)
            let vCenter = (Double(gy) + 0.5) / Double(gridHeight)
            let rowOffset = gy * gridWidth
            for gx in 0..<gridWidth {
                let sx = min(width - 1, (gx * width) / gridWidth)
                let uCenter = (Double(gx) + 0.5) / Double(gridWidth)
                let idx = (sy * width + sx) * 4
                let r = Float(rgba[idx])
                let g = Float(rgba[idx + 1])
                let b = Float(rgba[idx + 2])
                luminance[rowOffset + gx] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
                radiusGrid[rowOffset + gx] = radiusAtUV(uCenter, vCenter)
            }
        }

        // Build cumulative distribution over cells weighted by:
        //   spherical solid angle * (base + RGB edge gradient) * flying-pixel depth-cliff suppressor
        // Suppressing points on sharp depth discontinuities prevents seeding floating dark Gaussians in mid-air!
        var cdf = [Double](repeating: 0, count: cellCount)
        var runningTotal: Double = 0

        for gy in 0..<gridHeight {
            let vCenter = (Double(gy) + 0.5) / Double(gridHeight)
            let polarAngle = vCenter * .pi
            let solidAngleWeight = max(sin(polarAngle), 0.02)

            let ym = max(0, gy - 1)
            let yp = min(gridHeight - 1, gy + 1)

            for gx in 0..<gridWidth {
                let xm = (gx - 1 + gridWidth) % gridWidth
                let xp = (gx + 1) % gridWidth

                let rC = radiusGrid[gy * gridWidth + gx]
                let rL = radiusGrid[gy * gridWidth + xm]
                let rR = radiusGrid[gy * gridWidth + xp]
                let rU = radiusGrid[ym * gridWidth + gx]
                let rD = radiusGrid[yp * gridWidth + gx]

                let rMin = max(min(rC, min(min(rL, rR), min(rU, rD))), 0.1)
                let rMax = max(rC, max(max(rL, rR), max(rU, rD)))
                let depthJumpRatio = rMax / rMin

                // Suppress cells sitting on sharp depth cliffs (> 6% jump across adjacent cells)
                let cliffFactor: Double
                if depthJumpRatio >= 1.07 {
                    cliffFactor = 0.0
                } else if depthJumpRatio > 1.03 {
                    cliffFactor = 1.0 - (depthJumpRatio - 1.03) / 0.04
                } else {
                    cliffFactor = 1.0
                }

                let dx = luminance[gy * gridWidth + xp] - luminance[gy * gridWidth + xm]
                let dy = luminance[yp * gridWidth + gx] - luminance[ym * gridWidth + gx]
                let gradMag = sqrt(Double(dx * dx + dy * dy))

                // Uniform baseline (0.20) guarantees sky/walls/snow get clean coverage;
                // sharp RGB texture edges on continuous surfaces get high density, while mid-air depth cliffs get 0.
                let weight = solidAngleWeight * (0.20 + 3.2 * gradMag) * cliffFactor
                runningTotal += weight
                cdf[gy * gridWidth + gx] = runningTotal
            }
        }

        guard runningTotal > 0 else { return [] }

        var rng = SplitMix64(seed: seed)
        var points: [ColoredPoint3D] = []
        points.reserveCapacity(targetPointCount)

        let invGridWidth = 1.0 / Double(gridWidth)
        let invGridHeight = 1.0 / Double(gridHeight)

        for _ in 0..<targetPointCount {
            let target = rng.nextDouble01() * runningTotal

            // Binary search in CDF
            var low = 0
            var high = cellCount - 1
            while low < high {
                let mid = (low + high) >> 1
                if cdf[mid] < target {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            let gy = low / gridWidth
            let gx = low - gy * gridWidth

            // Jitter sub-cell position to avoid regular grid aliasing
            let u = (Double(gx) + rng.nextDouble01()) * invGridWidth
            let v = min(max((Double(gy) + rng.nextDouble01()) * invGridHeight, 1e-4), 1.0 - 1e-4)

            let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)
            let radius = radiusAtUV(u, v)
            let worldPos = SIMD3<Float>(
                Float(dir.x * radius),
                Float(dir.y * radius),
                Float(dir.z * radius)
            )

            // Bilinearly sample source RGB color at full panorama resolution for clean alias-free Gaussian initialization
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

            let i00 = (cy0 * width + wx0) * 4
            let i10 = (cy0 * width + wx1) * 4
            let i01 = (cy1 * width + wx0) * 4
            let i11 = (cy1 * width + wx1) * 4

            let w00 = (1.0 - tx) * (1.0 - ty)
            let w10 = tx * (1.0 - ty)
            let w01 = (1.0 - tx) * ty
            let w11 = tx * ty

            let rF = Double(rgba[i00]) * w00 + Double(rgba[i10]) * w10 + Double(rgba[i01]) * w01 + Double(rgba[i11]) * w11
            let gF = Double(rgba[i00 + 1]) * w00 + Double(rgba[i10 + 1]) * w10 + Double(rgba[i01 + 1]) * w01 + Double(rgba[i11 + 1]) * w11
            let bF = Double(rgba[i00 + 2]) * w00 + Double(rgba[i10 + 2]) * w10 + Double(rgba[i01 + 2]) * w01 + Double(rgba[i11 + 2]) * w11

            points.append(
                ColoredPoint3D(
                    position: worldPos,
                    r: UInt8(min(max(rF.rounded(), 0), 255)),
                    g: UInt8(min(max(gF.rounded(), 0), 255)),
                    b: UInt8(min(max(bF.rounded(), 0), 255))
                )
            )
        }

        // Optional Layer-2 background seeding behind foreground occluders (trees, rocks, pillars)
        // Gives Brush an immediate background-depth Gaussian seed when LaMa disocclusion hole-filling is enabled.
        if seedBackgroundBehindOccluders {
            let maxBgPoints = max(500, targetPointCount / 8)
            var bgCandidates: [(gx: Int, gy: Int, farRadius: Double, farGX: Int)] = []
            bgCandidates.reserveCapacity(16_384)
            let searchOffsets = [-16, -10, -5, 5, 10, 16]

            for gy in stride(from: 2, to: gridHeight - 2, by: 2) {
                let rowOff = gy * gridWidth
                for gx in stride(from: 0, to: gridWidth, by: 2) {
                    let rC = radiusGrid[rowOff + gx]
                    var bestFar = rC
                    var bestFarGX = gx
                    for dx in searchOffsets {
                        let nx = (gx + dx + gridWidth) % gridWidth
                        let rN = radiusGrid[rowOff + nx]
                        if rN > bestFar {
                            bestFar = rN
                            bestFarGX = nx
                        }
                    }
                    // Foreground occluder: sits at least ~28% closer than adjacent background
                    if rC < bestFar * 0.72 && bestFar - rC >= 1.2 {
                        bgCandidates.append((gx, gy, bestFar, bestFarGX))
                    }
                }
            }

            if !bgCandidates.isEmpty {
                let bgSampleCount = min(maxBgPoints, bgCandidates.count * 2)
                points.reserveCapacity(points.count + bgSampleCount)
                for _ in 0..<bgSampleCount {
                    let pick = bgCandidates[Int(rng.nextUInt64() % UInt64(bgCandidates.count))]
                    let u = (Double(pick.gx) + rng.nextDouble01()) * invGridWidth
                    let v = min(max((Double(pick.gy) + rng.nextDouble01()) * invGridHeight, 1e-4), 1.0 - 1e-4)
                    let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)
                    let worldPos = SIMD3<Float>(
                        Float(dir.x * pick.farRadius),
                        Float(dir.y * pick.farRadius),
                        Float(dir.z * pick.farRadius)
                    )

                    let farU = (Double(pick.farGX) + 0.5) * invGridWidth
                    let px = min(width - 1, max(0, Int((farU * Double(width)).rounded(.down))))
                    let py = min(height - 1, max(0, Int((v * Double(height)).rounded(.down))))
                    let cIdx = (py * width + px) * 4
                    points.append(
                        ColoredPoint3D(
                            position: worldPos,
                            r: rgba[cIdx],
                            g: rgba[cIdx + 1],
                            b: rgba[cIdx + 2]
                        )
                    )
                }
            }
        }

        return points
    }
}
