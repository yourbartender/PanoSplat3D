import AppKit
import Foundation

/// Draw Things sampler options supported by its HTTP API (`POST /sdapi/v1/txt2img`).
public enum DrawThingsSamplerOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case keepActive = "Keep Draw Things Active"
    case eulerATrailing = "Euler A Trailing"
    case eulerASubstep = "Euler A Substep"
    case eulerA = "Euler A"
    case dpmpp2MKarras = "DPM++ 2M Karras"
    case dpmpp2MTrailing = "DPM++ 2M Trailing"
    case dpmpp2MAYS = "DPM++ 2M AYS"
    case dpmppSDEKarras = "DPM++ SDE Karras"
    case dpmppSDETrailing = "DPM++ SDE Trailing"
    case uniPCTrailing = "UniPC Trailing"
    case uniPCAYS = "UniPC AYS"
    case ddimTrailing = "DDIM Trailing"
    case tcd = "TCD"
    case lcm = "LCM"

    public var id: String { rawValue }

    /// Maps Draw Things' internal integer sampler indices (returned by `GET /`) to human-readable sampler names.
    public static func from(rawValueOrIndex value: Any?) -> DrawThingsSamplerOption? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return exact
            }
        }
        if let intVal = value as? Int {
            // Draw Things SamplerType enum ordering
            switch intVal {
            case 0: return .dpmpp2MKarras
            case 1: return .eulerA
            case 2: return .ddimTrailing
            case 4: return .dpmppSDEKarras
            case 9: return .lcm
            case 10: return .dpmpp2MAYS
            case 11: return .eulerASubstep
            case 12: return .dpmppSDETrailing
            case 13: return .dpmpp2MTrailing
            case 14: return .eulerATrailing
            case 16: return .uniPCTrailing
            case 17: return .uniPCAYS
            case 18: return .tcd
            default: return nil
            }
        }
        return nil
    }
}

/// Built-in upscaler options available inside Draw Things (or `None` to use PanoSplat3D's 360°-wrap-safe upscaler).
public enum DrawThingsUpscalerOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = ""
    case keepActive = "__KEEP_ACTIVE__"
    case realESRGANx2Plus = "realesrgan_x2plus_f16.ckpt"
    case realESRGANx4Plus = "realesrgan_x4plus_f16.ckpt"
    case ultraSharp4x = "4x_ultrasharp_f16.ckpt"
    case universalV2Sharp = "esrgan_4x_universal_upscaler_v2_sharp_f16.ckpt"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "None (Recommended — use PanoSplat3D 360° Upscaler)"
        case .keepActive: return "Keep Draw Things Active"
        case .realESRGANx2Plus: return "Real-ESRGAN x2+ (Draw Things)"
        case .realESRGANx4Plus: return "Real-ESRGAN x4+ (Draw Things)"
        case .ultraSharp4x: return "4x UltraSharp (Draw Things)"
        case .universalV2Sharp: return "Universal Upscaler v2 Sharp (Draw Things)"
        }
    }
}

/// Single LoRA entry returned by Draw Things `GET /` or sent in `"loras"` payloads.
public struct DrawThingsLoRAEntry: Equatable, Sendable {
    public let file: String
    public let weight: Double
    public let mode: String

    public init(file: String, weight: Double = 1.0, mode: String = "all") {
        self.file = file
        self.weight = weight
        self.mode = mode
    }
}

/// Live configuration snapshot synced from Draw Things via `GET /` or `GET /sdapi/v1/options`.
public struct DrawThingsConfigSnapshot: Equatable, Sendable {
    public let model: String?
    public let steps: Int?
    public let shift: Double?
    public let guidanceScale: Double?
    public let resolutionDependentShift: Bool?
    public let samplerLabel: String?
    public let samplerOption: DrawThingsSamplerOption?
    public let upscaler: String?
    public let width: Int?
    public let height: Int?
    public let loras: [DrawThingsLoRAEntry]

