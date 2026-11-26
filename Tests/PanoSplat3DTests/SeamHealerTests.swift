import CoreGraphics
import Foundation
import Testing
@testable import PanoSplat3DCore

@Suite("360° 180°-Shift Seam Healer & Draw Things Inpaint Request")
struct SeamHealerTests {
    private func makeTestImage(width: Int, height: Int, pixelColor: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
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

    @Test("Horizontal circular roll round-trips bit-for-bit on even and odd widths")
    func horizontalRollRoundTrip() throws {
        for width in [128, 129] {
            let height = 64
            let original = makeTestImage(width: width, height: height) { x, y in
                (UInt8(x % 256), UInt8((y * 3) % 256), UInt8(((x + y) * 5) % 256))
            }
            let origBytes = PanoramaLoader.extractRGBA8Bytes(from: original)

            let half = width / 2
            let shifted = try SeamHealerService.rollHorizontal(original, shiftPixels: half)
            let restored = try SeamHealerService.rollHorizontal(shifted, shiftPixels: width - half)
            let restoredBytes = PanoramaLoader.extractRGBA8Bytes(from: restored)

            #expect(restoredBytes == origBytes)

            // Also verify shift180 / rollBack180 manual Draw Things round-trip helpers
            let manualShifted = try SeamHealerService.shift180(original)
            let manualRestored = try SeamHealerService.rollBack180(manualShifted)
            #expect(PanoramaLoader.extractRGBA8Bytes(from: manualRestored) == origBytes)
        }
    }

    @Test("Center seam mask is pure white at x=W/2, pure black at outer edges, with smooth feathering")
    func centerSeamMaskProfile() throws {
        let width = 256
        let height = 128
        let mask = try SeamHealerService.makeCenterSeamMask(
            width: width,
            height: height,
            coreWidthFraction: SeamStripWidth.medium.coreWidthFraction,
            featherFraction: SeamStripWidth.medium.featherFraction
        )
        let rgba = PanoramaLoader.extractRGBA8Bytes(from: mask)

        let row = height / 2
        let centerVal = rgba[(row * width + width / 2) * 4]
        let leftEdgeVal = rgba[(row * width + 0) * 4]
        let rightEdgeVal = rgba[(row * width + (width - 1)) * 4]
        let quarterVal = rgba[(row * width + width / 4) * 4]

        #expect(centerVal == 255)
        #expect(leftEdgeVal == 0)
        #expect(rightEdgeVal == 0)
        #expect(quarterVal == 0)
    }

    @Test("prepareForDrawThings + finalizeHealedPanorama heals 0°/360° seam while preserving outer 80% bit-exact")
    func endToEndShiftCompositeAndRollback() throws {
        let width = 512
        let height = 256
        let original = makeTestImage(width: width, height: height) { x, _ in
            if x < 10 { return (240, 20, 20) }
            if x >= width - 10 { return (20, 220, 20) }
            return (40, 100, 210)
        }
        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: original)

        let prepared = try SeamHealerService.prepareCenterSquareForDrawThings(
            panorama: original,
            squareSize: 512,
            stripWidth: .medium
        )
        #expect(prepared.workingWidth == 512)
        #expect(prepared.workingHeight == 512)
        #expect(prepared.cropX == 128)
        #expect(prepared.cropWidth == 256)
        #expect(!prepared.initImagePNG.isEmpty)

        // Simulate Draw Things returning a uniformly healed purple square crop
        let fakeInpainted = makeTestImage(width: 512, height: 512) { _, _ in (160, 80, 180) }
        let fakeInpaintedPNG = try SeamHealerService.encodePNG(fakeInpainted)

        let healed = try SeamHealerService.finalizeHealedPanorama(
            shiftedOriginal: prepared.shiftedOriginal,
            inpaintedImageData: fakeInpaintedPNG,
            stripWidth: .medium,
            cropX: prepared.cropX,
            cropWidth: prepared.cropWidth
        )
        #expect(healed.width == width)
        #expect(healed.height == height)

        let healedBytes = PanoramaLoader.extractRGBA8Bytes(from: healed)
        let midRow = height / 2

        let seamLeftR = healedBytes[(midRow * width + 0) * 4]
        let seamRightR = healedBytes[(midRow * width + (width - 1)) * 4]
        #expect(abs(Int(seamLeftR) - 160) <= 2)
        #expect(abs(Int(seamRightR) - 160) <= 2)

        let centerIdx = (midRow * width + width / 2) * 4
        #expect(healedBytes[centerIdx] == origBytes[centerIdx])
        #expect(healedBytes[centerIdx + 1] == origBytes[centerIdx + 1])
        #expect(healedBytes[centerIdx + 2] == origBytes[centerIdx + 2])

        let preview = SeamHealerService.makeShiftedSeamPreview(panorama: original, stripWidth: .medium)
        #expect(preview != nil)
    }

