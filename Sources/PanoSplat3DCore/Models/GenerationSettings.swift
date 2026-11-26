import Foundation

/// Training step presets matching SPEC Section 1.4.
public enum TrainingStepsPreset: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fast = 5_000
    case balanced = 8_000
    case high = 15_000

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .fast: return "5,000 (Fast)"
        case .balanced: return "8,000 (Balanced)"
        case .high: return "15,000 (High)"
        }
    }
}

/// Perspective view resolution presets controlling both sliced view size and Brush `--max-resolution`.
public enum ViewResolutionPreset: Int, CaseIterable, Identifiable, Codable, Sendable {
    case draft = 768
    case standard = 1024
    case sharp = 1280
    case ultra = 1536

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .draft: return "768 (Fast)"
        case .standard: return "1024"
        case .sharp: return "1280 (Sharp)"
        case .ultra: return "1536 (Ultra)"
        }
    }
}

/// Spherical Harmonics degree options (1, 2, or 3).
public enum SphericalHarmonicsDegree: Int, CaseIterable, Identifiable, Codable, Sendable {
    case one = 1
    case two = 2
    case three = 3

    public var id: Int { rawValue }

    public var label: String { "\(rawValue)" }
}

/// Export mode toggle between full Brush `.ply` splat export and COLMAP dataset folder export.
public enum ExportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case plySplat = "plySplat"
    case colmapDataset = "colmapDataset"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .plySplat: return "Export .ply Splat"
        case .colmapDataset: return "Export COLMAP Dataset Only"
        }
    }

    public var shortDescription: String {
        switch self {
        case .plySplat:
            return "Runs all 4 stages automatically (Depth → Point Cloud → Parallax Masks → Brush) and saves a SuperSplat / UE5 ready .ply."
        case .colmapDataset:
            return "Runs stages 1–3 and saves the intermediate COLMAP folder (images, masks, sparse/0, init.ply) without running Brush."
        }
    }
}

/// Complete configuration for panorama-to-3DGS conversion.
public struct GenerationSettings: Codable, Equatable, Sendable {
    /// CoreML monocular depth estimation model (V2 Small, V3 Base, or Apple Depth Pro 1536px).
    public var depthModel: DepthModelVariant = .depthAnythingV2Small

    /// Depth scale / room radius in meters (2.0m – 50.0m, default 12.0m).
    public var depthScaleMeters: Double = 12.0

    /// Multi-view camera parallax baseline radius in meters (0.0m – 2.0m, default 0.50m).
    public var parallaxBaselineMeters: Double = 0.50

    /// Brush training steps preset (default 8,000 Balanced).
    public var trainingSteps: TrainingStepsPreset = .balanced

    /// Spherical Harmonics degree (default 2).
    public var shDegree: SphericalHarmonicsDegree = .two

    /// Export mode (default `.plySplat` for 1-click SuperSplat / Unreal `.ply` generation).
    public var exportMode: ExportMode = .plySplat

    /// Perspective camera view resolution (square width = height in pixels).
    public var perspectiveResolution: Int = 1280

    /// Convenience binding helper mapping `perspectiveResolution` to `ViewResolutionPreset`.
    public var viewResolutionPreset: ViewResolutionPreset {
        get { ViewResolutionPreset(rawValue: perspectiveResolution) ?? .sharp }
        set { perspectiveResolution = newValue.rawValue }
    }

    /// Perspective camera horizontal/vertical FOV in degrees (`82°` minimizes wide-angle edge stretching).
    public var fieldOfViewDegrees: Double = 82.0

    /// Target point count for gradient-importance-sampled `init.ply`.
    public var initialPointCount: Int = 220_000

    /// Automatically AI-upscale 2× (360°-wrap-safe CoreML) when input panorama width is under 3072px.
    public var autoUpscaleLowRes: Bool = true

    /// Selected CoreML 360°-wrap-safe AI upscaler architecture (default: RealPLKSR 2× Natural).
    public var upscalerModel: UpscalerModelVariant = .realPLKSR2xNatural