    public init(
        model: String? = nil,
        steps: Int? = nil,
        shift: Double? = nil,
        guidanceScale: Double? = nil,
        resolutionDependentShift: Bool? = nil,
        samplerLabel: String? = nil,
        samplerOption: DrawThingsSamplerOption? = nil,
        upscaler: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        loras: [DrawThingsLoRAEntry] = []
    ) {
        self.model = model
        self.steps = steps
        self.shift = shift
        self.guidanceScale = guidanceScale
        self.resolutionDependentShift = resolutionDependentShift
        self.samplerLabel = samplerLabel
        self.samplerOption = samplerOption
        self.upscaler = upscaler
        self.width = width
        self.height = height
        self.loras = loras
    }
}

/// Connection status of the local Draw Things HTTP API server (`127.0.0.1:7860`).
public enum DrawThingsServerStatus: Equatable, Sendable {
    case unknown
    case checking
    case online(DrawThingsConfigSnapshot)
    case offline(reason: String)

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    public var snapshot: DrawThingsConfigSnapshot? {
        if case .online(let snap) = self { return snap }
        return nil
    }
}

/// 2:1 equirectangular resolution presets for Draw Things generation.
public enum DrawThingsSizePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case useActive = "useActive"
    case size1024x512 = "1024x512"
    case size1536x768 = "1536x768"
    case size2048x1024 = "2048x1024"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .useActive: return "Use Draw Things Size"
        case .size1024x512: return "1024 × 512 (Fast)"
        case .size1536x768: return "1536 × 768 (Balanced)"
        case .size2048x1024: return "2048 × 1024 (High)"
        }
    }

    public var dimensions: (width: Int, height: Int)? {
        switch self {
        case .useActive: return nil
        case .size1024x512: return (1024, 512)
        case .size1536x768: return (1536, 768)
        case .size2048x1024: return (2048, 1024)
        }
    }
}

/// Request parameters sent to Draw Things `POST /sdapi/v1/txt2img`.
public struct DrawThingsGenerationRequest: Equatable, Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var sizePreset: DrawThingsSizePreset
    public var seed: Int
    /// Explicit sampling steps (`nil` keeps Draw Things' active step count).
    public var steps: Int?
    /// Explicit flow-matching shift value (critical for Qwen 2.1 Turbo / Flux / SD3; `nil` keeps active).
    public var shift: Double?
    /// Whether Draw Things adjusts shift automatically by resolution (`nil` keeps active).
    public var resolutionDependentShift: Bool?
    /// Explicit guidance / CFG scale (`nil` keeps active).
    public var guidanceScale: Double?
    /// Sampler override (`.keepActive` leaves Draw Things' current sampler untouched).
    public var sampler: DrawThingsSamplerOption
    /// Draw Things upscaler override (`.keepActive` leaves current untouched; `.none` disables DT upscaler).
    public var upscaler: DrawThingsUpscalerOption

    public init(
        prompt: String,
        negativePrompt: String = "",
        sizePreset: DrawThingsSizePreset = .size1536x768,
        seed: Int = -1,
        steps: Int? = nil,
        shift: Double? = nil,
        resolutionDependentShift: Bool? = nil,
        guidanceScale: Double? = nil,
        sampler: DrawThingsSamplerOption = .keepActive,
        upscaler: DrawThingsUpscalerOption = .keepActive
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.sizePreset = sizePreset
        self.seed = seed
        self.steps = steps
        self.shift = shift
        self.resolutionDependentShift = resolutionDependentShift
        self.guidanceScale = guidanceScale
        self.sampler = sampler
        self.upscaler = upscaler
    }

    /// Encodes a clean JSON payload for Draw Things `POST /sdapi/v1/txt2img`.
    /// When `steps`, `shift`, `guidanceScale`, `sampler`, or `upscaler` are specified (or synced from `GET /`),
    /// they are sent explicitly so Draw Things never resets flow-matching models like Qwen 2.1 Turbo to bad defaults.
    public func toJSONObject() -> [String: Any] {
        var dict: [String: Any] = [
            "prompt": prompt,
            "seed": seed,
            // Always force single-image generation so Draw Things never runs a multi-image batch
            // left over from the user's Draw Things UI settings.
            "batch_count": 1,
            "batch_size": 1,
            "preserve_original_after_inpaint": false
        ]
        let trimmedNeg = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNeg.isEmpty {
            dict["negative_prompt"] = trimmedNeg
        }
        if let dims = sizePreset.dimensions {
            dict["width"] = dims.width
            dict["height"] = dims.height
        }
        if let steps, steps > 0 {
            dict["steps"] = steps
        }
        if let shift, shift > 0 {
            dict["shift"] = shift
        }
        if let resShift = resolutionDependentShift {
            dict["resolution_dependent_shift"] = resShift
        }
        if let cfg = guidanceScale, cfg >= 0 {
            dict["guidance_scale"] = cfg
        }
        if sampler != .keepActive {
            dict["sampler"] = sampler.rawValue
        }
        if upscaler == .none {
            // Draw Things requires explicit `null` + `upscaler_scale: 0` (an empty string `""` enables a broken 400% upscaler!)
            dict["upscaler"] = NSNull()
            dict["upscaler_scale"] = 0
        } else if upscaler != .keepActive {
            dict["upscaler"] = upscaler.rawValue
        }
        return dict
    }
}