    @Test("DrawThingsInpaintRequest encodes clean img2img payload with model override, LoRA bypass, and Draw Things model scanner")
    func inpaintJSONPayloadAndModelDiscovery() {
        let initData = Data([0x89, 0x50, 0x4E, 0x47])
        let maskData = Data([0x89, 0x50, 0x4E, 0x48])
        let req = DrawThingsInpaintRequest(
            prompt: "seamless snowy Lapland pine forest continuation",
            negativePrompt: "seam, blurry",
            initImagePNG: initData,
            maskPNG: maskData,
            width: 768,
            height: 768,
            denoisingStrength: 0.78,
            maskBlur: 8,
            seed: 123,
            steps: 24,
            shift: 1.0,
            resolutionDependentShift: false,
            guidanceScale: 7.0,
            sampler: .dpmpp2MKarras,
            model: "realistic_vision_v5.1_f16.ckpt"
        )

        let json = req.toJSONObject()
        let initImages = json["init_images"] as? [String]
        #expect(initImages?.count == 1)
        #expect(initImages?.first == initData.base64EncodedString())
        #expect(json["mask"] == nil)
        #expect(json["mask_blur"] == nil)
        #expect(json["inpainting_mask_invert"] == nil)
        #expect(json["inpainting_fill"] == nil)
        #expect(json["model"] as? String == "realistic_vision_v5.1_f16.ckpt")
        #expect(json["denoising_strength"] as? Double == 0.78)
        #expect(json["strength"] == nil)
        #expect(json["guidance_scale"] as? Double == 7.0)
        #expect(json["cfg_scale"] == nil)
        #expect(json["batch_count"] as? Int == 1)
        #expect(json["batch_size"] as? Int == 1)
        #expect(json["n_iter"] == nil)
        #expect(json["upscaler"] is NSNull)
        #expect(json["upscaler_scale"] as? Int == 0)
        #expect(json["preserve_original_after_inpaint"] as? Bool == false)
        #expect(json["sampler"] as? String == "DPM++ 2M Karras")
        #expect(json["sampler_name"] == nil)
        let loras = json["loras"] as? [Any]
        #expect(loras != nil && loras?.isEmpty == true)

        var keepReq = req
        keepReq.disableLoRAs = false
        #expect(keepReq.toJSONObject()["loras"] == nil)

        let configJSON = Data("""
        {
            "model": "flux_2_klein_base_9b_i8x.ckpt",
            "loras": [{"file": "flux_2_klein_9b_360_panorama_lora_f16.ckpt", "weight": 1.0, "mode": "all"}]
        }
        """.utf8)
        let snap = DrawThingsClient.parseConfigSnapshot(configJSON)
        #expect(snap.loras.count == 1)
        #expect(snap.loras.first?.file == "flux_2_klein_9b_360_panorama_lora_f16.ckpt")
        #expect(snap.loras.first?.weight == 1.0)

        // Verify Draw Things model scanner filters out LoRAs/VAEs/CLIP and prioritizes inpainting & SD 1.5 models
        let tmpModels = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoSplat3D-DTModels-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpModels, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpModels) }
        for name in [
            "flux_2_klein_base_9b_i8x.ckpt",
            "flux_2_klein_9b_360_panorama_lora_f16.ckpt",
            "flux_2_vae_f16.ckpt",
            "qwen_3_8b_q8p.ckpt",
            "realistic_vision_v5.1_f16.ckpt",
            "realistic_vision_v5.1_inpainting_f16.ckpt",
            "realistic_vision_v5.1_clip_vit_l14_f16.ckpt"
        ] {
            FileManager.default.createFile(atPath: tmpModels.appendingPathComponent(name).path, contents: Data())
        }
        let discovered = DrawThingsClient.discoverInstalledModels(modelsDirectory: tmpModels)
        #expect(discovered == [
            "realistic_vision_v5.1_inpainting_f16.ckpt",
            "realistic_vision_v5.1_f16.ckpt",
            "flux_2_klein_base_9b_i8x.ckpt"
        ])
    }

    @Test("1:1 square center-crop compositing heals only the seam strip while leaving outer panorama pixels bit-exact")
    func centerSquareCropCompositing() throws {
        let width = 512
        let height = 256
        let shiftedOriginal = makeTestImage(width: width, height: height) { x, _ in
            if abs(x - width / 2) < 8 { return (240, 20, 20) }
            return (40, 120, 210)
        }
        let origBytes = PanoramaLoader.extractRGBA8Bytes(from: shiftedOriginal)

        let cropW = min(width, height)
        let cropX = (width - cropW) / 2
        let mask = try SeamHealerService.makeCropValidityMask(
            cropWidth: cropW,
            cropHeight: height,
            holeWidthPixels: Double(width) * SeamStripWidth.medium.coreWidthFraction
        )
        let maskRGBA = PanoramaLoader.extractRGBA8Bytes(from: mask)
        #expect(maskRGBA[(128 * cropW + cropW / 2) * 4] == 0)
        #expect(maskRGBA[(128 * cropW + 4) * 4] == 255)

        let healedCrop = makeTestImage(width: cropW, height: height) { _, _ in (42, 122, 212) }
        let composited = try SeamHealerService.compositeHealedCenterCrop(
            shiftedOriginal: shiftedOriginal,
            healedCenterCrop: healedCrop,
            cropX: cropX,
            stripWidth: .medium
        )
        let compBytes = PanoramaLoader.extractRGBA8Bytes(from: composited)

        let centerIdx = (128 * width + width / 2) * 4
        #expect(compBytes[centerIdx] == 42)
        #expect(compBytes[centerIdx + 1] == 122)

        let outerIdx = (128 * width + 32) * 4
        #expect(compBytes[outerIdx] == origBytes[outerIdx])
        #expect(compBytes[outerIdx + 1] == origBytes[outerIdx + 1])
        #expect(compBytes[outerIdx + 2] == origBytes[outerIdx + 2])
    }

    @Test("Opt-in live local CoreML LaMa 180°-shift seam healing eliminates harsh 0°/360° edge seam (PANOSPLAT_LIVE_LAMA=1)")
    func liveLocalLaMaSeamHeal() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_LAMA"] == "1" else {
            return
        }
        let width = 1024
        let height = 512
        let broken = makeTestImage(width: width, height: height) { x, y in
            if x < 16 || x >= width - 16 { return (0, 0, 0) }
            if y < height / 2 { return (110, 165, 235) }
            return (225, 232, 242)
        }

        let start = Date()
        let healed = try await SeamHealerService.healWithLocalLaMa(
            panorama: broken,
            stripWidth: .narrow
        )
        let elapsed = Date().timeIntervalSince(start)
        let bytes = PanoramaLoader.extractRGBA8Bytes(from: healed)

        let leftSnowIdx = (384 * width + 2) * 4
        let rightSnowIdx = (384 * width + (width - 3)) * 4
        print("Local LaMa Seam Heal (\(String(format: "%.2f", elapsed))s) — seamLeft=(\(bytes[leftSnowIdx]),\(bytes[leftSnowIdx+1]),\(bytes[leftSnowIdx+2])), seamRight=(\(bytes[rightSnowIdx]),\(bytes[rightSnowIdx+1]),\(bytes[rightSnowIdx+2]))")

        #expect(bytes[leftSnowIdx] > 170)
        #expect(bytes[rightSnowIdx] > 170)
    }
}
