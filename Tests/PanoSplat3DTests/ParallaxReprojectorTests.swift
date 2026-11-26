import CoreGraphics
import Foundation
import Metal
import Testing
import simd
@testable import PanoSplat3DCore

@Suite("Multi-Position Parallax Rig & Metal Z-Buffer Disocclusion Re-Projection")
struct ParallaxReprojectorTests {
    @Test("makeParallaxRig builds 20 center views + 24 two-ring offset views (44 total) with valid SO(3) poses")
    func parallaxRigGeometry() {
        let baseline = 0.75
        let poses = CameraRigGenerator.makeParallaxRig(baselineMeters: baseline)
        #expect(poses.count == 44)

        let centerPoses = poses.prefix(20)
        let innerRing = poses[20..<32]
        let outerRing = poses[32..<44]
        #expect(centerPoses.count == 20)
        #expect(innerRing.count == 12)
        #expect(outerRing.count == 12)

        for pose in centerPoses {
            #expect(simd_length(pose.worldPosition) < 1e-6)
            #expect(abs(simd_determinant(pose.worldToCameraRotation) - 1.0) < 1e-6)
        }

        for pose in innerRing {
            let horizRadius = hypot(pose.worldPosition.x, pose.worldPosition.z)
            #expect(abs(horizRadius - baseline * 0.50) < 1e-6)
            #expect(abs(simd_determinant(pose.worldToCameraRotation) - 1.0) < 1e-6)
        }

        for pose in outerRing {
            let horizRadius = hypot(pose.worldPosition.x, pose.worldPosition.z)
            #expect(abs(horizRadius - baseline) < 1e-6)
            #expect(abs(simd_determinant(pose.worldToCameraRotation) - 1.0) < 1e-6)
        }

        // Zero baseline collapses cleanly to 20 center views
        let zeroBaselinePoses = CameraRigGenerator.makeParallaxRig(baselineMeters: 0.0)
        #expect(zeroBaselinePoses.count == 20)
    }

    @Test("Metal Z-buffer parallax re-projection creates black disocclusion holes behind a foreground pillar")
    func zBufferParallaxAndDisocclusionMask() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        // Build a synthetic 2:1 panorama & depth map with a close foreground pillar (3m) in front (-Z, u in [0.44, 0.56])
        // against a distant background wall (20m) everywhere else.
        let panoW = 512
        let panoH = 256
        var rgba = [UInt8](repeating: 255, count: panoW * panoH * 4)
        var radii = [Float](repeating: 20.0, count: panoW * panoH)
        var disp = [Float](repeating: 1.0 / 20.0, count: panoW * panoH)

