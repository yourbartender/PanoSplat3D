import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import PanoSplat3DCore

@Suite("Equirectangular Slicer & COLMAP Dataset Export")
struct ColmapDatasetWriterTests {
    /// Creates a synthetic 2:1 equirectangular panorama encoding cardinal world directions as distinct colors:
    /// - Front (`-Z`, u ≈ 0.5, v ≈ 0.5) -> Red (255, 0, 0)
    /// - Right (`+X`, u ≈ 0.75, v ≈ 0.5) -> Green (0, 255, 0)
    /// - Zenith (`+Y`, v ≈ 0.0) -> Blue (0, 0, 255)
    private func makeSyntheticPanorama(width: Int = 512, height: Int = 256) throws -> PanoramaAsset {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)

                let offset = (y * width + x) * 4
                if dir.z > 0.75 {
                    // Front (+Z in COLMAP RDF) -> Red
                    rgba[offset] = 240; rgba[offset + 1] = 20; rgba[offset + 2] = 20
                } else if dir.x > 0.75 {
                    // Right (+X) -> Green
                    rgba[offset] = 20; rgba[offset + 1] = 240; rgba[offset + 2] = 20
                } else if dir.y < -0.75 {
                    // Zenith (-Y in COLMAP RDF) -> Blue
                    rgba[offset] = 20; rgba[offset + 1] = 20; rgba[offset + 2] = 240
                } else {
                    // Gradient background for edge importance sampling
                    rgba[offset] = UInt8(u * 200.0)
                    rgba[offset + 1] = UInt8(v * 200.0)
                    rgba[offset + 2] = 100
                }
                rgba[offset + 3] = 255
            }
        }

        let data = Data(rgba)
        let provider = try #require(CGDataProvider(data: data as CFData))
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

        return PanoramaAsset(
            sourceURL: URL(fileURLWithPath: "/tmp/synthetic_pano.png"),
            width: width,
            height: height,
            isHDR: false,
            fileSizeBytes: Int64(rgba.count),
            cgImage: image,
            thumbnail: image
        )
    }

    @Test("Metal/CPU slicer projects cardinal equirectangular colors upright without mirror or roll")
    func slicerOrientationAccuracy() throws {
        let pano = try makeSyntheticPanorama()
        let slicer = EquirectangularSlicer()
        if MTLCreateSystemDefaultDevice() != nil {
            #expect(slicer.isUsingMetal, "Expected Equirectangular.metal compute shader to compile and run on Metal GPU")
        }
        let intrinsics = PinholeCameraIntrinsics(width: 128, height: 128, fovDegrees: 90.0)

        // Forward camera (yaw=0, pitch=0) should see Red at image center
        let forwardPose = VirtualCameraPose(imageID: 1, name: "front.png", yawDegrees: 0, pitchDegrees: 0)
        let frontImage = try slicer.sliceSingleView(from: pano.cgImage, pose: forwardPose, intrinsics: intrinsics)
        let frontBytes = PanoramaLoader.extractRGBA8Bytes(from: frontImage)
        let centerIdx = (64 * 128 + 64) * 4
        #expect(frontBytes[centerIdx] > 200)
        #expect(frontBytes[centerIdx + 1] < 50)
        #expect(frontBytes[centerIdx + 2] < 50)

        // Right camera (yaw=+90, pitch=0) should see Green at image center
        let rightPose = VirtualCameraPose(imageID: 2, name: "right.png", yawDegrees: 90, pitchDegrees: 0)
        let rightImage = try slicer.sliceSingleView(from: pano.cgImage, pose: rightPose, intrinsics: intrinsics)
        let rightBytes = PanoramaLoader.extractRGBA8Bytes(from: rightImage)
        #expect(rightBytes[centerIdx] < 50)
        #expect(rightBytes[centerIdx + 1] > 200)
        #expect(rightBytes[centerIdx + 2] < 50)

        // Zenith camera (yaw=0, pitch=+90) should see Blue at image center
        let zenithPose = VirtualCameraPose(imageID: 3, name: "up.png", yawDegrees: 0, pitchDegrees: 90)
        let zenithImage = try slicer.sliceSingleView(from: pano.cgImage, pose: zenithPose, intrinsics: intrinsics)
        let zenithBytes = PanoramaLoader.extractRGBA8Bytes(from: zenithImage)
        #expect(zenithBytes[centerIdx] < 50)
        #expect(zenithBytes[centerIdx + 1] < 50)
        #expect(zenithBytes[centerIdx + 2] > 200)
    }

    @Test("ColmapDatasetWriter outputs complete dataset folder, COLMAP txt files, and binary init.ply")
    func fullDatasetExport() throws {
        let pano = try makeSyntheticPanorama()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoSplat3D-DatasetTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = GenerationSettings(
            depthScaleMeters: 10.0,
            perspectiveResolution: 256,
            fieldOfViewDegrees: 96.0,
            initialPointCount: 2_500
        )

        let writer = ColmapDatasetWriter()
        let result = try writer.writeDataset(from: pano, to: tempDir, settings: settings)

        #expect(result.imageCount == 20)
        #expect(result.pointCount == 2_500)

        let fm = FileManager.default
        for i in 0..<20 {
            let imgPath = result.imagesDirectory.appendingPathComponent(String(format: "view_%03d.png", i)).path
            #expect(fm.fileExists(atPath: imgPath))
        }

        let camerasTxt = try String(contentsOf: result.sparseDirectory.appendingPathComponent("cameras.txt"), encoding: .utf8)
        #expect(camerasTxt.contains("1 SIMPLE_PINHOLE 256 256"))

        let imagesTxt = try String(contentsOf: result.sparseDirectory.appendingPathComponent("images.txt"), encoding: .utf8)
        #expect(imagesTxt.contains("view_000.png"))
        #expect(imagesTxt.contains("view_019.png"))

        let points3DTxt = try String(contentsOf: result.sparseDirectory.appendingPathComponent("points3D.txt"), encoding: .utf8)
        #expect(points3DTxt.contains("Number of points: 0"))

        // Validate binary PLY header & exact payload size (header + 2500 * 15 bytes)
        let plyData = try Data(contentsOf: result.initPLYURL)
        let endHeaderMarker = Data("end_header\n".utf8)
        let markerRange = try #require(plyData.range(of: endHeaderMarker))
        let headerString = try #require(String(data: plyData[..<markerRange.upperBound], encoding: .utf8))
        #expect(headerString.contains("format binary_little_endian 1.0"))
        #expect(headerString.contains("element vertex 2500"))
        let binaryPayloadSize = plyData.count - markerRange.upperBound
        #expect(binaryPayloadSize == 2_500 * 15)
    }
}