/// Request parameters sent to Draw Things `POST /sdapi/v1/img2img` for 180°-shifted 360° seam inpainting.
public struct DrawThingsInpaintRequest: Equatable, Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var initImagePNG: Data
    public var maskPNG: Data
    public var width: Int
    public var height: Int
    /// Inpainting denoise strength (`0.40 – 1.00`, default `0.78`).
    public var denoisingStrength: Double
    /// Draw Things mask edge blur radius in pixels (default `8`).
    public var maskBlur: Int
    public var seed: Int
    public var steps: Int?
    public var shift: Double?
    public var resolutionDependentShift: Bool?
    public var guidanceScale: Double?
    public var sampler: DrawThingsSamplerOption
    /// When `true` (default), sends `"loras": []` so Draw Things disables 360° LoRAs during centered seam inpainting
    /// without removing them from Draw Things' UI for future 360° generations.
    public var disableLoRAs: Bool
    /// Optional model checkpoint filename (e.g. `realistic_vision_v5.1_f16.ckpt`) sent per-request so Draw Things
    /// uses a fast dedicated model for seam healing without altering your normal 360° generation model.
    public var model: String?

    public init(
        prompt: String,
        negativePrompt: String = "",
        initImagePNG: Data,
        maskPNG: Data,
        width: Int,
        height: Int,
        denoisingStrength: Double = 0.78,
        maskBlur: Int = 8,
        seed: Int = -1,
        steps: Int? = nil,
        shift: Double? = nil,
        resolutionDependentShift: Bool? = nil,
        guidanceScale: Double? = nil,
        sampler: DrawThingsSamplerOption = .keepActive,
        disableLoRAs: Bool = true,
        model: String? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.initImagePNG = initImagePNG
        self.maskPNG = maskPNG
        self.width = width
        self.height = height
        self.denoisingStrength = min(max(denoisingStrength, 0.05), 1.0)
        self.maskBlur = max(0, maskBlur)
        self.seed = seed
        self.steps = steps
        self.shift = shift
        self.resolutionDependentShift = resolutionDependentShift
        self.guidanceScale = guidanceScale
        self.sampler = sampler
        self.disableLoRAs = disableLoRAs
        self.model = model
    }

    /// Builds a clean Draw Things `POST /sdapi/v1/img2img` JSON payload containing only keys
    /// accepted by Draw Things' strict HTTP validator (omitting unsupported A1111 keys like
    /// `mask`, `inpainting_mask_invert`, and `inpainting_fill` which trigger HTTP 422).
    public func toJSONObject() -> [String: Any] {
        let clampedStrength = min(max(denoisingStrength, 0.05), 1.0)
        var dict: [String: Any] = [
            "prompt": prompt,
            "init_images": [initImagePNG.base64EncodedString()],
            "width": width,
            "height": height,
            "denoising_strength": clampedStrength,
            "seed": seed,
            "batch_count": 1,
            "batch_size": 1,
            // Ignore any stale canvas/mask left open in Draw Things UI (PanoSplat3D preserves outer pixels itself)
            "preserve_original_after_inpaint": false,
            "controls": [],
            // Explicitly disable Draw Things upscaler with `null` + scale 0 (NEVER `""`, which enables a broken 400% upscaler!)
            "upscaler": NSNull(),
            "upscaler_scale": 0
        ]
        if disableLoRAs {
            dict["loras"] = []
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            dict["model"] = model
        }
        let trimmedNeg = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNeg.isEmpty {
            dict["negative_prompt"] = trimmedNeg
        }
        if let steps, steps > 0 {
            dict["steps"] = steps
        }
        if let shift, shift > 0 {
            dict["shift"] = shift
        }
        if let resShift = resolutionDependentShift {
            dict["resolution_dependent_shift"] = resShift
        }
        if let cfg = guidanceScale, cfg >= 0 {
            dict["guidance_scale"] = cfg
        }
        if sampler != .keepActive {
            dict["sampler"] = sampler.rawValue
        }
        return dict
    }
}

