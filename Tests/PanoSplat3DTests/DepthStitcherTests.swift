import CoreGraphics
import Foundation
import Testing
import simd
@testable import PanoSplat3DCore

@Suite("360° Depth Stitching, Least-Squares Alignment & Depth-Displaced Point Cloud")
struct DepthStitcherTests {
    /// Analytical 3D scene distance field in COLMAP RDF: closer in front (+Z) & below (+Y), farther in back (-Z) & sky (-Y).
    private func syntheticWorldRadius(for dir: SIMD3<Double>) -> Double {
        let d = simd_normalize(dir)
        // Smooth positive distance in [3.0m, 25.0m]
        return 10.0 - 6.0 * d.z - 5.0 * d.y + 2.0 * d.x
    }

    @Test("Least-squares edge alignment removes per-face scale/shift offsets and stitches seamlessly across 360° wrap")
    func leastSquaresAlignmentAndSeamlessStitch() {
        let faceSize = 96
        let fov = 95.0
        let tanHalf = tan((fov * 0.5) * (.pi / 180.0))

        // Arbitrary distinct unknown scale & shift per face (simulating monocular scale/shift ambiguity)
        let syntheticScales: [Double] = [1.0, 2.3, 0.55, 1.75, 0.8, 1.45]
        let syntheticShifts: [Double] = [0.2, -0.4, 1.1, 0.65, -0.25, 0.9]

        var faces: [CubemapFaceDisparity] = []
        for kind in CubemapFaceKind.allCases {
            let pose = kind.makeCameraPose()
            let scale = syntheticScales[kind.rawValue]
            let shift = syntheticShifts[kind.rawValue]
            var values = [Float](repeating: 0, count: faceSize * faceSize)

            for y in 0..<faceSize {
                let ny = (2.0 * ((Double(y) + 0.5) / Double(faceSize)) - 1.0) * tanHalf
                for x in 0..<faceSize {
                    let nx = (2.0 * ((Double(x) + 0.5) / Double(faceSize)) - 1.0) * tanHalf
                    let worldDir = simd_normalize(nx * pose.cameraRight + ny * pose.cameraDown + pose.cameraForward)
                    let cosGamma = simd_dot(worldDir, pose.cameraForward)
                    let trueRadius = syntheticWorldRadius(for: worldDir)
                    // True planar Z-depth = R * cosGamma -> planar disparity = 1 / (R * cosGamma)
                    let planarDisp = 1.0 / (trueRadius * cosGamma)
                    // Perturb in radial-equivalent domain and map back to planar disparity
                    let perturbedPlanar = (scale * (planarDisp * cosGamma) + shift) / cosGamma
                    values[y * faceSize + x] = Float(max(perturbedPlanar, 0.001))
                }
            }

            faces.append(
                CubemapFaceDisparity(
                    face: kind,
                    pose: pose,
                    fovDegrees: fov,
                    width: faceSize,
                    height: faceSize,
                    values: values
                )
            )
        }

        let depthMap = DepthStitcher.stitch(
            faces: faces,
            outputWidth: 256,
            outputHeight: 128,
            depthScaleMeters: 12.0
        )

        #expect(depthMap.width == 256)
        #expect(depthMap.height == 128)
        #expect(depthMap.metricRadiusMeters.count == 256 * 128)

        // Check strict metric radius bounds [1.5m, 60.0m]
        for r in depthMap.metricRadiusMeters {
            #expect(r >= 1.5 - 1e-4)
            #expect(r <= 60.0 + 1e-4)
        }

        // Check seam continuity across the 0°/360° wrap meridian (x = 0 vs x = width - 1)
        var maxWrapDiff: Float = 0
        for y in 16..<(depthMap.height - 16) {
            let leftVal = depthMap.metricRadiusMeters[y * depthMap.width]
            let rightVal = depthMap.metricRadiusMeters[y * depthMap.width + (depthMap.width - 1)]
            maxWrapDiff = max(maxWrapDiff, abs(leftVal - rightVal))
        }
        #expect(maxWrapDiff < 1.0, "Expected seamless wrap across u=0 / u=1 meridian, got jump \(maxWrapDiff)m")

        // Check physical ordering: Front (-Z, u=0.5, v=0.5) had smaller true radius than Back (+Z, u=0.0, v=0.5)
        let frontRadius = depthMap.radius(u: 0.5, v: 0.5)
        let backRadius = depthMap.radius(u: 0.0, v: 0.5)
        #expect(frontRadius < backRadius, "Foreground (-Z) should be closer than background (+Z)")

        // Check colorized preview generation
        let preview = depthMap.makeColorizedPreviewCGImage()
        #expect(preview != nil)
        #expect(preview?.width == 256)
        #expect(preview?.height == 128)
    }