        for y in 0..<panoH {
            let v = (Double(y) + 0.5) / Double(panoH)
            for x in 0..<panoW {
                let u = (Double(x) + 0.5) / Double(panoW)
                let idx = y * panoW + x
                let off = idx * 4
                let isForegroundPillar = (u >= 0.44 && u <= 0.56 && v >= 0.25 && v <= 0.75)
                if isForegroundPillar {
                    // Red foreground pillar at 3.0m
                    rgba[off] = 240; rgba[off + 1] = 30; rgba[off + 2] = 30; rgba[off + 3] = 255
                    radii[idx] = 3.0
                    disp[idx] = 1.0 / 3.0
                } else {
                    // Blue distant background at 20.0m
                    rgba[off] = 30; rgba[off + 1] = 90; rgba[off + 2] = 230; rgba[off + 3] = 255
                    radii[idx] = 20.0
                    disp[idx] = 1.0 / 20.0
                }
            }
        }

        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let panoImage = try #require(CGImage(
            width: panoW,
            height: panoH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: panoW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))

        let depthMap = EquirectangularDepthMap(
            width: panoW,
            height: panoH,
            disparity: disp,
            metricRadiusMeters: radii
        )

        let reprojector = try ParallaxReprojector()
        let intrinsics = PinholeCameraIntrinsics(width: 256, height: 256, fovDegrees: 96.0)

        // Shift camera +0.8m to the RIGHT (+X), looking straight ahead (-Z)
        let rightShiftedPose = VirtualCameraPose(
            imageID: 13,
            name: "view_012.png",
            worldPosition: SIMD3<Double>(0.8, 0.0, 0.0),
            yawDegrees: 0.0,
            pitchDegrees: 0.0
        )

        var rendered: ReprojectedViewResult?
        try reprojector.reprojectViews(
            panoramaImage: panoImage,
            depthMap: depthMap,
            poses: [rightShiftedPose],
            intrinsics: intrinsics,
            meshWidth: 256,
            meshHeight: 128,
            depthTearRatio: 1.15,
            maskErosionRadius: 1
        ) { _, _, result in
            rendered = result
        }

        let view = try #require(rendered)
        // Must have a genuine disocclusion hole (validPixelFraction < 0.99) AND mostly valid pixels (> 0.70)
        #expect(view.validPixelFraction < 0.99, "Expected black disocclusion mask pixels behind shifted foreground pillar")
        #expect(view.validPixelFraction > 0.70, "Expected majority of re-projected frame to remain valid white pixels")

        // Verify parallax shift: since camera moved RIGHT (+0.8m), the close 3m red pillar shifts LEFT in image space
        let colorBytes = PanoramaLoader.extractRGBA8Bytes(from: view.colorImage)
        var redXSum = 0.0
        var redCount = 0
        for y in 64..<192 {
            for x in 0..<256 {
                let off = (y * 256 + x) * 4
                if colorBytes[off] > 180 && colorBytes[off + 2] < 80 {
                    redXSum += Double(x)
                    redCount += 1
                }
            }
        }
        #expect(redCount > 100)
        let meanRedX = redXSum / Double(redCount)
        #expect(meanRedX < 120.0, "Foreground pillar should shift left (< 128px) when camera translates right (+X); got \(meanRedX)")
    }

    @Test("ColmapDatasetWriter writes masks/ folder and 28 views when depthMap and baseline > 0 are provided")
    func fullParallaxDatasetExport() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let panoW = 256
        let panoH = 128
        let rgba = [UInt8](repeating: 140, count: panoW * panoH * 4)
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let image = try #require(CGImage(
            width: panoW,
            height: panoH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: panoW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))

        let asset = PanoramaAsset(
            sourceURL: URL(fileURLWithPath: "/tmp/parallax_test.png"),
            width: panoW,
            height: panoH,
            isHDR: false,
            fileSizeBytes: Int64(rgba.count),
            cgImage: image,
            thumbnail: image
        )

        var radii = [Float](repeating: 12.0, count: panoW * panoH)
        var disp = [Float](repeating: 1.0 / 12.0, count: panoW * panoH)
        for y in 32..<96 {
            for x in 100..<140 {
                radii[y * panoW + x] = 3.5
                disp[y * panoW + x] = 1.0 / 3.5
            }
        }
        let depthMap = EquirectangularDepthMap(width: panoW, height: panoH, disparity: disp, metricRadiusMeters: radii)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoSplat3D-ParallaxDataset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = GenerationSettings(
            depthScaleMeters: 12.0,
            parallaxBaselineMeters: 0.75,
            perspectiveResolution: 128,
            initialPointCount: 1_000
        )

        let writer = ColmapDatasetWriter()
        let result = try writer.writeDataset(from: asset, depthMap: depthMap, to: tempDir, settings: settings)

        #expect(result.imageCount == 44)
        #expect(result.parallaxViewCount == 24)
        let masksDir = try #require(result.masksDirectory)

        let fm = FileManager.default
        for i in 0..<44 {
            let name = String(format: "view_%03d.png", i)
            #expect(fm.fileExists(atPath: result.imagesDirectory.appendingPathComponent(name).path))
            #expect(fm.fileExists(atPath: masksDir.appendingPathComponent(name).path))
        }
    }

    @Test("Flat 1.7m tripod ground plane stays intact (no horizontal grazing-angle tear) in offset parallax views")
    func flatGroundPlanePreservedWithoutHorizontalHole() throws {
        let panoW = 512
        let panoH = 256
        var rgba = [UInt8](repeating: 255, count: panoW * panoH * 4)
        var radii = [Float](repeating: 40.0, count: panoW * panoH)
        var disp = [Float](repeating: 1.0 / 40.0, count: panoW * panoH)

        // Realistic 1.7m tripod above an infinite flat ground plane (y = +1.7m in COLMAP RDF)
        for y in 0..<panoH {
            let v = (Double(y) + 0.5) / Double(panoH)
            let dirSample = SphericalMath.equirectangularUVToWorldDirection(u: 0.5, v: v)
            let r: Float
            if dirSample.y > 0.04 {
                r = Float(min(max(1.7 / dirSample.y, 1.7), 40.0))
            } else {
                r = 40.0
            }
            for x in 0..<panoW {
                radii[y * panoW + x] = r
                disp[y * panoW + x] = 1.0 / r
                let idx = (y * panoW + x) * 4
                rgba[idx] = dirSample.y > 0 ? 220 : 120
                rgba[idx + 1] = dirSample.y > 0 ? 225 : 170
                rgba[idx + 2] = dirSample.y > 0 ? 235 : 240
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(
            width: panoW,
            height: panoH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: panoW * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!

        let depthMap = EquirectangularDepthMap(width: panoW, height: panoH, disparity: disp, metricRadiusMeters: radii)
        let intrinsics = PinholeCameraIntrinsics(cameraID: 1, width: 256, height: 256, fovDegrees: 82.0)
        let offsetPose = VirtualCameraPose(
            imageID: 1,
            name: "ground_check.png",
            cameraID: 1,
            worldPosition: SIMD3<Double>(0.5, 0.0, 0.0),
            yawDegrees: 0,
            pitchDegrees: 0
        )

        let reprojector = try ParallaxReprojector()
        var validFraction = 0.0
        try reprojector.reprojectViews(
            panoramaImage: image,
            depthMap: depthMap,
            poses: [offsetPose],
            intrinsics: intrinsics,
            meshWidth: 512,
            meshHeight: 256
        ) { _, _, res in
            validFraction = res.validPixelFraction
        }

        // Ground plane at shallow 5°–12° grazing angles must stay intact (> 95% valid instead of torn away!)
        #expect(validFraction > 0.95, "Expected flat ground plane to stay >95% intact, got \(Int(validFraction * 100))%")
    }
}