/// Live progress update polled from `GET /sdapi/v1/progress`.
public struct DrawThingsProgress: Equatable, Sendable {
    public let fraction: Double
    public let currentStep: Int?
    public let totalSteps: Int?
    public let hasStarted: Bool

    public init(fraction: Double, currentStep: Int? = nil, totalSteps: Int? = nil, hasStarted: Bool = false) {
        self.fraction = min(max(fraction, 0.0), 1.0)
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.hasStarted = hasStarted || fraction > 0.0 || (currentStep ?? 0) > 0
    }
}

public enum DrawThingsError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case emptyPrompt
    case serverUnreachable(String)
    case httpError(Int, String)
    case invalidImagePayload

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url):
            return "Invalid Draw Things API URL: \(url)"
        case .emptyPrompt:
            return "Please enter a prompt describing your 360° panorama."
        case .serverUnreachable(let reason):
            return "Could not connect to Draw Things HTTP API (\(reason)). Make sure Draw Things is open with API Server → HTTP enabled."
        case .httpError(let code, let body):
            let short = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            return "Draw Things API returned HTTP \(code)\(short.isEmpty ? "" : ": \(short)")"
        case .invalidImagePayload:
            return "Draw Things returned a response without a valid image."
        }
    }
}

/// Zero-dependency native `URLSession` client for Draw Things' local HTTP API (`127.0.0.1:7860`).
public final class DrawThingsClient: Sendable {
    public init() {}