    @Test("12-face 105° horizon-anchored depth stitcher eliminates ±45° cube edges and bright ground steps")
    func twelveFaceSeamlessAlignment() {
        let faceSpecs = DepthSamplingFace.standard12Faces
        #expect(faceSpecs.count == 12)

        let faceSize = 80
        var faces: [CubemapFaceDisparity] = []

        for spec in faceSpecs {
            let pose = spec.makeCameraPose()
            let tanHalf = tan((spec.fovDegrees * 0.5) * (.pi / 180.0))
            // Deliberately give lower faces extreme different scale & shift to stress-test global-mean gauge solver
            let scale = 0.4 + 0.35 * Double(spec.index % 5)
            let shift = -0.3 + 0.25 * Double(spec.index % 4)
            var values = [Float](repeating: 0, count: faceSize * faceSize)

            for y in 0..<faceSize {
                let ny = (2.0 * ((Double(y) + 0.5) / Double(faceSize)) - 1.0) * tanHalf
                for x in 0..<faceSize {
                    let nx = (2.0 * ((Double(x) + 0.5) / Double(faceSize)) - 1.0) * tanHalf
                    let worldDir = simd_normalize(nx * pose.cameraRight + ny * pose.cameraDown + pose.cameraForward)
                    let cosGamma = simd_dot(worldDir, pose.cameraForward)
                    let trueRadius = syntheticWorldRadius(for: worldDir)
                    let radialDisp = 1.0 / trueRadius
                    let perturbedPlanar = (scale * radialDisp + shift + 2.0) / cosGamma
                    values[y * faceSize + x] = Float(max(perturbedPlanar, 0.001))
                }
            }

            faces.append(
                CubemapFaceDisparity(
                    faceIndex: spec.index,
                    pose: pose,
                    fovDegrees: spec.fovDegrees,
                    width: faceSize,
                    height: faceSize,
                    values: values
                )
            )
        }

        let depthMap = DepthStitcher.stitch(
            faces: faces,
            outputWidth: 256,
            outputHeight: 128,
            depthScaleMeters: 12.0
        )

        // Verify smooth gradients everywhere across the lower hemisphere (no sharp step edges along ±45°!)
        var maxNeighborJump: Float = 0
        for y in 20..<(depthMap.height - 20) {
            for x in 0..<(depthMap.width - 1) {
                let a = depthMap.metricRadiusMeters[y * depthMap.width + x]
                let b = depthMap.metricRadiusMeters[y * depthMap.width + x + 1]
                maxNeighborJump = max(maxNeighborJump, abs(a - b))
            }
        }
        #expect(maxNeighborJump < 1.2, "Expected smooth 12-face depth map without sharp cube seams; max pixel jump was \(maxNeighborJump)m")
    }

