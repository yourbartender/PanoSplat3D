import Foundation
import Testing
@testable import PanoSplat3DCore

@Suite("Draw Things HTTP API Client & View Resolution Presets")
struct DrawThingsClientTests {
    @Test("Builds txt2img JSON payload with explicit Steps, Shift, Guidance, Sampler, and Upscaler")
    func requestJSONPayload() {
        let req = DrawThingsGenerationRequest(
            prompt: "360 equirectangular snowy pine forest in Lapland",
            negativePrompt: "blurry, seam",
            sizePreset: .size1536x768,
            seed: 42,
            steps: 8,
            shift: 3.15,
            resolutionDependentShift: true,
            guidanceScale: 2.5,
            sampler: .eulerATrailing,
            upscaler: .none
        )
        let json = req.toJSONObject()
        #expect(json["prompt"] as? String == "360 equirectangular snowy pine forest in Lapland")
        #expect(json["negative_prompt"] as? String == "blurry, seam")
        #expect(json["width"] as? Int == 1536)
        #expect(json["height"] as? Int == 768)
        #expect(json["seed"] as? Int == 42)
        #expect(json["steps"] as? Int == 8)
        #expect(json["shift"] as? Double == 3.15)
        #expect(json["resolution_dependent_shift"] as? Bool == true)
        #expect(json["guidance_scale"] as? Double == 2.5)
        #expect(json["cfg_scale"] == nil)
        #expect(json["sampler"] as? String == "Euler A Trailing")
        #expect(json["sampler_name"] == nil)
        #expect(json["upscaler"] is NSNull)
        #expect(json["upscaler_scale"] as? Int == 0)
        #expect(json["batch_count"] as? Int == 1)
        #expect(json["batch_size"] as? Int == 1)
        #expect(json["n_iter"] == nil)

        // Leaving sampler/upscaler on .keepActive omits them so Draw Things keeps active values
        let activeReq = DrawThingsGenerationRequest(
            prompt: "test",
            sizePreset: .useActive,
            sampler: .keepActive,
            upscaler: .keepActive
        )
        let activeJson = activeReq.toJSONObject()
        #expect(activeJson["width"] == nil)
        #expect(activeJson["height"] == nil)
        #expect(activeJson["sampler"] == nil)
        #expect(activeJson["upscaler"] == nil)
    }

    @Test("Parses live Draw Things GET / config snapshot, progress, and Base64 txt2img image payloads")
    func parseAPIResponses() throws {
        let configJSON = Data("""
        {
            "model": "qwen_image_2.1_turbo_q8p.ckpt",
            "steps": 8,
            "shift": 3.0,
            "guidance_scale": 2.5,
            "resolution_dependent_shift": true,
            "sampler": 14,
            "upscaler": "",
            "width": 1536,
            "height": 768
        }
        """.utf8)
        let snap = DrawThingsClient.parseConfigSnapshot(configJSON)
        #expect(snap.model == "qwen_image_2.1_turbo_q8p.ckpt")
        #expect(snap.steps == 8)
        #expect(snap.shift == 3.0)
        #expect(snap.guidanceScale == 2.5)
        #expect(snap.resolutionDependentShift == true)
        #expect(snap.samplerOption == .eulerATrailing)
        #expect(snap.upscaler == "")
        #expect(snap.width == 1536)
        #expect(snap.height == 768)

        let progressJSON = Data("""
        {"progress": 0.625, "state": {"sampling_step": 5, "sampling_steps": 8}}
        """.utf8)
        let prog = try #require(DrawThingsClient.parseProgressResponse(progressJSON))
        #expect(abs(prog.fraction - 0.625) < 1e-6)
        #expect(prog.currentStep == 5)
        #expect(prog.totalSteps == 8)
        #expect(prog.hasStarted == true)

        let sampleBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let b64 = sampleBytes.base64EncodedString()

        let plainResponse = Data("{\"images\": [\"\(b64)\"]}".utf8)
        #expect(try DrawThingsClient.decodeFirstImageData(from: plainResponse) == sampleBytes)

        let dataURIResponse = Data("{\"images\": [\"data:image/png;base64,\(b64)\"]}".utf8)
        #expect(try DrawThingsClient.decodeFirstImageData(from: dataURIResponse) == sampleBytes)
    }

    @Test("ViewResolutionPreset maps cleanly to GenerationSettings.perspectiveResolution")
    func viewResolutionPresets() {
        var settings = GenerationSettings()
        #expect(settings.viewResolutionPreset == .sharp)
        #expect(settings.perspectiveResolution == 1280)

        settings.viewResolutionPreset = .draft
        #expect(settings.perspectiveResolution == 768)

        settings.viewResolutionPreset = .ultra
        #expect(settings.perspectiveResolution == 1536)
    }

    @Test("PanoramaPromptEnhancer expands short prompts with 360° framing and fills empty negative prompt")
    func promptEnhancerExpandsAndAvoidsDuplicates() {
        let enhanced = PanoramaPromptEnhancer.enhance(
            prompt: "snowy pine forest at dawn",
            existingNegativePrompt: "",
            style: .natureLandscape
        )
        #expect(enhanced.prompt.lowercased().contains("360-degree equirectangular panorama"))
        #expect(enhanced.prompt.contains("snowy pine forest at dawn"))
        #expect(enhanced.prompt.lowercased().contains("seamless"))
        #expect(enhanced.prompt.lowercased().contains("horizon"))
        #expect(!enhanced.negativePrompt.isEmpty)

        // Existing negative prompt is preserved, and existing "360" prefix isn't duplicated
        let custom = PanoramaPromptEnhancer.enhance(
            prompt: "360 equirectangular cozy studio",
            existingNegativePrompt: "people",
            style: .architecturalInterior
        )
        #expect(!custom.prompt.hasPrefix("360-degree equirectangular panorama"))
        #expect(custom.negativePrompt == "people")
    }

    @Test("External file open filter accepts supported 360° image types and rejects unrelated files")
    func supportedPanoramaFileExtensions() {
        #expect(PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/forest.jpg")))
        #expect(PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/forest.JPEG")))
        #expect(PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/forest.png")))
        #expect(PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/hdr.exr")))
        #expect(PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/pano.heic")))
        #expect(!PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!PipelineCoordinator.isSupportedPanoramaURL(URL(fileURLWithPath: "/tmp/model.ply")))
        #expect(!PipelineCoordinator.isSupportedPanoramaURL(URL(string: "https://example.com/test.jpg")!))
    }
}