    /// Finds `Draw Things.app` installed on this Mac (Applications folder or LaunchServices bundle ID).
    @MainActor
    public static func installedDrawThingsAppURL() -> URL? {
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.liuliu.draw-things") {
            return byID
        }
        let candidates = [
            URL(fileURLWithPath: "/Applications/Draw Things.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Draw Things.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Default sandboxed Models directory used by macOS Draw Things (`com.liuliu.draw-things`).
    public static var defaultDrawThingsModelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models", isDirectory: true)
    }

    /// Returns `true` when a Draw Things checkpoint filename looks like a dedicated inpainting model.
    public static func isLikelyInpaintingModel(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.contains("inpaint") || lower.contains("fill")
    }

    /// Returns `true` when a Draw Things checkpoint filename looks like an SD 1.5 model (such as Realistic Vision).
    public static func isLikelySD15Model(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.contains("realistic_vision")
            || lower.contains("sd_v1")
            || lower.contains("sd15")
            || lower.contains("sd_1.5")
            || lower.contains("dreamshaper_v")
            || lower.contains("epicrealism")
    }

    /// Returns `true` when a Draw Things checkpoint filename is an SDXL model (e.g. Juggernaut XL, RealVisXL),
    /// which works best with `20 steps`, `CFG 5.5`, `Shift 1.0`, `DPM++ 2M Karras`.
    public static func isLikelySDXLModel(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.contains("sdxl")
            || lower.contains("sd_xl")
            || lower.contains("juggernaut_xl")
            || lower.contains("realvisxl")
            || lower.contains("_xl_")
    }

    /// Returns `true` when a Draw Things checkpoint filename is a distilled FLUX.2 Klein model
    /// (4B or 9B non-Base), which requires `steps = 4` and `guidance_scale = 1.0` (higher CFG causes NaN black output).
    public static func isLikelyFluxKleinDistilled(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.contains("flux_2_klein") && !lower.contains("base")
    }

    /// Returns `true` when a Draw Things checkpoint filename is a distilled Qwen Turbo model (`steps = 8`, `CFG = 1.0`).
    public static func isLikelyQwenTurbo(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.contains("qwen") && lower.contains("turbo")
    }

    /// Scans Draw Things' local `Models` folder for installed diffusion checkpoints (`.ckpt`),
    /// filtering out LoRAs, VAEs, CLIP/text encoders, and ControlNets, and sorting inpainting / fast models first.
    public static func discoverInstalledModels(modelsDirectory: URL? = nil) -> [String] {
        let dir = modelsDirectory ?? defaultDrawThingsModelsDirectory
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return []
        }

        let excludedSubstrings = [
            "_lora", "lora_", "_vae", "vae_", "clip_", "_clip",
            "t5_", "umt5_", "qwen_3_", "llama_", "siglip",
            "controlnet", "ip_adapter", "upscaler", "esrgan", "ultrasharp",
            "open_clip", "text_encoder", "refiner"
        ]

        var models: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".ckpt") else { continue }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }

            let lower = name.lowercased()
            if excludedSubstrings.contains(where: { lower.contains($0) }) {
                continue
            }
            models.append(name)
        }

        return models.sorted { a, b in
            let aInpaint = isLikelyInpaintingModel(a)
            let bInpaint = isLikelyInpaintingModel(b)
            if aInpaint != bInpaint { return aInpaint }
            let aSDXL = isLikelySDXLModel(a)
            let bSDXL = isLikelySDXLModel(b)
            if aSDXL != bSDXL { return aSDXL }
            let aKleinDist = isLikelyFluxKleinDistilled(a)
            let bKleinDist = isLikelyFluxKleinDistilled(b)
            if aKleinDist != bKleinDist { return aKleinDist }
            let aSD15 = isLikelySD15Model(a)
            let bSD15 = isLikelySD15Model(b)
            if aSD15 != bSD15 { return aSD15 }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Launches Draw Things via macOS `NSWorkspace` so the user doesn't have to locate it manually.
    @MainActor
    public static func launchDrawThingsApp() -> Bool {
        guard let appURL = installedDrawThingsAppURL() else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        return true
    }

    /// Builds a normalized base URL from host & port (e.g. `http://127.0.0.1:7860`).
    public static func makeBaseURL(host: String = "127.0.0.1", port: Int = 7860) throws -> URL {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = trimmedHost.isEmpty ? "127.0.0.1" : trimmedHost
        let urlString: String
        if cleanHost.hasPrefix("http://") || cleanHost.hasPrefix("https://") {
            urlString = "\(cleanHost):\(port)"
        } else {
            urlString = "http://\(cleanHost):\(port)"
        }
        guard let url = URL(string: urlString) else {
            throw DrawThingsError.invalidEndpoint(urlString)
        }
        return url
    }

    /// Parses live Draw Things configuration returned by `GET /` or `GET /sdapi/v1/options`.
    public static func parseConfigSnapshot(_ data: Data) -> DrawThingsConfigSnapshot {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return DrawThingsConfigSnapshot()
        }

        func doubleVal(_ keys: [String]) -> Double? {
            for k in keys {
                if let d = obj[k] as? Double { return d }
                if let n = obj[k] as? NSNumber { return n.doubleValue }
            }
            return nil
        }

        func intVal(_ keys: [String]) -> Int? {
            for k in keys {
                if let i = obj[k] as? Int { return i }
                if let n = obj[k] as? NSNumber { return n.intValue }
            }
            return nil
        }

        func boolVal(_ keys: [String]) -> Bool? {
            for k in keys {
                if let b = obj[k] as? Bool { return b }
            }
            return nil
        }

        let model = (obj["model"] as? String) ?? (obj["sd_model_checkpoint"] as? String)
        let steps = intVal(["steps"])
        let shift = doubleVal(["shift"])
        let guidance = doubleVal(["guidance_scale", "guidanceScale", "cfg_scale"])
        let resShift = boolVal(["resolution_dependent_shift", "resolutionDependentShift"])
        let width = intVal(["width"])
        let height = intVal(["height"])
        let upscaler = obj["upscaler"] as? String

        let rawSampler = obj["sampler"] ?? obj["sampler_name"]
        let samplerOption = DrawThingsSamplerOption.from(rawValueOrIndex: rawSampler)
        let samplerLabel: String?
        if let opt = samplerOption {
            samplerLabel = opt.rawValue
        } else if let str = rawSampler as? String, !str.isEmpty {
            samplerLabel = str
        } else {
            samplerLabel = nil
        }

        var parsedLoras: [DrawThingsLoRAEntry] = []
        if let rawLoras = obj["loras"] as? [[String: Any]] {
            for item in rawLoras {
                if let file = item["file"] as? String, !file.isEmpty {
                    let weight = (item["weight"] as? Double)
                        ?? (item["weight"] as? NSNumber)?.doubleValue
                        ?? 1.0
                    let mode = (item["mode"] as? String) ?? "all"
                    parsedLoras.append(DrawThingsLoRAEntry(file: file, weight: weight, mode: mode))
                }
            }
        }

        return DrawThingsConfigSnapshot(
            model: model,
            steps: steps,
            shift: shift,
            guidanceScale: guidance,
            resolutionDependentShift: resShift,
            samplerLabel: samplerLabel,
            samplerOption: samplerOption,
            upscaler: upscaler,
            width: width,
            height: height,
            loras: parsedLoras
        )
    }

    /// Parses progress JSON returned by `GET /sdapi/v1/progress`.
    public static func parseProgressResponse(_ data: Data) -> DrawThingsProgress? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let progressVal = (obj["progress"] as? Double)
            ?? (obj["progress"] as? NSNumber)?.doubleValue
        var curStep: Int?
        var totSteps: Int?
        var jobActive = false
        if let state = obj["state"] as? [String: Any] {
            curStep = state["sampling_step"] as? Int
            totSteps = state["sampling_steps"] as? Int
            if let job = state["job"] as? String, !job.isEmpty {
                jobActive = true
            }
        }
        if let progressVal {
            return DrawThingsProgress(
                fraction: progressVal,
                currentStep: curStep,
                totalSteps: totSteps,
                hasStarted: jobActive || progressVal > 0 || (curStep ?? 0) > 0
            )
        }
        if let curStep, let totSteps, totSteps > 0 {
            return DrawThingsProgress(
                fraction: Double(curStep) / Double(totSteps),
                currentStep: curStep,
                totalSteps: totSteps,
                hasStarted: jobActive || curStep > 0
            )
        }
        return nil
    }

    /// Extracts and decodes the first PNG/JPEG image from a Draw Things `txt2img` JSON response.
    public static func decodeFirstImageData(from responseData: Data) throws -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
              let images = obj["images"] as? [String],
              let first = images.first,
              !first.isEmpty else {
            throw DrawThingsError.invalidImagePayload
        }

        let base64String: String
        if let commaIndex = first.firstIndex(of: ","), first[..<commaIndex].contains("base64") {
            base64String = String(first[first.index(after: commaIndex)...])
        } else {
            base64String = first
        }

        guard let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              !decoded.isEmpty else {
            throw DrawThingsError.invalidImagePayload
        }
        return decoded
    }

    /// Pings the local Draw Things HTTP server and fetches its full live configuration (`GET /` then `/sdapi/v1/options`).
    public func checkStatus(host: String = "127.0.0.1", port: Int = 7860) async -> DrawThingsServerStatus {
        guard let baseURL = try? Self.makeBaseURL(host: host, port: port) else {
            return .offline(reason: "Invalid host/port")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Draw Things returns its richest live GenerationConfiguration JSON on `GET /`, and A1111 options on `/sdapi/v1/options`
        var bestSnapshot: DrawThingsConfigSnapshot?
        var reachedServer = false

        for path in ["", "sdapi/v1/options"] {
            let endpoint = path.isEmpty ? baseURL : baseURL.appendingPathComponent(path)
            var req = URLRequest(url: endpoint)
            req.httpMethod = "GET"
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    reachedServer = true
                    let parsed = Self.parseConfigSnapshot(data)
                    if let existing = bestSnapshot {
                        bestSnapshot = DrawThingsConfigSnapshot(
                            model: existing.model ?? parsed.model,
                            steps: existing.steps ?? parsed.steps,
                            shift: existing.shift ?? parsed.shift,
                            guidanceScale: existing.guidanceScale ?? parsed.guidanceScale,
                            resolutionDependentShift: existing.resolutionDependentShift ?? parsed.resolutionDependentShift,
                            samplerLabel: existing.samplerLabel ?? parsed.samplerLabel,
                            samplerOption: existing.samplerOption ?? parsed.samplerOption,
                            upscaler: existing.upscaler ?? parsed.upscaler,
                            width: existing.width ?? parsed.width,
                            height: existing.height ?? parsed.height,
                            loras: existing.loras.isEmpty ? parsed.loras : existing.loras
                        )
                    } else {
                        bestSnapshot = parsed
                    }
                    // If `GET /` already gave us model + steps + shift, no need for a second request
                    if bestSnapshot?.model != nil && bestSnapshot?.steps != nil && bestSnapshot?.shift != nil {
                        break
                    }
                }
            } catch {
                continue
            }
        }

        if reachedServer {
            return .online(bestSnapshot ?? DrawThingsConfigSnapshot())
        }
        return .offline(reason: "No server listening on \(host):\(port)")
    }

    /// Calls `POST /sdapi/v1/txt2img`, polls `/sdapi/v1/progress` every 0.4s for live status, and saves the generated panorama to disk.
    public func generatePanorama(
        host: String = "127.0.0.1",
        port: Int = 7860,
        request: DrawThingsGenerationRequest,
        saveDirectory: URL? = nil,
        onProgress: @Sendable @escaping (DrawThingsProgress) -> Void = { _ in }
    ) async throws -> URL {
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw DrawThingsError.emptyPrompt
        }

        let baseURL = try Self.makeBaseURL(host: host, port: port)
        let txt2imgURL = baseURL.appendingPathComponent("sdapi/v1/txt2img")
        let progressURL = baseURL.appendingPathComponent("sdapi/v1/progress")
        let interruptURL = baseURL.appendingPathComponent("sdapi/v1/interrupt")

        var normalizedRequest = request
        normalizedRequest.prompt = trimmedPrompt
        let bodyData = try JSONSerialization.data(withJSONObject: normalizedRequest.toJSONObject(), options: [])

        var urlRequest = URLRequest(url: txt2imgURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let genConfig = URLSessionConfiguration.ephemeral
        genConfig.timeoutIntervalForRequest = 600
        genConfig.timeoutIntervalForResource = 900
        let genSession = URLSession(configuration: genConfig)
        defer { genSession.invalidateAndCancel() }

        // Background progress poller every 0.4s so the user immediately sees when Draw Things starts generating
        let pollTask = Task.detached(priority: .utility) {
            let pollConfig = URLSessionConfiguration.ephemeral
            pollConfig.timeoutIntervalForRequest = 2.0
            let pollSession = URLSession(configuration: pollConfig)
            defer { pollSession.invalidateAndCancel() }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { break }
                if let (data, resp) = try? await pollSession.data(from: progressURL),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let parsed = Self.parseProgressResponse(data) {
                    onProgress(parsed)
                }
            }
        }
        defer { pollTask.cancel() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await genSession.data(for: urlRequest)
            } onCancel: {
                Task.detached {
                    var stopReq = URLRequest(url: interruptURL)
                    stopReq.httpMethod = "POST"
                    _ = try? await URLSession.shared.data(for: stopReq)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DrawThingsError.serverUnreachable(error.localizedDescription)
        }

        pollTask.cancel()

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw DrawThingsError.httpError(http.statusCode, bodyText)
        }

        let imageBytes = try Self.decodeFirstImageData(from: data)

        let outputDir: URL
        if let saveDirectory {
            outputDir = saveDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            outputDir = appSupport
                .appendingPathComponent("PanoSplat3D", isDirectory: true)
                .appendingPathComponent("GeneratedPanoramas", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let shortSlug = Self.shortFilenameSlug(from: trimmedPrompt)
        let timestamp = Int(Date().timeIntervalSince1970)
        let ext = Self.detectImageExtension(from: imageBytes)
        let savedURL = outputDir.appendingPathComponent("\(shortSlug)_\(timestamp).\(ext)")
        try imageBytes.write(to: savedURL, options: .atomic)

        return savedURL
    }

    /// Calls `POST /sdapi/v1/img2img` with the 180°-shifted panorama and white-center inpaint mask,
    /// polling `/sdapi/v1/progress` every 0.4s and supporting clean cancellation via `/sdapi/v1/interrupt`.
    public func inpaintSeam(
        host: String = "127.0.0.1",
        port: Int = 7860,
        request: DrawThingsInpaintRequest,
        onProgress: @Sendable @escaping (DrawThingsProgress) -> Void = { _ in }
    ) async throws -> Data {
        let baseURL = try Self.makeBaseURL(host: host, port: port)
        let img2imgURL = baseURL.appendingPathComponent("sdapi/v1/img2img")
        let progressURL = baseURL.appendingPathComponent("sdapi/v1/progress")
        let interruptURL = baseURL.appendingPathComponent("sdapi/v1/interrupt")

        var normalized = request
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.prompt = trimmed.isEmpty
            ? "seamless continuous landscape continuation, matching lighting and texture, photorealistic"
            : trimmed

        let bodyData = try JSONSerialization.data(withJSONObject: normalized.toJSONObject(), options: [])

        var urlRequest = URLRequest(url: img2imgURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 600
        sessionConfig.timeoutIntervalForResource = 900
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let pollTask = Task.detached(priority: .utility) {
            let pollConfig = URLSessionConfiguration.ephemeral
            pollConfig.timeoutIntervalForRequest = 2.0
            let pollSession = URLSession(configuration: pollConfig)
            defer { pollSession.invalidateAndCancel() }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { break }
                if let (data, resp) = try? await pollSession.data(from: progressURL),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let parsed = Self.parseProgressResponse(data) {
                    onProgress(parsed)
                }
            }
        }
        defer { pollTask.cancel() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await session.data(for: urlRequest)
            } onCancel: {
                Task.detached {
                    var stopReq = URLRequest(url: interruptURL)
                    stopReq.httpMethod = "POST"
                    _ = try? await URLSession.shared.data(for: stopReq)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DrawThingsError.serverUnreachable(error.localizedDescription)
        }

        pollTask.cancel()

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw DrawThingsError.httpError(http.statusCode, bodyText)
        }

        return try Self.decodeFirstImageData(from: data)
    }

    private static func shortFilenameSlug(from prompt: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = prompt
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { $0.count >= 2 }
            .prefix(5)
        let joined = words.joined(separator: "_")
        if joined.isEmpty { return "drawthings_pano" }
        return String(joined.prefix(32))
    }

    private static func detectImageExtension(from data: Data) -> String {
        if data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
            return "jpg"
        }
        return "png"
    }
}