    /// AI-to-bicubic blend strength (`0.50...1.0`, default `0.80`). Blends AI sharpening with a
    /// 360°-wrap-safe bicubic resize of the original to retain organic grain and prevent plastic sheen.
    public var upscalerBlendStrength: Double = 0.80

    /// Plays `coin.wav` on successful completion and the macOS alert sound on failure.
    public var playAlertSounds: Bool = true

    /// Remembers and reuses the last output destination folder across new panoramas & launches.
    public var saveToLastUsedFolder: Bool = true

    /// Uses CoreML `LaMa` to inpaint disoccluded background voids behind foreground trees/rocks in offset parallax views.
    public var inpaintParallaxHoles: Bool = true

    public init(
        depthModel: DepthModelVariant = .depthAnythingV2Small,
        depthScaleMeters: Double = 12.0,
        parallaxBaselineMeters: Double = 0.50,
        trainingSteps: TrainingStepsPreset = .balanced,
        shDegree: SphericalHarmonicsDegree = .two,
        exportMode: ExportMode = .plySplat,
        perspectiveResolution: Int = 1280,
        fieldOfViewDegrees: Double = 82.0,
        initialPointCount: Int = 220_000,
        autoUpscaleLowRes: Bool = true,
        upscalerModel: UpscalerModelVariant = .realPLKSR2xNatural,
        upscalerBlendStrength: Double = 0.80,
        playAlertSounds: Bool = true,
        saveToLastUsedFolder: Bool = true,
        inpaintParallaxHoles: Bool = true
    ) {
        self.depthModel = depthModel
        self.depthScaleMeters = depthScaleMeters
        self.parallaxBaselineMeters = parallaxBaselineMeters
        self.trainingSteps = trainingSteps
        self.shDegree = shDegree
        self.exportMode = exportMode
        self.perspectiveResolution = perspectiveResolution
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.initialPointCount = initialPointCount
        self.autoUpscaleLowRes = autoUpscaleLowRes
        self.upscalerModel = upscalerModel
        self.upscalerBlendStrength = upscalerBlendStrength
        self.playAlertSounds = playAlertSounds
        self.saveToLastUsedFolder = saveToLastUsedFolder
        self.inpaintParallaxHoles = inpaintParallaxHoles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.depthModel = try c.decodeIfPresent(DepthModelVariant.self, forKey: .depthModel) ?? .depthAnythingV2Small
        self.depthScaleMeters = try c.decodeIfPresent(Double.self, forKey: .depthScaleMeters) ?? 12.0
        self.parallaxBaselineMeters = try c.decodeIfPresent(Double.self, forKey: .parallaxBaselineMeters) ?? 0.50
        self.trainingSteps = try c.decodeIfPresent(TrainingStepsPreset.self, forKey: .trainingSteps) ?? .balanced
        self.shDegree = try c.decodeIfPresent(SphericalHarmonicsDegree.self, forKey: .shDegree) ?? .two
        self.exportMode = try c.decodeIfPresent(ExportMode.self, forKey: .exportMode) ?? .plySplat
        self.perspectiveResolution = try c.decodeIfPresent(Int.self, forKey: .perspectiveResolution) ?? 1280
        self.fieldOfViewDegrees = try c.decodeIfPresent(Double.self, forKey: .fieldOfViewDegrees) ?? 82.0
        self.initialPointCount = try c.decodeIfPresent(Int.self, forKey: .initialPointCount) ?? 220_000
        self.autoUpscaleLowRes = try c.decodeIfPresent(Bool.self, forKey: .autoUpscaleLowRes) ?? true
        self.upscalerModel = try c.decodeIfPresent(UpscalerModelVariant.self, forKey: .upscalerModel) ?? .realPLKSR2xNatural
        self.upscalerBlendStrength = try c.decodeIfPresent(Double.self, forKey: .upscalerBlendStrength) ?? 0.80
        self.playAlertSounds = try c.decodeIfPresent(Bool.self, forKey: .playAlertSounds) ?? true
        self.saveToLastUsedFolder = try c.decodeIfPresent(Bool.self, forKey: .saveToLastUsedFolder) ?? true
        self.inpaintParallaxHoles = try c.decodeIfPresent(Bool.self, forKey: .inpaintParallaxHoles) ?? true
    }
}
