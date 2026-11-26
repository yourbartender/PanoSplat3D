import CoreGraphics
import Foundation
import simd
import Testing
@testable import PanoSplat3DCore

@Suite("CoreML LaMa Parallax Background Void Inpainter & 2-Layer Seeding")
struct LaMaInpainterTests {
    private func makeRGBImage(width: Int, height: Int, pixelColor: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixelColor(x, y)
                let idx = (y * width + x) * 4
                rgba[idx] = r
                rgba[idx + 1] = g
                rgba[idx + 2] = b
                rgba[idx + 3] = 255
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    private func makeGrayMask(width: Int, height: Int, valueAt: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = valueAt(x, y)
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @Test("LaMaModelManager defines valid Apache-2.0 Hugging Face 3-file manifest")
    func lamaManifestIsValid() {
        #expect(LaMaModelManager.remoteFiles.count == 3)
        #expect(LaMaModelManager.totalExpectedBytes > 200_000_000)
        for f in LaMaModelManager.remoteFiles {
            #expect(f.relativePath.hasPrefix(LaMaModelManager.packageName + "/"))
            #expect(URL(string: LaMaModelManager.baseDownloadURL + f.relativePath) != nil)
        }
    }

    @Test("buildDilatedHoleMask inverts Brush validity mask and dilates holes by radius")
    func dilatedHoleMaskInversion() {
        let w = 32
        let h = 32
        var valid = [UInt8](repeating: 255, count: w * h)
        // Single 2×2 black hole at (15..16, 15..16)
        for y in 15...16 {
            for x in 15...16 {
                valid[y * w + x] = 0
            }
        }

        let (holeMask, frac) = ParallaxHoleInpainter.buildDilatedHoleMask(
            validMaskBytes: valid,
            width: w,
            height: h,
            dilationRadius: 2
        )
        #expect(abs(frac - (4.0 / 1024.0)) < 1e-6)
        // Inside hole and 2px border must be marked 255 (inpaint)
        #expect(holeMask[15 * w + 15] == 255)
        #expect(holeMask[13 * w + 15] == 255)
        #expect(holeMask[18 * w + 16] == 255)
        // Far away valid pixels must stay 0 (preserve untouched)
        #expect(holeMask[0] == 0)
        #expect(holeMask[10 * w + 10] == 0)
    }

    @Test("compositeInpaintedHoles replaces only hole pixels and preserves valid pixels bit-exact")
    func holeOnlyCompositingPreservesValidPixels() throws {
        let w = 128
        let h = 128
        let original = makeRGBImage(width: w, height: h) { x, y in
            if x >= 56 && x < 72 { return (0, 0, 0) } // Black vertical disocclusion void
            return (UInt8(40 + (x % 60)), UInt8(120 + (y % 50)), 210)
        }
        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: original)

        let fakeInpainted = makeRGBImage(width: 64, height: 64) { _, _ in (235, 240, 248) } // Crisp white snow fill

        var holeMask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 56..<72 {
                holeMask[y * w + x] = 255
            }
        }

        let composited = try ParallaxHoleInpainter.compositeInpaintedHoles(
            original: original,
            inpainted: fakeInpainted,
            holeMaskBytes: holeMask,
            width: w,
            height: h
        )
        let outBytes = PanoramaLoader.extractRGBA8Bytes(from: composited)

        // Center of hole must be filled with snow color
        let holeIdx = (64 * w + 64) * 4
        #expect(outBytes[holeIdx] >= 230)
        #expect(outBytes[holeIdx + 1] >= 235)
        #expect(outBytes[holeIdx + 2] >= 242)

        // Valid pixel outside hole must be 100% bit-exact original
        let validIdx = (64 * w + 20) * 4
        #expect(outBytes[validIdx] == origBytes[validIdx])
        #expect(outBytes[validIdx + 1] == origBytes[validIdx + 1])
        #expect(outBytes[validIdx + 2] == origBytes[validIdx + 2])
    }

    @Test("PointCloudGenerator seeds Layer-2 background points behind foreground occluder cliffs")
    func layer2BackgroundPointSeeding() {
        let img = makeRGBImage(width: 256, height: 128) { x, _ in
            // Foreground dark tree trunk in center, bright snow background everywhere else
            if x >= 118 && x <= 138 { return (35, 25, 20) }
            return (230, 235, 245)
        }

        let radiusFn: (Double, Double) -> Double = { u, _ in
            // Close tree trunk at 3.0m, snow background at 18.0m
            (u >= 0.46 && u <= 0.54) ? 3.0 : 18.0
        }

        let withoutBg = PointCloudGenerator.generate(
            from: img,
            targetPointCount: 4_000,
            radiusAtUV: radiusFn,
            seedBackgroundBehindOccluders: false
        )
        let withBg = PointCloudGenerator.generate(
            from: img,
            targetPointCount: 4_000,
            radiusAtUV: radiusFn,
            seedBackgroundBehindOccluders: true
        )

        #expect(withBg.count > withoutBg.count)
    }

    @Test("Opt-in live CoreML LaMa download, compile, and vertical tree-void inpainting (PANOSPLAT_LIVE_LAMA=1)")
    func liveLaMaInpainting() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_LAMA"] == "1" else {
            return
        }

        let w = 512
        let h = 512
        // Blue sky upper half, bright snow lower half, with a vertical black disocclusion void in the center
        let viewImg = makeRGBImage(width: w, height: h) { x, y in
            if x >= 230 && x < 282 { return (0, 0, 0) }
            if y < h / 2 { return (110, 165, 235) }
            return (225, 232, 242)
        }
        let validMask = makeGrayMask(width: w, height: h) { x, _ in
            (x >= 230 && x < 282) ? 0 : 255
        }

        let inpainter = ParallaxHoleInpainter()
        let loadStart = Date()
        let model = try await inpainter.prepareModel()
        let loadElapsed = Date().timeIntervalSince(loadStart)

        let inferStart = Date()
        let (filled, didFill) = try await inpainter.fillDisoccludedHoles(
            in: viewImg,
            validMask: validMask,
            using: model
        )
        let inferElapsed = Date().timeIntervalSince(inferStart)

        #expect(didFill == true)
        #expect(filled.width == w)
        #expect(filled.height == h)

        let bytes = PanoramaLoader.extractRGBA8Bytes(from: filled)
        // Center of sky void should now be bright blue sky (not black!)
        let skyVoidIdx = ((h / 4) * w + 256) * 4
        let skyR = Int(bytes[skyVoidIdx])
        let skyG = Int(bytes[skyVoidIdx + 1])
        let skyB = Int(bytes[skyVoidIdx + 2])
        // Center of snow void should now be bright white snow (not black!)
        let snowVoidIdx = ((3 * h / 4) * w + 256) * 4
        let snowR = Int(bytes[snowVoidIdx])
        let snowG = Int(bytes[snowVoidIdx + 1])
        let snowB = Int(bytes[snowVoidIdx + 2])

        print("LaMa Live Check — load: \(String(format: "%.1f", loadElapsed))s, infer: \(String(format: "%.2f", inferElapsed))s, skyVoid RGB=(\(skyR),\(skyG),\(skyB)), snowVoid RGB=(\(snowR),\(snowG),\(snowB))")

        #expect(skyB > 150, "Expected blue sky inpainting inside sky void, got RGB(\(skyR),\(skyG),\(skyB))")
        #expect(snowR > 160 && snowG > 160 && snowB > 160, "Expected bright snow inpainting inside snow void, got RGB(\(snowR),\(snowG),\(snowB))")
    }
}