    @Test("RGB-guided DepthEdgeRefiner preserves sharp foreground-background edge without blurring across color boundary")
    func rgbGuidedDepthEdgeRefiner() throws {
        let w = 128
        let h = 64
        // Left half dark tree trunk (RGB 20), right half bright snow (RGB 240)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var disp = [Float](repeating: 0.1, count: w * h)
        var rad = [Float](repeating: 20.0, count: w * h)

        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let off = idx * 4
                let isDarkTrunk = (x >= 40 && x < 70)
                let col: UInt8 = isDarkTrunk ? 20 : 240
                rgba[off] = col; rgba[off + 1] = col; rgba[off + 2] = col; rgba[off + 3] = 255
                disp[idx] = isDarkTrunk ? 0.9 : 0.1
                rad[idx] = isDarkTrunk ? 3.0 : 25.0
            }
        }

        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let img = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4, space: cs, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))

        let inputMap = EquirectangularDepthMap(width: w, height: h, disparity: disp, metricRadiusMeters: rad)
        let refined = DepthEdgeRefiner.refine(depthMap: inputMap, guidedBy: img, depthScaleMeters: 12.0)

        // Immediately adjacent pixels on opposite sides of the dark-trunk/bright-snow edge must stay sharply separated
        let trunkEdgeRadius = refined.metricRadiusMeters[32 * w + 69]
        let snowEdgeRadius = refined.metricRadiusMeters[32 * w + 70]
        #expect(snowEdgeRadius > trunkEdgeRadius * 3.0, "Expected sharp RGB-guided depth edge; got trunk=\(trunkEdgeRadius)m vs snow=\(snowEdgeRadius)m")
    }

    @Test("Depth-displaced PointCloudGenerator places foreground points closer to origin than background points")
    func depthDisplacedPointCloud() throws {
        let width = 128
        let height = 64
        // Checkerboard texture so gradient importance sampling samples both front and back hemispheres
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let checker: UInt8 = ((x / 4 + y / 4) % 2 == 0) ? 230 : 30
                let offset = (y * width + x) * 4
                rgba[offset] = checker
                rgba[offset + 1] = checker
                rgba[offset + 2] = checker
                rgba[offset + 3] = 255
            }
        }

        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        // Foreground in center (u in [0.35, 0.65] -> -Z hemisphere) at 3m; background at 30m
        let points = PointCloudGenerator.generate(
            from: image,
            targetPointCount: 2_000,
            radiusAtUV: { u, _ in
                (u >= 0.35 && u <= 0.65) ? 3.0 : 30.0
            }
        )

        #expect(points.count == 2_000)

        let frontPoints = points.filter { $0.position.z > 0.5 && abs($0.position.x) < abs($0.position.z) * 0.5 }
        let backPoints = points.filter { $0.position.z < -0.5 && abs($0.position.x) < abs($0.position.z) * 0.5 }
        #expect(!frontPoints.isEmpty)
        #expect(!backPoints.isEmpty)

        let avgFrontDist = frontPoints.map { simd_length($0.position) }.reduce(0, +) / Float(frontPoints.count)
        let avgBackDist = backPoints.map { simd_length($0.position) }.reduce(0, +) / Float(backPoints.count)
        #expect(abs(avgFrontDist - 3.0) < 0.25)
        #expect(abs(avgBackDist - 30.0) < 0.5)
    }

    @Test("Live CoreML DepthAnythingV2SmallF16 download, compile, and 360° inference (opt-in via PANOSPLAT_LIVE_COREML=1)")
    func liveCoreMLDepthEstimation() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_COREML"] == "1" else {
            return
        }

        // Synthesize a 512x256 equirectangular scene with sky top, horizon band, and textured ground bottom
        let width = 512
        let height = 256
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = Double(y) / Double(height)
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if v < 0.45 {
                    // Blue sky gradient
                    rgba[offset] = 120; rgba[offset + 1] = 175; rgba[offset + 2] = 240
                } else if v < 0.55 {
                    // Distant horizon silhouettes
                    let stripe = ((x / 16) % 2 == 0) ? UInt8(90) : UInt8(60)
                    rgba[offset] = stripe; rgba[offset + 1] = stripe + 10; rgba[offset + 2] = stripe
                } else {
                    // Textured foreground ground
                    let checker = ((x / 8 + y / 8) % 2 == 0) ? UInt8(165) : UInt8(115)
                    rgba[offset] = checker; rgba[offset + 1] = checker - 15; rgba[offset + 2] = 85
                }
                rgba[offset + 3] = 255
            }
        }

        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let image = try #require(CGImage(
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
        ))

        let asset = PanoramaAsset(
            sourceURL: URL(fileURLWithPath: "/tmp/live_depth_test.png"),
            width: width,
            height: height,
            isHDR: false,
            fileSizeBytes: Int64(rgba.count),
            cgImage: image,
            thumbnail: image
        )

        let estimator = DepthEstimator()
        let depthMap = try await estimator.estimate360Depth(
            from: asset,
            depthScaleMeters: 12.0,
            outputWidth: 512,
            outputHeight: 256
        )

        #expect(depthMap.width == 512)
        #expect(depthMap.height == 256)
        #expect(depthMap.minRadiusMeters >= 1.5 - 1e-3)
        #expect(depthMap.maxRadiusMeters <= 60.0 + 1e-3)
        #expect(depthMap.maxRadiusMeters > depthMap.minRadiusMeters + 1.0)
        #expect(depthMap.makeColorizedPreviewCGImage() != nil)
    }
}
