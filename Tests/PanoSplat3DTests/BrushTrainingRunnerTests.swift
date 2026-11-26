import CoreGraphics
import Foundation
import Metal
import Testing
@testable import PanoSplat3DCore

@Suite("Brush Headless Runner, Progress Parser & SuperSplat PLY Export")
struct BrushTrainingRunnerTests {
    @Test("Parses ANSI PTY step progress, ETA, and splat count from Brush output")
    func parseBrushPTYProgress() {
        let sample = """
        \u{001B}[4A\r\u{001B}[2K🖌️ Training\r
        [12s] ◍◍◍◍◍◍◍◍○○     245/5000     Steps (110.5483/s, 43s remaining)\r
        ✅ evaluating every 1000 steps\r
        ℹ️ Current splat count 152400
        """

        let parsed = BrushTrainingRunner.parseProgressChunk(
            sample,
            fallbackTotalSteps: 5000,
            previousSplatCount: nil
        )
        #expect(parsed != nil)
        #expect(parsed?.currentStep == 245)
        #expect(parsed?.totalSteps == 5000)
        #expect(parsed?.splatCount == 152_400)
        #expect(parsed?.rateAndETA == "110.5483/s, 43s remaining")
    }

    @Test("Shortens long AI-generated panorama filenames cleanly for default output paths")
    @MainActor
    func sanitizedShortName() {
        let longPrompt = "transform_this_set_of_images_into_an_equirectangular_360_panorama___scene__a_snowy_pine_forest_in_lapland_with_extraordinary_ancient_alien_architecture_under_soft_overcast_blue_late_aft_4081245080"
        let short = NativeFileDialogs.sanitizedShortBaseName(from: longPrompt)
        #expect(short.count <= 36)
        #expect(!short.isEmpty)
        #expect(!short.contains("__"))
    }

    @Test("Locates bundled coin.wav completion alert sound cleanly")
    @MainActor
    func locatesCoinSound() {
        let soundURL = SoundAlertService.locateSuccessSoundURL()
        #expect(soundURL != nil)
        #expect(soundURL?.lastPathComponent == "coin.wav")
    }

    @Test("End-to-end ColmapDatasetWriter (28 parallax views + masks + init.ply) -> brush_app -> SuperSplat 3DGS .ply + PLYPreviewLoader")
    func endToEndBrushTrainingProducesSuperSplatPLY() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let brushURL = projectDir.appendingPathComponent("brush_app")
        guard FileManager.default.isExecutableFile(atPath: brushURL.path) else {
            return
        }

        // Synthesize a textured (non-trivial PNG size) 2:1 equirectangular panorama + synthetic depth map
        let panoW = 512
        let panoH = 256
        var rgba = [UInt8](repeating: 255, count: panoW * panoH * 4)
        var radii = [Float](repeating: 12.0, count: panoW * panoH)
        var disp = [Float](repeating: 1.0 / 12.0, count: panoW * panoH)

        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        func nextByte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((seed >> 33) & 0xFF)
        }

        for y in 0..<panoH {
            for x in 0..<panoW {
                let idx = y * panoW + x
                let off = idx * 4
                let noise = Int(nextByte()) / 4
                let isNear = (x > 210 && x < 300 && y > 64 && y < 192)
                if isNear {
                    rgba[off] = UInt8(min(255, 180 + noise))
                    rgba[off + 1] = UInt8(min(255, 60 + noise))
                    rgba[off + 2] = UInt8(min(255, 50 + noise))
                    radii[idx] = 3.2
                    disp[idx] = 1.0 / 3.2
                } else {
                    rgba[off] = UInt8(min(255, 50 + noise))
                    rgba[off + 1] = UInt8(min(255, 110 + noise))
                    rgba[off + 2] = UInt8(min(255, 175 + noise))
                    radii[idx] = 18.0
                    disp[idx] = 1.0 / 18.0
                }
                rgba[off + 3] = 255
            }
        }

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
            sourceURL: URL(fileURLWithPath: "/tmp/e2e_pano.png"),
            width: panoW,
            height: panoH,
            isHDR: false,
            fileSizeBytes: Int64(rgba.count),
            cgImage: image,
            thumbnail: image
        )
        let depthMap = EquirectangularDepthMap(width: panoW, height: panoH, disparity: disp, metricRadiusMeters: radii)

        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoSplat3D-E2E-\(UUID().uuidString)", isDirectory: true)
        let datasetDir = workRoot.appendingPathComponent("dataset", isDirectory: true)
        let outputPLY = workRoot.appendingPathComponent("lapland_test.ply")
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let settings = GenerationSettings(
            depthScaleMeters: 12.0,
            parallaxBaselineMeters: 0.75,
            perspectiveResolution: 256,
            initialPointCount: 2_000
        )

        let writer = ColmapDatasetWriter()
        let datasetResult = try writer.writeDataset(
            from: asset,
            depthMap: depthMap,
            to: datasetDir,
            settings: settings
        )
        #expect(datasetResult.imageCount == 44)
        #expect(datasetResult.masksDirectory != nil)

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var maxStep = 0
            func record(_ step: Int) {
                lock.lock()
                maxStep = max(maxStep, step)
                lock.unlock()
            }
            func value() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return maxStep
            }
        }
        let progressCounter = Counter()

        let runner = BrushTrainingRunner()
        let trainResult = try await runner.train(
            brushExecutableURL: brushURL,
            datasetDirectory: datasetDir,
            outputPLYURL: outputPLY,
            totalSteps: 40,
            shDegree: 2,
            maxResolution: 256
        ) { progress in
            progressCounter.record(progress.currentStep)
        }

        #expect(trainResult.fileSizeBytes > 10_000)
        #expect(progressCounter.value() > 0, "Expected real-time PTY step progress updates from Brush")

        // Verify the exported .ply has full SuperSplat 3D Gaussian Splatting headers
        let plyData = try Data(contentsOf: outputPLY)
        let endMarker = Data("end_header\n".utf8)
        let range = try #require(plyData.range(of: endMarker))
        let header = String(decoding: plyData[..<range.upperBound], as: UTF8.self)
        #expect(header.contains("property float f_dc_0"))
        #expect(header.contains("property float opacity"))
        #expect(header.contains("property float scale_0"))
        #expect(header.contains("property float rot_0"))

        // Verify PLYPreviewLoader parses the trained 3DGS splat cleanly
        let cloud = try PLYPreviewLoader.load(from: outputPLY)
        #expect(cloud.isGaussianSplat)
        #expect(cloud.totalVertexCount > 0)
        #expect(!cloud.positions.isEmpty)
        #expect(cloud.positions.count == cloud.colors.count)
    }
}
