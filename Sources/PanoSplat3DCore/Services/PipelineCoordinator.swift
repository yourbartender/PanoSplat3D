import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Central @MainActor view model coordinating Brush engine discovery, CoreML depth model lifecycle,
/// native file dialogs, settings persistence, interactive 3D preview, and the full 4-stage generation pipeline.
@MainActor
@Observable
public final class PipelineCoordinator {
    private static let settingsKey = "PanoSplat3D.generationSettings.v3"
    private static let lastInputPathKey = "PanoSplat3D.lastInputPanoramaPath"
    private static let lastOutputDirectoryKey = "PanoSplat3D.lastOutputDirectoryPath"
    private static let drawThingsPortKey = "PanoSplat3D.drawThingsPort"
    private static let drawThingsPromptKey = "PanoSplat3D.drawThingsPrompt"
    private static let drawThingsNegPromptKey = "PanoSplat3D.drawThingsNegativePrompt"

    public private(set) var brushEngine: ResolvedBrushEngine?
    public var brushError: String?

    public private(set) var depthModelState: DepthModelState = .notDownloaded
    public private(set) var upscalerModelState: UpscalerModelState = .notDownloaded
    public private(set) var isUpscalingPanorama: Bool = false
    public private(set) var upscaleProgress: Double = 0.0
    public private(set) var upscaleStatusText: String = ""
    public private(set) var previousPanoramaBeforeUpscale: PanoramaAsset?
    public private(set) var lastUpscaleSummary: String?
    public private(set) var lastSavedUpscaledURL: URL?

    public var isCurrentPanoramaUpscaled: Bool {
        previousPanoramaBeforeUpscale != nil
    }

    public var canUndoUpscale: Bool {
        previousPanoramaBeforeUpscale != nil && !isRunning && !isUpscalingPanorama && !isRunningBatch
    }

    // Overnight Batch Queue state
    public private(set) var batchItems: [BatchQueueItem] = []
    public var batchOutputDirectory: URL?
    public private(set) var isRunningBatch: Bool = false
    public private(set) var batchActiveItemID: UUID?
    public private(set) var batchSummaryText: String = ""
    public var isShowingBatchSheet: Bool = false
    private var batchTask: Task<Void, Never>?

    // Standard macOS Edit → Undo (⌘Z) / Redo (⇧⌘Z) history stack
    private var editHistory = UndoRedoStack<CoordinatorUndoSnapshot>(maxEntries: 10)
    public private(set) var historyRevision: Int = 0

    private var isBusyWithActiveWork: Bool {
        isRunning || isRunningBatch || isUpscalingPanorama || isHealingSeam || isGeneratingWithDrawThings
    }

    public var canUndo: Bool {
        _ = historyRevision
        return editHistory.canUndo && !isBusyWithActiveWork
    }

    public var canRedo: Bool {
        _ = historyRevision
        return editHistory.canRedo && !isBusyWithActiveWork
    }

    public var undoMenuTitle: String {
        _ = historyRevision
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canUndo {
            let name = um.undoActionName
            return name.isEmpty ? "Undo Typing" : "Undo \(name)"
        }
        if let name = editHistory.undoActionName {
            return "Undo \(name)"
        }
        return "Undo"
    }

    public var redoMenuTitle: String {
        _ = historyRevision
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canRedo {
            let name = um.redoActionName
            return name.isEmpty ? "Redo Typing" : "Redo \(name)"
        }
        if let name = editHistory.redoActionName {
            return "Redo \(name)"
        }
        return "Redo"
    }

    public var canPerformEditMenuUndo: Bool {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            return tv.undoManager?.canUndo == true || canUndo
        }
        return canUndo
    }

    public var canPerformEditMenuRedo: Bool {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            return tv.undoManager?.canRedo == true || canRedo
        }
        return canRedo
    }

    private func captureUndoSnapshot() -> CoordinatorUndoSnapshot {
        CoordinatorUndoSnapshot(
            panorama: panorama,
            previousPanoramaBeforeUpscale: previousPanoramaBeforeUpscale,
            lastUpscaleSummary: lastUpscaleSummary,
            previousPanoramaBeforeSeamHeal: previousPanoramaBeforeSeamHeal,
            previousPanoramaURLBeforeSeamHeal: previousPanoramaURLBeforeSeamHeal,
            depthMap: depthMap,
            depthPreviewImage: depthPreviewImage,
            settings: settings,
            batchItems: batchItems,
            editableOutputName: editableOutputName,
            outputURL: outputURL
        )
    }

    private func restoreUndoSnapshot(_ snap: CoordinatorUndoSnapshot) {
        self.panorama = snap.panorama
        self.previousPanoramaBeforeUpscale = snap.previousPanoramaBeforeUpscale
        self.lastUpscaleSummary = snap.lastUpscaleSummary
        self.previousPanoramaBeforeSeamHeal = snap.previousPanoramaBeforeSeamHeal
        self.previousPanoramaURLBeforeSeamHeal = snap.previousPanoramaURLBeforeSeamHeal
        self.depthMap = snap.depthMap
        self.depthPreviewImage = snap.depthPreviewImage
        self.settings = snap.settings
        self.batchItems = snap.batchItems
        self.editableOutputName = snap.editableOutputName
        self.outputURL = snap.outputURL
    }

    private func recordUndoState(actionName: String) {
        editHistory.recordBeforeChange(actionName: actionName, state: captureUndoSnapshot())
        historyRevision &+= 1
    }

    /// Standard macOS Edit → Undo (`⌘Z`): delegates to active TextField editor when editing text,
    /// otherwise pops the multi-step PanoSplat3D document history (Seam Heal, AI Upscale, Load Panorama, Batch Queue, Presets).
    public func performEditMenuUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canUndo {
            um.undo()
            return
        }
        guard canUndo else { return }
        let current = captureUndoSnapshot()
        guard let entry = editHistory.undo(currentState: current) else { return }
        restoreUndoSnapshot(entry.state)
        historyRevision &+= 1
        stageTitle = "Ready"
        stageDetail = "Undid \(entry.actionName)"
    }

    /// Standard macOS Edit → Redo (`⇧⌘Z`): delegates to active TextField editor when editing text,
    /// otherwise re-applies the most recently undone PanoSplat3D edit.
    public func performEditMenuRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canRedo {
            um.redo()
            return
        }
        guard canRedo else { return }
        let current = captureUndoSnapshot()
        guard let entry = editHistory.redo(currentState: current) else { return }
        restoreUndoSnapshot(entry.state)
        historyRevision &+= 1
        stageTitle = "Ready"
        stageDetail = "Redid \(entry.actionName)"
    }

    /// Applies a one-click Depth Scale + Parallax Baseline scene preset with full `⌘Z` / `⇧⌘Z` Undo/Redo support.
    public func applyScenePreset(name: String, depthScaleMeters: Double, parallaxBaselineMeters: Double) {
        guard !isBusyWithActiveWork else { return }
        recordUndoState(actionName: "Preset (\(name))")
        settings.depthScaleMeters = depthScaleMeters
        settings.parallaxBaselineMeters = parallaxBaselineMeters
        stageDetail = String(format: "Applied %@ preset (%.1fm depth, %.2fm parallax)", name, depthScaleMeters, parallaxBaselineMeters)
    }

    // Draw Things local HTTP API state (Phase B)
    public private(set) var drawThingsStatus: DrawThingsServerStatus = .unknown
    public var drawThingsPort: Int = 7860 {
        didSet { UserDefaults.standard.set(drawThingsPort, forKey: Self.drawThingsPortKey) }
    }
    public var drawThingsPrompt: String = "" {
        didSet { UserDefaults.standard.set(drawThingsPrompt, forKey: Self.drawThingsPromptKey) }
    }
    public var drawThingsNegativePrompt: String = "blurry, visible seam, distorted horizon, watermark, text" {
        didSet { UserDefaults.standard.set(drawThingsNegativePrompt, forKey: Self.drawThingsNegPromptKey) }
    }
    public var drawThingsSizePreset: DrawThingsSizePreset = .size1536x768
    public var drawThingsSeed: Int = -1
    public var drawThingsSteps: Int = 8
    public var drawThingsShift: Double = 3.0
    public var drawThingsResolutionDependentShift: Bool = true
    public var drawThingsGuidanceScale: Double = 3.5
    public var drawThingsSampler: DrawThingsSamplerOption = .keepActive
    public var drawThingsUpscaler: DrawThingsUpscalerOption = .none
    public private(set) var hasSyncedDrawThingsOnce: Bool = false
    public private(set) var isGeneratingWithDrawThings: Bool = false
    public private(set) var drawThingsProgress: Double = 0.0
    public private(set) var drawThingsProgressText: String = ""
    public var drawThingsError: String?
    public private(set) var requestSwitchTo360ViewToken: Int = 0
    public private(set) var requestJumpToBackSeamToken: Int = 0

    // 180°-Shift Seam Inpainting (Fast Local CoreML LaMa ~2s OR Draw Things /sdapi/v1/img2img)
    public static let defaultGenericSeamPrompt =
        "seamless natural continuation matching surrounding scene, lighting, colors, and fine surface texture, photorealistic"
    public var seamHealEngine: SeamHealEngine = .drawThings
    public var seamHealPrompt: String = PipelineCoordinator.defaultGenericSeamPrompt
    public var seamHealStrength: Double = 0.42
    public var seamHealStripWidth: SeamStripWidth = .narrow
    public var seamHealSizePreset: DrawThingsSizePreset = .size1536x768
    public var seamHealDisableLoRAs: Bool = true
    public private(set) var installedDrawThingsModels: [String] = []
    public var seamHealModelOverride: String = ""
    public private(set) var isHealingSeam: Bool = false
    public private(set) var seamHealProgress: Double = 0.0
    public private(set) var seamHealStatusText: String = ""
    public var seamHealError: String?
    public private(set) var previousPanoramaURLBeforeSeamHeal: URL?
    public private(set) var previousPanoramaBeforeSeamHeal: PanoramaAsset?
    public private(set) var lastExportedShifted180URL: URL?
    public private(set) var manualShiftStatusMessage: String?
    private var seamHealTask: Task<Void, Never>?

    public var isCurrentPanoramaSeamHealed: Bool {
        previousPanoramaBeforeSeamHeal != nil
    }

    public private(set) var panoramaRevision: Int = 0
    public private(set) var panorama: PanoramaAsset? {
        didSet { panoramaRevision &+= 1 }
    }
    public private(set) var isLoadingPanorama: Bool = false
    public var panoramaError: String?

    public private(set) var depthMap: EquirectangularDepthMap?
    public private(set) var depthPreviewImage: CGImage? {
        didSet { panoramaRevision &+= 1 }
    }
    public private(set) var previewCloud: PLYPreviewCloud?

    /// Exact destination URL (file `.ply` for `.plySplat`, or folder for `.colmapDataset`).
    public private(set) var outputURL: URL?
    /// Editable short output base name (without `.ply` extension) shown directly in the Output row.
    public var editableOutputName: String = ""
    private var hasUserChosenOutputDirectory: Bool = false
    private var hasUserEditedOutputName: Bool = false

    public var settings: GenerationSettings {
        didSet {
            persistSettings()
            if oldValue.exportMode != settings.exportMode {
                syncOutputURLForCurrentMode()
            }
            if oldValue.depthModel != settings.depthModel {
                refreshSelectedDepthModelState()
            }
            if oldValue.upscalerModel != settings.upscalerModel {
                refreshSelectedUpscalerModelState()
            }
            if oldValue.saveToLastUsedFolder != settings.saveToLastUsedFolder {
                applyOutputFolderPreferenceChange()
            }
        }
    }

    public private(set) var isRunning: Bool = false
    public private(set) var progress: Double = 0.0
    public private(set) var stageTitle: String = "Ready"
    public private(set) var stageDetail: String = "Drop a 2:1 equirectangular panorama to generate a 3D Gaussian Splat (.ply)."
    public private(set) var lastExportedURL: URL?
    public private(set) var lastDatasetResult: ColmapDatasetResult?
    public private(set) var lastTrainingResult: BrushTrainingResult?
    public var pipelineError: String?

    private let brushLocator: BrushEngineLocator
    private let depthEstimator: DepthEstimator
    private let panoramaUpscaler: PanoramaUpscaler
    private let holeInpainter: ParallaxHoleInpainter
    private let datasetWriter: ColmapDatasetWriter
    private let brushRunner: BrushTrainingRunner
    private let drawThingsClient: DrawThingsClient
    private var activeTask: Task<Void, Never>?
    private var modelDownloadTask: Task<Void, Never>?
    private var drawThingsTask: Task<Void, Never>?
    private var upscaleTask: Task<Void, Never>?

    public init(
        brushLocator: BrushEngineLocator = BrushEngineLocator(),
        depthEstimator: DepthEstimator = DepthEstimator(),
        panoramaUpscaler: PanoramaUpscaler = PanoramaUpscaler(),
        holeInpainter: ParallaxHoleInpainter = ParallaxHoleInpainter(),
        datasetWriter: ColmapDatasetWriter = ColmapDatasetWriter(),
        brushRunner: BrushTrainingRunner = BrushTrainingRunner(),
        drawThingsClient: DrawThingsClient = DrawThingsClient()
    ) {
        self.brushLocator = brushLocator
        self.depthEstimator = depthEstimator
        self.panoramaUpscaler = panoramaUpscaler
        self.holeInpainter = holeInpainter
        self.datasetWriter = datasetWriter
        self.brushRunner = brushRunner
        self.drawThingsClient = drawThingsClient
        self.settings = Self.loadPersistedSettings() ?? GenerationSettings()

        let savedPort = UserDefaults.standard.integer(forKey: Self.drawThingsPortKey)
        if savedPort > 0 && savedPort <= 65535 {
            self.drawThingsPort = savedPort
        }
        if let savedPrompt = UserDefaults.standard.string(forKey: Self.drawThingsPromptKey) {
            self.drawThingsPrompt = savedPrompt
        }
        if let savedNeg = UserDefaults.standard.string(forKey: Self.drawThingsNegPromptKey) {
            self.drawThingsNegativePrompt = savedNeg
        }

        // Automatic Brush engine discovery on launch
        self.brushEngine = brushLocator.discover()

        // Restore last output directory if available
        if let savedDir = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey) {
            let dirURL = URL(fileURLWithPath: savedDir, isDirectory: true)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                self.editableOutputName = "pano_splat"
                self.outputURL = Self.buildOutputURL(in: dirURL, baseName: "pano_splat", mode: settings.exportMode)
                self.batchOutputDirectory = dirURL
                if settings.saveToLastUsedFolder {
                    self.hasUserChosenOutputDirectory = true
                }
            }
        }

        // Check whether selected CoreML depth model & upscaler models are already cached locally
        refreshSelectedDepthModelState()
        refreshSelectedUpscalerModelState()
    }

    // MARK: - Brush Engine Discovery & Selection

    public func refreshBrushDiscovery() {
        brushError = nil
        brushEngine = brushLocator.discover()
    }

    public func locateBrushViaDialog() {
        brushError = nil
        let initialDir = brushEngine?.displayURL.deletingLastPathComponent()
        guard let selectedURL = NativeFileDialogs.pickBrushEngine(initialDirectory: initialDir) else {
            return
        }
        do {
            let resolved = try brushLocator.saveUserSelection(selectedURL)
            brushEngine = resolved
        } catch {
            brushError = error.localizedDescription
        }
    }

    // MARK: - CoreML Depth Model Download

    public func refreshSelectedDepthModelState() {
        let selectedVariant = settings.depthModel
        let manager = depthEstimator.modelManager
        Task {
            let localURL = await manager.localModelURL(for: selectedVariant)
            guard self.settings.depthModel == selectedVariant else { return }
            if let localURL {
                self.depthModelState = .ready(modelURL: localURL)
            } else if !self.depthModelState.isBusy {
                self.depthModelState = .notDownloaded
            }
        }
    }

    public func downloadDepthModel() {
        guard !depthModelState.isBusy else { return }
        let selectedVariant = settings.depthModel
        let manager = depthEstimator.modelManager
        modelDownloadTask = Task.detached(priority: .userInitiated) {
            do {
                _ = try await manager.loadOrDownloadModel(variant: selectedVariant) { state in
                    Task { @MainActor in
                        if self.settings.depthModel == selectedVariant {
                            self.depthModelState = state
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.settings.depthModel == selectedVariant {
                        self.depthModelState = .notDownloaded
                    }
                }
            } catch {
                await MainActor.run {
                    if self.settings.depthModel == selectedVariant {
                        self.depthModelState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Draw Things Local HTTP API (Phase B)

    public func checkDrawThingsServer(applySyncedSettings: Bool = false) {
        drawThingsError = nil
        drawThingsStatus = .checking
        let port = drawThingsPort
        let client = drawThingsClient
        Task.detached(priority: .utility) {
            let status = await client.checkStatus(host: "127.0.0.1", port: port)
            await MainActor.run {
                self.drawThingsStatus = status
                if applySyncedSettings, let snap = status.snapshot {
                    self.applySyncedDrawThingsConfig(snap)
                }
            }
        }
    }

    public func launchDrawThingsAndCheck() {
        drawThingsError = nil
        guard DrawThingsClient.launchDrawThingsApp() else {
            drawThingsError = "Draw Things.app was not found in /Applications."
            return
        }
        drawThingsStatus = .checking
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.checkDrawThingsServer(applySyncedSettings: true)
        }
    }

    private func applySyncedDrawThingsConfig(_ snap: DrawThingsConfigSnapshot) {
        if let steps = snap.steps, steps > 0 {
            drawThingsSteps = steps
        }
        if let shift = snap.shift, shift > 0 {
            drawThingsShift = min(max(shift, 0.1), 10.0)
        }
        if let resShift = snap.resolutionDependentShift {
            drawThingsResolutionDependentShift = resShift
        }
        if let cfg = snap.guidanceScale, cfg >= 1.0 {
            drawThingsGuidanceScale = min(max(cfg, 1.0), 15.0)
        }
        if let sampler = snap.samplerOption {
            drawThingsSampler = sampler
        }
        if let upscaler = snap.upscaler {
            if upscaler.isEmpty {
                drawThingsUpscaler = .none
            } else if let matched = DrawThingsUpscalerOption(rawValue: upscaler) {
                drawThingsUpscaler = matched
            } else {
                drawThingsUpscaler = .keepActive
            }
        }
        hasSyncedDrawThingsOnce = true
    }

    public func generatePanoramaWithDrawThings(onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !isGeneratingWithDrawThings else { return }
        drawThingsError = nil
        isGeneratingWithDrawThings = true
        drawThingsProgress = 0.0
        drawThingsProgressText = "Sending prompt to Draw Things..."

        let port = drawThingsPort
        let client = drawThingsClient
        let req = DrawThingsGenerationRequest(
            prompt: drawThingsPrompt,
            negativePrompt: drawThingsNegativePrompt,
            sizePreset: drawThingsSizePreset,
            seed: drawThingsSeed,
            steps: drawThingsSteps,
            shift: drawThingsShift,
            resolutionDependentShift: drawThingsResolutionDependentShift,
            guidanceScale: drawThingsGuidanceScale,
            sampler: drawThingsSampler,
            upscaler: drawThingsUpscaler
        )

        drawThingsTask = Task.detached(priority: .userInitiated) {
            do {
                let savedURL = try await client.generatePanorama(
                    host: "127.0.0.1",
                    port: port,
                    request: req
                ) { update in
                    Task { @MainActor in
                        self.drawThingsProgress = update.fraction
                        if let cur = update.currentStep, let tot = update.totalSteps, tot > 0 {
                            self.drawThingsProgressText = "Generation started — Step \(cur) / \(tot)..."
                        } else if update.hasStarted {
                            self.drawThingsProgressText = "Generation started in Draw Things..."
                        } else {
                            self.drawThingsProgressText = "Waiting for Draw Things to begin..."
                        }
                    }
                }

                await MainActor.run {
                    self.isGeneratingWithDrawThings = false
                    self.drawThingsProgress = 1.0
                    self.drawThingsProgressText = "Loaded generated panorama"
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playSuccess()
                    }
                    self.loadPanorama(from: savedURL, switchTo360OnLoad: true)
                    onSuccess()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isGeneratingWithDrawThings = false
                    self.drawThingsProgress = 0.0
                    self.drawThingsProgressText = ""
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingWithDrawThings = false
                    self.drawThingsProgress = 0.0
                    self.drawThingsError = error.localizedDescription
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playError()
                    }
                }
            }
        }
    }

    public func cancelDrawThingsGeneration() {
        drawThingsTask?.cancel()
        drawThingsTask = nil
    }

    // MARK: - 180°-Shift 360° Seam Inpainting via Draw Things

    /// Scans Draw Things' local `Models` directory for installed `.ckpt` diffusion models and
    /// automatically pre-selects an inpainting or fast Realistic Vision / SD 1.5 model if present.
    public func refreshInstalledDrawThingsModels() {
        let found = DrawThingsClient.discoverInstalledModels()
        installedDrawThingsModels = found
        if seamHealModelOverride.isEmpty {
            if let preferred = found.first(where: {
                DrawThingsClient.isLikelyInpaintingModel($0)
                    || DrawThingsClient.isLikelySDXLModel($0)
                    || DrawThingsClient.isLikelyFluxKleinDistilled($0)
                    || DrawThingsClient.isLikelySD15Model($0)
            }) {
                seamHealModelOverride = preferred
            }
        } else if !found.contains(seamHealModelOverride) {
            seamHealModelOverride = ""
        }
    }

    public func healCurrentPanoramaSeam(onSuccess: @escaping @MainActor () -> Void = {}) {
        guard let currentPano = panorama, !isRunning, !isHealingSeam, !isGeneratingWithDrawThings else { return }
        guard seamHealEngine != .manualShift180 else { return }

        seamHealError = nil
        isHealingSeam = true
        seamHealProgress = 0.05
        seamHealStatusText = "Shifting panorama 180° & preparing centered 1:1 seam crop..."

        // Smart retry: if retrying right after a heal, always start from the un-healed original
        // so tweaking Strength or Prompt never compounds artifacts on top of a previous attempt.
        let sourcePano = previousPanoramaBeforeSeamHeal ?? currentPano
        let originalURL = sourcePano.sourceURL
        let originalImage = sourcePano.cgImage
        let cleanBase = NativeFileDialogs.sanitizedShortBaseName(from: sourcePano.baseName)
        let engine = seamHealEngine
        let port = drawThingsPort
        let stripWidth = seamHealStripWidth
        let chosenModel = seamHealModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOverride: String? = chosenModel.isEmpty ? nil : chosenModel
        let activeOrSelectedModel = modelOverride ?? drawThingsStatus.snapshot?.model ?? ""
        let isSDXLModel = DrawThingsClient.isLikelySDXLModel(activeOrSelectedModel)
        let isSD15Model = DrawThingsClient.isLikelySD15Model(activeOrSelectedModel)
        let isFluxKleinDistilled = DrawThingsClient.isLikelyFluxKleinDistilled(activeOrSelectedModel)
        let isQwenTurbo = DrawThingsClient.isLikelyQwenTurbo(activeOrSelectedModel)
        let squareCropSize: Int = {
            switch seamHealSizePreset {
            case .size1024x512: return 512
            case .size2048x1024: return 1024
            case .size1536x768, .useActive: return 768
            }
        }()
        let strength = seamHealStrength
        let seed = drawThingsSeed
        // Auto-apply architecture-safe sampling defaults so distilled models never get CFG 3.5 NaN-black explosions
        // and SDXL / SD 1.5 models always use clean Karras + Shift 1.0 settings.
        let steps: Int?
        let shift: Double?
        let resShift: Bool?
        let cfg: Double?
        let sampler: DrawThingsSamplerOption
        if isSDXLModel {
            steps = 20
            shift = 1.0
            resShift = false
            cfg = 5.5
            sampler = .dpmpp2MKarras
        } else if isFluxKleinDistilled {
            steps = 4
            shift = 3.0
            resShift = true
            cfg = 1.0
            sampler = .eulerATrailing
        } else if isQwenTurbo {
            steps = 8
            shift = 3.0
            resShift = true
            cfg = 1.0
            sampler = .eulerATrailing
        } else if isSD15Model {
            steps = 24
            shift = 1.0
            resShift = false
            cfg = 7.0
            sampler = .dpmpp2MKarras
        } else {
            // Defer to Draw Things' own active model settings rather than risking stale cached CFG/steps
            steps = nil
            shift = nil
            resShift = nil
            cfg = nil
            sampler = .keepActive
        }
        let disableLoRAs = seamHealDisableLoRAs
        let trimmedSeamPrompt = seamHealPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmedSeamPrompt.isEmpty ? Self.defaultGenericSeamPrompt : trimmedSeamPrompt
        let negPrompt = drawThingsNegativePrompt.isEmpty
            ? "seam, split screen, vertical line, collage, border, blurry, watermark, text"
            : "\(drawThingsNegativePrompt), split screen, vertical line, collage"
        let client = drawThingsClient
        let inpainter = holeInpainter

        seamHealTask = Task.detached(priority: .userInitiated) {
            do {
                let healedCG: CGImage
                switch engine {
                case .localLaMa:
                    await MainActor.run {
                        self.seamHealProgress = 0.15
                        self.seamHealStatusText = "Running local CoreML LaMa on 1:1 centered seam crop..."
                    }
                    healedCG = try await SeamHealerService.healWithLocalLaMa(
                        panorama: originalImage,
                        stripWidth: stripWidth,
                        inpainter: inpainter
                    ) { state in
                        Task { @MainActor in
                            switch state {
                            case .downloading(let frac, let dlMB, let totMB):
                                self.seamHealProgress = 0.15 + 0.45 * frac
                                self.seamHealStatusText = String(format: "Downloading CoreML LaMa (%.1f / %.1f MB)...", dlMB, totMB)
                            case .compiling:
                                self.seamHealProgress = 0.65
                                self.seamHealStatusText = "Compiling CoreML LaMa for Apple Silicon (one-time)..."
                            case .ready:
                                self.seamHealProgress = 0.72
                                self.seamHealStatusText = "Inpainting 180° seam strip locally with CoreML LaMa..."
                            case .notDownloaded, .failed:
                                break
                            }
                        }
                    }

                case .drawThings:
                    let prepared = try SeamHealerService.prepareCenterSquareForDrawThings(
                        panorama: originalImage,
                        squareSize: squareCropSize,
                        stripWidth: stripWidth
                    )

                    let modelLabel = modelOverride ?? "active Draw Things model"
                    await MainActor.run {
                        self.seamHealProgress = 0.12
                        self.seamHealStatusText = "Sending \(prepared.workingWidth)×\(prepared.workingHeight) seam crop to \(modelLabel)..."
                    }

                    let request = DrawThingsInpaintRequest(
                        prompt: prompt,
                        negativePrompt: negPrompt,
                        initImagePNG: prepared.initImagePNG,
                        maskPNG: prepared.maskPNG,
                        width: prepared.workingWidth,
                        height: prepared.workingHeight,
                        denoisingStrength: strength,
                        maskBlur: 8,
                        seed: seed,
                        steps: steps,
                        shift: shift,
                        resolutionDependentShift: resShift,
                        guidanceScale: cfg,
                        sampler: sampler,
                        disableLoRAs: disableLoRAs,
                        model: modelOverride
                    )

                    let inpaintedBytes = try await client.inpaintSeam(
                        host: "127.0.0.1",
                        port: port,
                        request: request
                    ) { prog in
                        Task { @MainActor in
                            self.seamHealProgress = 0.12 + 0.78 * prog.fraction
                            if let cur = prog.currentStep, let tot = prog.totalSteps, tot > 0 {
                                self.seamHealStatusText = "Draw Things healing seam: Step \(cur) / \(tot)..."
                            } else if prog.fraction > 0 {
                                self.seamHealStatusText = "Draw Things healing seam (\(Int((prog.fraction * 100).rounded()))%)..."
                            } else if prog.hasStarted {
                                self.seamHealStatusText = "Draw Things active — healing seam..."
                            }
                        }
                    }

                    try Task.checkCancellation()
                    await MainActor.run {
                        self.seamHealProgress = 0.92
                        self.seamHealStatusText = "Compositing healed seam strip & rolling back 180°..."
                    }

                    healedCG = try SeamHealerService.finalizeHealedPanorama(
                        shiftedOriginal: prepared.shiftedOriginal,
                        inpaintedImageData: inpaintedBytes,
                        stripWidth: stripWidth,
                        cropX: prepared.cropX,
                        cropWidth: prepared.cropWidth
                    )

                case .manualShift180:
                    healedCG = originalImage
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self.seamHealProgress = 0.95
                    self.seamHealStatusText = "Saving healed panorama..."
                }
                let healedPNG = try SeamHealerService.encodePNG(healedCG)

                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
                let outputDir = appSupport
                    .appendingPathComponent("PanoSplat3D", isDirectory: true)
                    .appendingPathComponent("GeneratedPanoramas", isDirectory: true)
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                let timestamp = Int(Date().timeIntervalSince1970)
                let savedURL = outputDir.appendingPathComponent("\(cleanBase)_seamfixed_\(timestamp).png")
                try healedPNG.write(to: savedURL, options: .atomic)

                let healedAsset = try PanoramaLoader.load(from: savedURL)

                await MainActor.run {
                    self.recordUndoState(actionName: "Seam Heal")
                    self.previousPanoramaURLBeforeSeamHeal = originalURL
                    self.previousPanoramaBeforeSeamHeal = sourcePano
                    self.previousPanoramaBeforeUpscale = nil
                    self.lastUpscaleSummary = nil
                    self.lastSavedUpscaledURL = nil
                    self.panorama = healedAsset
                    self.depthMap = nil
                    self.depthPreviewImage = nil
                    self.previewCloud = nil
                    self.isHealingSeam = false
                    self.seamHealProgress = 1.0
                    self.seamHealStatusText = "360° seam healed!"
                    self.stageTitle = "Ready"
                    let engineLabel = engine == .localLaMa ? "CoreML LaMa" : "Draw Things"
                    self.stageDetail = "Seam healed via \(engineLabel) (\(healedAsset.resolutionBadge))"
                    self.requestSwitchTo360ViewToken += 1
                    self.requestJumpToBackSeamToken += 1
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playSuccess()
                    }
                    onSuccess()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isHealingSeam = false
                    self.seamHealProgress = 0.0
                    self.seamHealStatusText = ""
                }
            } catch {
                await MainActor.run {
                    self.isHealingSeam = false
                    self.seamHealProgress = 0.0
                    self.seamHealError = error.localizedDescription
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playError()
                    }
                }
            }
        }
    }

    public func cancelSeamHeal() {
        seamHealTask?.cancel()
        seamHealTask = nil
    }

    public func undoSeamHeal() {
        guard !isRunning, !isHealingSeam else { return }
        if let originalAsset = previousPanoramaBeforeSeamHeal {
            recordUndoState(actionName: "Revert Seam Heal")
            previousPanoramaBeforeSeamHeal = nil
            previousPanoramaURLBeforeSeamHeal = nil
            panorama = originalAsset
            depthMap = nil
            depthPreviewImage = nil
            previewCloud = nil
            stageTitle = "Ready"
            stageDetail = "Reverted seam heal — restored original \(originalAsset.fileName)"
            requestSwitchTo360ViewToken += 1
            requestJumpToBackSeamToken += 1
            return
        }
        guard let prevURL = previousPanoramaURLBeforeSeamHeal else { return }
        previousPanoramaURLBeforeSeamHeal = nil
        loadPanorama(from: prevURL, switchTo360OnLoad: true)
        requestJumpToBackSeamToken += 1
    }

    // MARK: - Manual 180°-Shift Export / Clipboard Round-Trip for Draw Things Native Eraser Inpaint

    /// Exports a 180°-shifted PNG via native `NSSavePanel` so the user can drop it into Draw Things,
    /// use the native Eraser tool to inpaint only the center seam, and import it back with zero Photoshop.
    public func exportShifted180PanoramaViaDialog() {
        guard let currentPano = panorama, !isRunning, !isHealingSeam else { return }
        seamHealError = nil
        manualShiftStatusMessage = nil

        let defaultDir: URL
        if let prev = lastExportedShifted180URL {
            defaultDir = prev.deletingLastPathComponent()
        } else if settings.saveToLastUsedFolder,
                  let savedDirPath = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey),
                  FileManager.default.fileExists(atPath: savedDirPath) {
            defaultDir = URL(fileURLWithPath: savedDirPath, isDirectory: true)
        } else {
            defaultDir = currentPano.sourceURL.deletingLastPathComponent()
        }

        let shortBase = NativeFileDialogs.sanitizedShortBaseName(from: currentPano.baseName)
        guard let destURL = NativeFileDialogs.pickSaveShifted180Destination(
            defaultDirectory: defaultDir,
            defaultBaseName: shortBase
        ) else {
            return
        }

        do {
            let shifted = try SeamHealerService.shift180(currentPano.cgImage)
            let png = try SeamHealerService.encodePNG(shifted)
            try png.write(to: destURL, options: .atomic)
            lastExportedShifted180URL = destURL
            NativeFileDialogs.revealInFinder(destURL)
            manualShiftStatusMessage = "Saved & revealed \(destURL.lastPathComponent) (\(shifted.width)×\(shifted.height)) — drag it onto Draw Things' canvas, erase center seam & generate."
        } catch {
            seamHealError = error.localizedDescription
        }
    }

    /// Writes a temporary full-resolution 180°-shifted PNG (for direct drag-and-drop onto Draw Things or clipboard fileURL).
    public func prepareDraggableShifted180FileURL() -> URL? {
        guard let currentPano = panorama else { return nil }
        do {
            let shifted = try SeamHealerService.shift180(currentPano.cgImage)
            let png = try SeamHealerService.encodePNG(shifted)
            let shortBase = NativeFileDialogs.sanitizedShortBaseName(from: currentPano.baseName)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PanoSplat3D-Shifted180", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("\(shortBase)_shifted180.png")
            try png.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Copies the 180°-shifted image to the macOS clipboard with full PNG, TIFF (`NSImage`), and file-URL
    /// representations so pressing `⌘V` works in Draw Things and every macOS image editor.
    public func copyShifted180PanoramaToClipboard() {
        guard let currentPano = panorama, !isRunning, !isHealingSeam else { return }
        seamHealError = nil
        manualShiftStatusMessage = nil

        do {
            let shifted = try SeamHealerService.shift180(currentPano.cgImage)
            let png = try SeamHealerService.encodePNG(shifted)
            let nsImage = NSImage(cgImage: shifted, size: NSSize(width: shifted.width, height: shifted.height))

            // Also write a temp file so apps that paste file URLs accept ⌘V cleanly
            let shortBase = NativeFileDialogs.sanitizedShortBaseName(from: currentPano.baseName)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PanoSplat3D-Shifted180", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent("\(shortBase)_shifted180.png")
            try png.write(to: tempURL, options: .atomic)

            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff = nsImage.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            item.setString(tempURL.absoluteString, forType: .fileURL)

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([item])

            manualShiftStatusMessage = "Copied to clipboard (\(shifted.width)×\(shifted.height)) — switch to Draw Things and press ⌘V (or drag the preview above onto Draw Things' canvas)."
        } catch {
            seamHealError = error.localizedDescription
        }
    }

    /// Imports an edited 180°-shifted image saved from Draw Things, rolls it back 180° (`W - W/2`),
    /// saves it cleanly, and loads it straight into the 360° viewer pointed at the back seam.
    public func importAndRollBack180ViaDialog(onSuccess: @escaping @MainActor () -> Void = {}) {
        guard let currentPano = panorama, !isRunning, !isHealingSeam else { return }
        seamHealError = nil
        manualShiftStatusMessage = nil

        let initialDir = lastExportedShifted180URL?.deletingLastPathComponent()
            ?? currentPano.sourceURL.deletingLastPathComponent()
        guard let pickedURL = NativeFileDialogs.pickImportShifted180Panorama(initialDirectory: initialDir) else {
            return
        }

        do {
            let importedAsset = try PanoramaLoader.load(from: pickedURL)
            try applyRolledBack180Image(importedAsset.cgImage, originalPanorama: currentPano, sourceLabel: pickedURL.lastPathComponent)
            onSuccess()
        } catch {
            seamHealError = error.localizedDescription
        }
    }

    /// Reads an edited 180°-shifted image directly from the macOS clipboard (`⌘C` in Draw Things),
    /// rolls it back 180°, and loads it straight into the 360° viewer pointed at the back seam.
    public func pasteAndRollBack180FromClipboard(onSuccess: @escaping @MainActor () -> Void = {}) {
        guard let currentPano = panorama, !isRunning, !isHealingSeam else { return }
        seamHealError = nil
        manualShiftStatusMessage = nil

        let pb = NSPasteboard.general
        let cgImage: CGImage?
        if let pngData = pb.data(forType: .png),
           let src = CGImageSourceCreateWithData(pngData as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            cgImage = img
        } else if let tiffData = pb.data(forType: .tiff),
                  let src = CGImageSourceCreateWithData(tiffData as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            cgImage = img
        } else if let nsImg = NSImage(pasteboard: pb) {
            var rect = NSRect(origin: .zero, size: nsImg.size)
            cgImage = nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } else {
            cgImage = nil
        }

        guard let pastedCG = cgImage else {
            seamHealError = "No image found on the clipboard. Copy your inpainted image in Draw Things (⌘C) or use 'Import File & Roll Back 180°...'."
            return
        }

        do {
            try applyRolledBack180Image(pastedCG, originalPanorama: currentPano, sourceLabel: "clipboard")
            onSuccess()
        } catch {
            seamHealError = error.localizedDescription
        }
    }

    private func applyRolledBack180Image(
        _ shiftedInpainted: CGImage,
        originalPanorama: PanoramaAsset,
        sourceLabel: String
    ) throws {
        let restoredCG = try SeamHealerService.rollBack180(shiftedInpainted)
        let pngData = try SeamHealerService.encodePNG(restoredCG)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let outputDir = appSupport
            .appendingPathComponent("PanoSplat3D", isDirectory: true)
            .appendingPathComponent("GeneratedPanoramas", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let cleanBase = NativeFileDialogs.sanitizedShortBaseName(from: originalPanorama.baseName)
        let timestamp = Int(Date().timeIntervalSince1970)
        let savedURL = outputDir.appendingPathComponent("\(cleanBase)_seamfixed_\(timestamp).png")
        try pngData.write(to: savedURL, options: .atomic)

        let healedAsset = try PanoramaLoader.load(from: savedURL)
        recordUndoState(actionName: "Seam Heal (180° Rollback)")
        previousPanoramaURLBeforeSeamHeal = originalPanorama.sourceURL
        previousPanoramaBeforeSeamHeal = previousPanoramaBeforeSeamHeal ?? originalPanorama
        previousPanoramaBeforeUpscale = nil
        lastUpscaleSummary = nil
        lastSavedUpscaledURL = nil
        panorama = healedAsset
        depthMap = nil
        depthPreviewImage = nil
        previewCloud = nil
        stageTitle = "Ready"
        stageDetail = "Rolled back 180° from \(sourceLabel) (\(healedAsset.resolutionBadge))"
        requestSwitchTo360ViewToken += 1
        requestJumpToBackSeamToken += 1
        if settings.playAlertSounds {
            SoundAlertService.shared.playSuccess()
        }
    }

    // MARK: - 360°-Wrap-Safe CoreML AI Upscaling (Phase C)

    public func refreshSelectedUpscalerModelState() {
        let selectedVariant = settings.upscalerModel
        let manager = panoramaUpscaler.modelManager
        Task {
            let localURL = await manager.localModelURL(for: selectedVariant)
            guard self.settings.upscalerModel == selectedVariant else { return }
            if let localURL {
                self.upscalerModelState = .ready(modelURL: localURL)
            } else if !self.upscalerModelState.isBusy {
                self.upscalerModelState = .notDownloaded
            }
        }
    }

    public func upscaleCurrentPanorama(
        factor: UpscaleFactor = .x2,
        variant: UpscalerModelVariant? = nil,
        blendStrength: Double? = nil
    ) {
        guard let currentPano = panorama, !isRunning, !isRunningBatch, !isUpscalingPanorama else { return }

        // Smart A/B testing: if already upscaled, re-test from the original source panorama so
        // switching models or strength never compounds 2× on top of 2×.
        let sourceForUpscale = previousPanoramaBeforeUpscale ?? currentPano
        let chosenVariant = variant ?? settings.upscalerModel
        let chosenStrength = min(max(blendStrength ?? settings.upscalerBlendStrength, 0.0), 1.0)
        let strengthPct = Int((chosenStrength * 100).rounded())

        panoramaError = nil
        isUpscalingPanorama = true
        upscaleProgress = 0.02
        upscaleStatusText = "Preparing \(chosenVariant.displayName)..."

        let upscaler = panoramaUpscaler
        upscaleTask = Task.detached(priority: .userInitiated) {
            do {
                let upscaled = try await upscaler.upscale(
                    panorama: sourceForUpscale,
                    variant: chosenVariant,
                    factor: factor,
                    blendStrength: chosenStrength,
                    onModelStateChange: { state in
                        Task { @MainActor in
                            if self.settings.upscalerModel == chosenVariant {
                                self.upscalerModelState = state
                            }
                            switch state {
                            case .downloading(let frac, let downMB, let totMB):
                                self.upscaleProgress = 0.02 + 0.25 * frac
                                self.upscaleStatusText = String(format: "Downloading %@ (%.1f / %.1f MB)...", chosenVariant.shortBadgeName, downMB, totMB)
                            case .compiling:
                                self.upscaleProgress = 0.28
                                let target = chosenVariant.preferredComputeUnits == .cpuAndGPU ? "Metal GPU" : "Apple Silicon"
                                self.upscaleStatusText = "Compiling \(chosenVariant.shortBadgeName) for \(target)..."
                            case .ready, .notDownloaded, .failed:
                                break
                            }
                        }
                    },
                    onProgress: { frac, detail in
                        Task { @MainActor in
                            self.upscaleProgress = 0.30 + 0.70 * frac
                            self.upscaleStatusText = detail
                        }
                    }
                )

                await MainActor.run {
                    self.recordUndoState(actionName: "AI Upscale (\(chosenVariant.shortBadgeName))")
                    if self.previousPanoramaBeforeUpscale == nil {
                        self.previousPanoramaBeforeUpscale = sourceForUpscale
                    }
                    self.panorama = upscaled
                    self.depthMap = nil
                    self.depthPreviewImage = nil
                    self.isUpscalingPanorama = false
                    self.upscaleProgress = 1.0
                    let summary = "\(chosenVariant.shortBadgeName) · \(strengthPct)%"
                    self.lastUpscaleSummary = summary
                    self.lastSavedUpscaledURL = nil
                    self.upscaleStatusText = "Upscaled to \(upscaled.width) × \(upscaled.height) (\(summary))"
                    self.stageTitle = "Ready"
                    self.stageDetail = "Upscaled to \(upscaled.resolutionBadge) via \(chosenVariant.displayName) at \(strengthPct)% blend"
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playSuccess()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isUpscalingPanorama = false
                    self.upscaleProgress = 0.0
                    self.upscaleStatusText = ""
                }
            } catch {
                await MainActor.run {
                    self.isUpscalingPanorama = false
                    self.upscaleProgress = 0.0
                    self.panoramaError = error.localizedDescription
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playError()
                    }
                }
            }
        }
    }

    public func cancelUpscale() {
        upscaleTask?.cancel()
        upscaleTask = nil
    }

    /// Reverts the current upscaled panorama back to the original un-upscaled image instantly.
    public func undoUpscale() {
        guard let original = previousPanoramaBeforeUpscale, !isRunning, !isUpscalingPanorama, !isRunningBatch else { return }
        recordUndoState(actionName: "Revert AI Upscale")
        previousPanoramaBeforeUpscale = nil
        lastUpscaleSummary = nil
        lastSavedUpscaledURL = nil
        panorama = original
        depthMap = nil
        depthPreviewImage = nil
        stageTitle = "Ready"
        stageDetail = "Reverted to original \(original.fileName) (\(original.resolutionBadge))"
    }

    /// Exports the current (upscaled) 360° panorama to PNG or JPEG via a native macOS `NSSavePanel`.
    public func saveUpscaledPanoramaViaDialog() {
        guard let currentPano = panorama, !isUpscalingPanorama else { return }
        panoramaError = nil

        let defaultDir: URL
        if settings.saveToLastUsedFolder,
           let savedDirPath = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey),
           FileManager.default.fileExists(atPath: savedDirPath) {
            defaultDir = URL(fileURLWithPath: savedDirPath, isDirectory: true)
        } else {
            defaultDir = outputURL?.deletingLastPathComponent() ?? currentPano.sourceURL.deletingLastPathComponent()
        }

        let shortBase = NativeFileDialogs.sanitizedShortBaseName(from: currentPano.baseName)
        guard let destinationURL = NativeFileDialogs.pickSavePanoramaDestination(
            defaultDirectory: defaultDir,
            defaultBaseName: shortBase
        ) else {
            return
        }

        do {
            try Self.writeCGImage(currentPano.cgImage, to: destinationURL)
            lastSavedUpscaledURL = destinationURL
            stageDetail = "Saved upscaled 360° panorama: \(destinationURL.lastPathComponent) (\(currentPano.width)×\(currentPano.height))"
        } catch {
            panoramaError = "Failed to save upscaled panorama: \(error.localizedDescription)"
        }
    }

    private static func writeCGImage(_ image: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let isJPEG = (ext == "jpg" || ext == "jpeg")
        let uti = (isJPEG ? UTType.jpeg : UTType.png).identifier as CFString

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        let options: CFDictionary? = isJPEG
            ? ([kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            : nil
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else {
            throw PanoramaUpscalerError.imageConstructionFailed
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    // MARK: - Panorama Input Selection & Drag-and-Drop

    public func chooseInputPanoramaViaDialog() {
        let initialDir = panorama?.sourceURL.deletingLastPathComponent()
            ?? UserDefaults.standard.string(forKey: Self.lastInputPathKey).map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
            }
        guard let url = NativeFileDialogs.pickInputPanorama(initialDirectory: initialDir) else {
            return
        }
        loadPanorama(from: url)
    }

    /// Supported image file extensions accepted via drag-and-drop onto the app icon or Finder "Open With".
    public nonisolated static let supportedPanoramaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "exr", "tif", "tiff", "heic", "heif"
    ]

    public nonisolated static func isSupportedPanoramaURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return supportedPanoramaExtensions.contains(url.pathExtension.lowercased())
    }

    /// Handles a file dragged onto the Dock/Finder app icon or opened via Finder's "Open With → PanoSplat3D".
    public func handleExternalOpenedFile(_ url: URL) {
        guard Self.isSupportedPanoramaURL(url) else { return }
        guard !isRunning else { return }
        loadPanorama(from: url, switchTo360OnLoad: true)
    }

    /// Runs standalone CoreML 360° depth estimation (Stage 1 only) so users can inspect the 360° depth map
    /// directly inside the main or fullscreen 360° viewer without starting full Brush training.
    public func estimateDepthOnly(onComplete: @escaping @MainActor () -> Void = {}) {
        guard let panorama, !isRunning else { return }

        pipelineError = nil
        isRunning = true
        progress = 0.05
        let selectedDepthModel = settings.depthModel
        stageTitle = "Estimating 360° Depth (\(selectedDepthModel.displayName))..."
        stageDetail = "Preparing \(selectedDepthModel.displayName)..."

        let depthScale = settings.depthScaleMeters
        let depthEstimator = self.depthEstimator

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let estimated = try await depthEstimator.estimate360Depth(
                    from: panorama,
                    variant: selectedDepthModel,
                    depthScaleMeters: depthScale,
                    onModelStateChange: { state in
                        Task { @MainActor in
                            self.depthModelState = state
                            switch state {
                            case .downloading(let frac, let downloadedMB, let totalMB):
                                self.progress = 0.05 + 0.35 * frac
                                self.stageTitle = "Downloading \(selectedDepthModel.displayName)..."
                                self.stageDetail = String(format: "%.1f MB / %.1f MB", downloadedMB, totalMB)
                            case .compiling:
                                self.progress = 0.42
                                let target = selectedDepthModel.preferredComputeUnits == .cpuAndGPU ? "Metal GPU" : "Apple Neural Engine"
                                self.stageTitle = "Preparing \(selectedDepthModel.displayName)..."
                                self.stageDetail = "Compiling CoreML graph for \(target)..."
                            case .ready, .notDownloaded, .failed:
                                break
                            }
                        }
                    },
                    onProgress: { frac, detail in
                        Task { @MainActor in
                            self.progress = 0.42 + 0.55 * frac
                            self.stageTitle = "Estimating 360° Depth (\(selectedDepthModel.displayName))..."
                            self.stageDetail = detail
                        }
                    }
                )
                let preview = estimated.makeColorizedPreviewCGImage()
                await MainActor.run {
                    self.depthMap = estimated
                    self.depthPreviewImage = preview
                    self.progress = 1.0
                    self.stageTitle = "360° Depth Ready"
                    self.stageDetail = String(
                        format: "%@ • %.1fm – %.1fm (median %.1fm)",
                        selectedDepthModel.displayName,
                        estimated.minRadiusMeters,
                        estimated.maxRadiusMeters,
                        estimated.medianRadiusMeters
                    )
                    self.isRunning = false
                    self.activeTask = nil
                    onComplete()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.activeTask = nil
                    self.progress = 0
                    self.stageTitle = "Cancelled"
                    self.stageDetail = "Depth estimation was cancelled."
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.activeTask = nil
                    self.stageTitle = "Depth Estimation Failed"
                    self.pipelineError = error.localizedDescription
                    self.stageDetail = error.localizedDescription
                }
            }
        }
    }

    public func loadPanorama(from url: URL, switchTo360OnLoad: Bool = false) {
        panoramaError = nil
        pipelineError = nil
        isLoadingPanorama = true

        let standardized = url.standardizedFileURL
        Task.detached(priority: .userInitiated) {
            do {
                let asset = try PanoramaLoader.load(from: standardized)
                await MainActor.run {
                    if self.panorama != nil {
                        self.recordUndoState(actionName: "Load Panorama")
                    }
                    self.panorama = asset
                    self.previousPanoramaBeforeUpscale = nil
                    self.previousPanoramaBeforeSeamHeal = nil
                    self.previousPanoramaURLBeforeSeamHeal = nil
                    self.lastUpscaleSummary = nil
                    self.lastSavedUpscaledURL = nil
                    self.depthMap = nil
                    self.depthPreviewImage = nil
                    self.previewCloud = nil
                    self.isLoadingPanorama = false
                    self.lastExportedURL = nil
                    self.lastDatasetResult = nil
                    self.lastTrainingResult = nil
                    self.progress = 0
                    self.stageTitle = "Ready"
                    self.stageDetail = "Loaded \(asset.fileName) (\(asset.resolutionBadge))"
                    UserDefaults.standard.set(standardized.path, forKey: Self.lastInputPathKey)

                    // Update default short output name & path cleanly
                    self.hasUserEditedOutputName = false
                    let shortName = NativeFileDialogs.sanitizedShortBaseName(from: asset.baseName)
                    self.editableOutputName = shortName

                    let targetDir: URL
                    if self.settings.saveToLastUsedFolder,
                       let savedDirPath = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey),
                       FileManager.default.fileExists(atPath: savedDirPath) {
                        targetDir = URL(fileURLWithPath: savedDirPath, isDirectory: true)
                    } else if self.hasUserChosenOutputDirectory, let existing = self.outputURL {
                        targetDir = existing.deletingLastPathComponent()
                    } else {
                        targetDir = asset.sourceURL.deletingLastPathComponent()
                    }
                    self.outputURL = Self.buildOutputURL(in: targetDir, baseName: shortName, mode: self.settings.exportMode)
                    if switchTo360OnLoad {
                        self.requestSwitchTo360ViewToken += 1
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingPanorama = false
                    self.panoramaError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Output Destination Selection & Inline Renaming

    public func applyEditedOutputName(_ rawName: String) {
        let sanitized = rawName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let withoutExt: String
        if sanitized.lowercased().hasSuffix(".ply") {
            withoutExt = String(sanitized.dropLast(4))
        } else {
            withoutExt = sanitized
        }

        let finalName = withoutExt.isEmpty
            ? NativeFileDialogs.sanitizedShortBaseName(from: panorama?.baseName ?? "pano_splat")
            : withoutExt

        editableOutputName = finalName
        hasUserEditedOutputName = true

        let parentDir = outputURL?.deletingLastPathComponent()
            ?? panorama?.sourceURL.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        outputURL = Self.buildOutputURL(in: parentDir, baseName: finalName, mode: settings.exportMode)
    }

    public func chooseOutputDestinationViaDialog() {
        let currentBase = editableOutputName.isEmpty
            ? NativeFileDialogs.sanitizedShortBaseName(from: panorama?.baseName ?? "pano_splat")
            : editableOutputName
        let defaultDir = outputURL?.deletingLastPathComponent()
            ?? panorama?.sourceURL.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        guard let pickedURL = NativeFileDialogs.pickOutputDestination(
            mode: settings.exportMode,
            defaultDirectory: defaultDir,
            defaultBaseName: currentBase
        ) else {
            return
        }

        hasUserChosenOutputDirectory = true
        hasUserEditedOutputName = true
        outputURL = pickedURL.standardizedFileURL

        let chosenName = (settings.exportMode == .plySplat)
            ? pickedURL.deletingPathExtension().lastPathComponent
            : pickedURL.lastPathComponent
        editableOutputName = chosenName

        UserDefaults.standard.set(pickedURL.deletingLastPathComponent().path, forKey: Self.lastOutputDirectoryKey)
    }

    private func applyOutputFolderPreferenceChange() {
        guard let panorama else { return }
        let baseName = editableOutputName.isEmpty
            ? NativeFileDialogs.sanitizedShortBaseName(from: panorama.baseName)
            : editableOutputName
        if settings.saveToLastUsedFolder,
           let savedDirPath = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey),
           FileManager.default.fileExists(atPath: savedDirPath) {
            let dir = URL(fileURLWithPath: savedDirPath, isDirectory: true)
            outputURL = Self.buildOutputURL(in: dir, baseName: baseName, mode: settings.exportMode)
        } else if !settings.saveToLastUsedFolder {
            hasUserChosenOutputDirectory = false
            let dir = panorama.sourceURL.deletingLastPathComponent()
            outputURL = Self.buildOutputURL(in: dir, baseName: baseName, mode: settings.exportMode)
        }
    }

    // MARK: - Full 4-Stage Generation Pipeline

    public var canGenerate: Bool {
        guard !isRunning, !isRunningBatch, !isLoadingPanorama, !isUpscalingPanorama, panorama != nil else { return false }
        if settings.exportMode == .plySplat && brushEngine == nil {
            return false
        }
        return true
    }

    public var primaryActionTitle: String {
        switch settings.exportMode {
        case .plySplat:
            return "Generate 3D Splat"
        case .colmapDataset:
            return "Export COLMAP Dataset"
        }
    }

    private struct SingleRunOutput: Sendable {
        let exportedURL: URL
        let datasetResult: ColmapDatasetResult
        let trainingResult: BrushTrainingResult?
        let previewCloud: PLYPreviewCloud?
        let elapsedSeconds: Double
    }

    /// Shared 4-stage pipeline runner invoked by both single-panorama `startGeneration()` and `startBatchQueue()`.
    private nonisolated static func executeSinglePipeline(
        initialPanorama: PanoramaAsset,
        resolvedOutput: URL,
        settings currentSettings: GenerationSettings,
        brushExecURL: URL?,
        upscaler: PanoramaUpscaler,
        estimator: DepthEstimator,
        inpainter: ParallaxHoleInpainter,
        writer: ColmapDatasetWriter,
        runner: BrushTrainingRunner,
        onUpscalerModelState: @escaping @Sendable (UpscalerModelState) -> Void,
        onDepthModelState: @escaping @Sendable (DepthModelState) -> Void,
        onPanoramaUpdated: @escaping @Sendable (PanoramaAsset) -> Void,
        onDepthReady: @escaping @Sendable (EquirectangularDepthMap, CGImage?) -> Void,
        onProgress: @escaping @Sendable (Double, String, String) -> Void
    ) async throws -> SingleRunOutput {
        let pipelineStartTime = Date()
        let isFullSplatMode = (currentSettings.exportMode == .plySplat)
        let totalStageCount = isFullSplatMode ? 4 : 3

        let parentDir = resolvedOutput.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let accessed = parentDir.startAccessingSecurityScopedResource()
        defer {
            if accessed { parentDir.stopAccessingSecurityScopedResource() }
        }

        let tempDatasetDir: URL? = isFullSplatMode
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("PanoSplat3D-Work-\(UUID().uuidString)", isDirectory: true)
            : nil
        let datasetDir = tempDatasetDir ?? resolvedOutput

        defer {
            if let tempDatasetDir {
                try? FileManager.default.removeItem(at: tempDatasetDir)
            }
        }

        // Optional Pre-Stage: Auto-Upscale 2× low-resolution panoramas (< 3072px wide)
        var workingPanorama = initialPanorama
        let needsAutoUpscale = currentSettings.autoUpscaleLowRes && initialPanorama.width < 3072
        let stage1Start = needsAutoUpscale ? 0.12 : 0.01

        if needsAutoUpscale {
            let upVariant = currentSettings.upscalerModel
            let upStrength = currentSettings.upscalerBlendStrength
            let pct = Int((upStrength * 100).rounded())
            onProgress(
                0.01,
                "Upscaling 360° Panorama 2× (\(upVariant.shortBadgeName) · \(pct)%)...",
                "\(initialPanorama.width)×\(initialPanorama.height) → \(initialPanorama.width * 2)×\(initialPanorama.height * 2) (360° wrap-safe)"
            )

            workingPanorama = try await upscaler.upscale(
                panorama: initialPanorama,
                variant: upVariant,
                factor: .x2,
                blendStrength: upStrength,
                onModelStateChange: { state in
                    onUpscalerModelState(state)
                    switch state {
                    case .downloading(let frac, let downMB, let totMB):
                        onProgress(
                            0.01 + 0.05 * frac,
                            "Downloading \(upVariant.displayName)...",
                            String(format: "%.1f / %.1f MB", downMB, totMB)
                        )
                    case .compiling:
                        let target = upVariant.preferredComputeUnits == .cpuAndGPU ? "Metal GPU" : "Apple Silicon"
                        onProgress(
                            0.06,
                            "Preparing \(upVariant.displayName)...",
                            "Compiling CoreML graph for \(target)..."
                        )
                    case .ready, .notDownloaded, .failed:
                        break
                    }
                },
                onProgress: { frac, detail in
                    onProgress(
                        0.06 + 0.06 * frac,
                        "Upscaling 360° Panorama 2× (\(upVariant.shortBadgeName))...",
                        detail
                    )
                }
            )

            onPanoramaUpdated(workingPanorama)
            try Task.checkCancellation()
        }

        // Stage 1: Seamless 360° Depth Estimation (CoreML)
        let stage1Weight = isFullSplatMode ? 0.16 : 0.35
        let selectedDepthModel = currentSettings.depthModel
        let estimatedDepth = try await estimator.estimate360Depth(
            from: workingPanorama,
            variant: selectedDepthModel,
            depthScaleMeters: currentSettings.depthScaleMeters,
            onModelStateChange: { state in
                onDepthModelState(state)
                switch state {
                case .downloading(let frac, let downloadedMB, let totalMB):
                    onProgress(
                        stage1Start + (stage1Weight * 0.45) * frac,
                        "1/\(totalStageCount) Downloading \(selectedDepthModel.displayName)...",
                        String(format: "%.1f MB / %.1f MB", downloadedMB, totalMB)
                    )
                case .compiling:
                    let targetName = selectedDepthModel.preferredComputeUnits == .cpuAndGPU
                        ? "Metal GPU"
                        : "Apple Neural Engine"
                    onProgress(
                        stage1Start + stage1Weight * 0.5,
                        "1/\(totalStageCount) Preparing \(selectedDepthModel.displayName)...",
                        "Compiling CoreML graph for \(targetName)..."
                    )
                case .ready, .notDownloaded, .failed:
                    break
                }
            },
            onProgress: { frac, detail in
                onProgress(
                    stage1Start + stage1Weight * frac,
                    "1/\(totalStageCount) Estimating 360° Depth (\(selectedDepthModel.displayName))...",
                    detail
                )
            }
        )

        let previewImage = estimatedDepth.makeColorizedPreviewCGImage()
        onDepthReady(estimatedDepth, previewImage)
        try Task.checkCancellation()

        // Stage 2 & 3: Depth-Displaced Point Cloud + Multi-View Parallax Cameras & Optional LaMa Void Fill
        let datasetStart = stage1Start + stage1Weight
        let datasetSpan = isFullSplatMode ? 0.24 : (1.0 - datasetStart)

        let datasetResult = try await writer.writeDatasetAsync(
            from: workingPanorama,
            depthMap: estimatedDepth,
            to: datasetDir,
            settings: currentSettings,
            holeInpainter: inpainter,
            stagePrefixPointCloud: "2/\(totalStageCount) Building Depth-Displaced Point Cloud...",
            stagePrefixCameras: "3/\(totalStageCount) Rendering Multi-View Parallax Cameras & Occlusion Masks...",
            onProgress: { update in
                onProgress(datasetStart + datasetSpan * update.fraction, update.stageTitle, update.detail)
            }
        )

        try Task.checkCancellation()

        if isFullSplatMode, let brushExecURL {
            // Stage 4: Headless Brush 3D Gaussian Splat Training
            let trainStart = datasetStart + datasetSpan
            let trainSpan = 1.0 - trainStart
            let totalSteps = currentSettings.trainingSteps.rawValue

            onProgress(
                trainStart,
                "4/4 Training 3D Gaussian Splat (Step 0 / \(totalSteps.formatted()))...",
                "Launching Brush GPU engine on \(datasetResult.imageCount) parallax views..."
            )

            let trainingResult = try await runner.train(
                brushExecutableURL: brushExecURL,
                datasetDirectory: datasetDir,
                outputPLYURL: resolvedOutput,
                totalSteps: totalSteps,
                shDegree: currentSettings.shDegree.rawValue,
                maxResolution: currentSettings.perspectiveResolution
            ) { trainProgress in
                var parts: [String] = []
                if let splats = trainProgress.splatCount {
                    parts.append("\(splats.formatted()) splats")
                }
                if let eta = trainProgress.rateAndETA {
                    parts.append(eta)
                }
                let detail = parts.isEmpty ? "Training on Apple Silicon Metal..." : parts.joined(separator: " • ")
                onProgress(
                    trainStart + trainSpan * trainProgress.fraction,
                    "4/4 Training 3D Gaussian Splat (Step \(trainProgress.currentStep.formatted()) / \(trainProgress.totalSteps.formatted()))...",
                    detail
                )
            }

            let loadedCloud = try? PLYPreviewLoader.load(from: trainingResult.outputPLYURL)
            return SingleRunOutput(
                exportedURL: trainingResult.outputPLYURL,
                datasetResult: datasetResult,
                trainingResult: trainingResult,
                previewCloud: loadedCloud,
                elapsedSeconds: Date().timeIntervalSince(pipelineStartTime)
            )
        } else {
            let loadedCloud = try? PLYPreviewLoader.load(from: datasetResult.initPLYURL)
            return SingleRunOutput(
                exportedURL: datasetResult.datasetDirectory,
                datasetResult: datasetResult,
                trainingResult: nil,
                previewCloud: loadedCloud,
                elapsedSeconds: Date().timeIntervalSince(pipelineStartTime)
            )
        }
    }

    public func startGeneration() {
        guard let panorama else { return }
        guard !isRunning, !isRunningBatch else { return }

        // Apply any pending typed output name before starting
        if !editableOutputName.isEmpty {
            applyEditedOutputName(editableOutputName)
        }

        if settings.exportMode == .plySplat && brushEngine == nil {
            pipelineError = "Please locate Brush.app or a brush binary in the top bar before generating a .ply splat."
            return
        }

        let currentSettings = settings
        let resolvedOutput = outputURL ?? Self.buildOutputURL(
            in: panorama.sourceURL.deletingLastPathComponent(),
            baseName: NativeFileDialogs.sanitizedShortBaseName(from: panorama.baseName),
            mode: currentSettings.exportMode
        )
        outputURL = resolvedOutput

        let brushExecURL = brushEngine?.executableURL
        let estimator = depthEstimator
        let upscaler = panoramaUpscaler
        let inpainter = holeInpainter
        let writer = datasetWriter
        let runner = brushRunner
        let initialPanorama = panorama

        pipelineError = nil
        lastExportedURL = nil
        lastDatasetResult = nil
        lastTrainingResult = nil
        previewCloud = nil
        isRunning = true
        progress = 0.02

        let totalStageCount = (currentSettings.exportMode == .plySplat) ? 4 : 3
        stageTitle = "1/\(totalStageCount) Preparing \(currentSettings.depthModel.displayName)..."
        stageDetail = "Starting Apple Silicon pipeline"

        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try await Self.executeSinglePipeline(
                    initialPanorama: initialPanorama,
                    resolvedOutput: resolvedOutput,
                    settings: currentSettings,
                    brushExecURL: brushExecURL,
                    upscaler: upscaler,
                    estimator: estimator,
                    inpainter: inpainter,
                    writer: writer,
                    runner: runner,
                    onUpscalerModelState: { state in
                        Task { @MainActor in self.upscalerModelState = state }
                    },
                    onDepthModelState: { state in
                        Task { @MainActor in self.depthModelState = state }
                    },
                    onPanoramaUpdated: { updated in
                        Task { @MainActor in
                            if self.previousPanoramaBeforeUpscale == nil {
                                self.previousPanoramaBeforeUpscale = initialPanorama
                            }
                            self.panorama = updated
                        }
                    },
                    onDepthReady: { depth, preview in
                        Task { @MainActor in
                            self.depthMap = depth
                            self.depthPreviewImage = preview
                        }
                    },
                    onProgress: { frac, title, detail in
                        Task { @MainActor in
                            self.progress = frac
                            self.stageTitle = title
                            self.stageDetail = detail
                        }
                    }
                )

                await MainActor.run {
                    self.isRunning = false
                    self.progress = 1.0
                    self.lastDatasetResult = result.datasetResult
                    self.lastTrainingResult = result.trainingResult
                    self.lastExportedURL = result.exportedURL
                    self.previewCloud = result.previewCloud
                    let elapsedStr = Self.formatDuration(result.elapsedSeconds)
                    if let trainingResult = result.trainingResult {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: trainingResult.fileSizeBytes, countStyle: .file)
                        let splatStr = result.previewCloud.map { "\($0.totalVertexCount.formatted()) Gaussians" } ?? "\(trainingResult.totalSteps.formatted()) steps"
                        self.stageTitle = "3D Gaussian Splat Ready (.ply)"
                        self.stageDetail = "\(trainingResult.outputPLYURL.lastPathComponent) • \(splatStr) • \(sizeStr) • \(elapsedStr)"
                    } else {
                        self.stageTitle = "COLMAP Dataset Ready"
                        self.stageDetail = "\(result.datasetResult.imageCount) views (\(result.datasetResult.parallaxViewCount) parallax + masks) + \(result.datasetResult.pointCount.formatted()) init points • \(elapsedStr)"
                    }
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playSuccess()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.progress = 0.0
                    self.stageTitle = "Cancelled"
                    self.stageDetail = "Generation was cancelled."
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.pipelineError = error.localizedDescription
                    self.stageTitle = "Generation Failed"
                    self.stageDetail = error.localizedDescription
                    if self.settings.playAlertSounds {
                        SoundAlertService.shared.playError()
                    }
                }
            }
        }
    }

    public func cancelGeneration() {
        activeTask?.cancel()
        activeTask = nil
        if isRunningBatch {
            cancelBatchQueue()
        }
    }

    // MARK: - Overnight Batch Processing Queue

    public var batchPendingCount: Int {
        batchItems.filter(\.status.isQueued).count
    }

    public var batchCompletedCount: Int {
        batchItems.filter(\.status.isCompleted).count
    }

    public var batchFailedOrCancelledCount: Int {
        batchItems.filter(\.status.isRetryable).count
    }

    public var canStartBatch: Bool {
        guard !isRunning, !isRunningBatch, !isUpscalingPanorama, batchPendingCount > 0 else { return false }
        if settings.exportMode == .plySplat && brushEngine == nil {
            return false
        }
        return true
    }

    public func addFilesToBatchViaDialog() {
        let initialDir = batchItems.last?.sourceURL.deletingLastPathComponent()
            ?? panorama?.sourceURL.deletingLastPathComponent()
            ?? UserDefaults.standard.string(forKey: Self.lastInputPathKey).map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
            }
        let picked = NativeFileDialogs.pickMultipleInputPanoramas(initialDirectory: initialDir)
        if !picked.isEmpty {
            addURLsToBatch(picked)
        }
    }

    public func addURLsToBatch(_ urls: [URL]) {
        let existingPaths = Set(batchItems.map { $0.sourceURL.standardizedFileURL.path })
        let candidates = urls
            .map(\.standardizedFileURL)
            .filter { Self.isSupportedPanoramaURL($0) && !existingPaths.contains($0.path) }
        guard !candidates.isEmpty else { return }

        recordUndoState(actionName: "Add to Batch Queue")
        for std in candidates {
            let rawBase = std.deletingPathExtension().lastPathComponent
            let shortName = NativeFileDialogs.sanitizedShortBaseName(from: rawBase)
            batchItems.append(BatchQueueItem(sourceURL: std, baseOutputName: shortName))
        }
        if batchOutputDirectory == nil {
            if let savedDirPath = UserDefaults.standard.string(forKey: Self.lastOutputDirectoryKey),
               FileManager.default.fileExists(atPath: savedDirPath) {
                batchOutputDirectory = URL(fileURLWithPath: savedDirPath, isDirectory: true)
            } else if let currentOut = outputURL {
                batchOutputDirectory = currentOut.deletingLastPathComponent()
            } else if let first = batchItems.first {
                batchOutputDirectory = first.sourceURL.deletingLastPathComponent()
            }
        }
    }

    public func chooseBatchOutputDirectoryViaDialog() {
        let initialDir = batchOutputDirectory
            ?? outputURL?.deletingLastPathComponent()
            ?? panorama?.sourceURL.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let pickedDir = NativeFileDialogs.pickBatchOutputDirectory(initialDirectory: initialDir) else {
            return
        }
        batchOutputDirectory = pickedDir
        if settings.saveToLastUsedFolder {
            UserDefaults.standard.set(pickedDir.path, forKey: Self.lastOutputDirectoryKey)
        }
    }

    public func removeBatchItem(id: UUID) {
        guard !isRunningBatch, batchItems.contains(where: { $0.id == id }) else { return }
        recordUndoState(actionName: "Remove Batch Item")
        batchItems.removeAll { $0.id == id }
    }

    public func clearCompletedBatchItems() {
        guard batchItems.contains(where: { $0.status.isCompleted }) else { return }
        recordUndoState(actionName: "Clear Completed Batch Items")
        batchItems.removeAll { $0.status.isCompleted }
    }

    public func clearBatchQueue() {
        guard !isRunningBatch, !batchItems.isEmpty else { return }
        recordUndoState(actionName: "Clear Batch Queue")
        batchItems.removeAll()
        batchSummaryText = ""
    }

    public func retryFailedBatchItems() {
        guard !isRunningBatch else { return }
        for i in batchItems.indices where batchItems[i].status.isRetryable {
            batchItems[i].status = .queued
        }
    }

    public func startBatchQueue() {
        guard canStartBatch else { return }

        let currentSettings = settings
        let brushExecURL = brushEngine?.executableURL
        let estimator = depthEstimator
        let upscaler = panoramaUpscaler
        let inpainter = holeInpainter
        let writer = datasetWriter
        let runner = brushRunner
        let chosenBatchDir = batchOutputDirectory

        pipelineError = nil
        isRunning = true
        isRunningBatch = true
        batchSummaryText = ""
        let batchStartTime = Date()

        // Snapshot IDs of queued items to run in order
        let queuedSnapshot: [(id: UUID, sourceURL: URL, baseName: String)] = batchItems
            .filter(\.status.isQueued)
            .map { ($0.id, $0.sourceURL, $0.baseOutputName) }
        let totalCount = queuedSnapshot.count

        batchTask = Task.detached(priority: .userInitiated) {
            var reservedOutputs: Set<URL> = []
            var succeeded = 0
            var failed = 0
            var cancelled = false

            for (idx, entry) in queuedSnapshot.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    break
                }

                let itemNumber = idx + 1
                let prefix = "[\(itemNumber)/\(totalCount)]"
                let outDir = chosenBatchDir ?? entry.sourceURL.deletingLastPathComponent()
                let resolvedOutput = BatchQueueItem.deduplicatedOutputURL(
                    in: outDir,
                    baseName: entry.baseName,
                    mode: currentSettings.exportMode,
                    reservedURLs: reservedOutputs,
                    checkFileSystem: true
                )
                reservedOutputs.insert(resolvedOutput)

                await MainActor.run {
                    self.batchActiveItemID = entry.id
                    self.updateBatchItemStatus(id: entry.id, status: .running(stage: "Loading panorama...", progress: 0.01))
                    self.progress = Double(idx) / Double(max(totalCount, 1))
                    self.stageTitle = "\(prefix) Loading \(entry.sourceURL.lastPathComponent)..."
                    self.stageDetail = "Saving to \(resolvedOutput.lastPathComponent)"
                }

                do {
                    let loadedPano = try PanoramaLoader.load(from: entry.sourceURL)
                    await MainActor.run {
                        self.panorama = loadedPano
                        self.previousPanoramaBeforeUpscale = nil
                        self.lastUpscaleSummary = nil
                        self.depthMap = nil
                        self.depthPreviewImage = nil
                        self.previewCloud = nil
                    }

                    let result = try await Self.executeSinglePipeline(
                        initialPanorama: loadedPano,
                        resolvedOutput: resolvedOutput,
                        settings: currentSettings,
                        brushExecURL: brushExecURL,
                        upscaler: upscaler,
                        estimator: estimator,
                        inpainter: inpainter,
                        writer: writer,
                        runner: runner,
                        onUpscalerModelState: { state in
                            Task { @MainActor in self.upscalerModelState = state }
                        },
                        onDepthModelState: { state in
                            Task { @MainActor in self.depthModelState = state }
                        },
                        onPanoramaUpdated: { updated in
                            Task { @MainActor in self.panorama = updated }
                        },
                        onDepthReady: { depth, preview in
                            Task { @MainActor in
                                self.depthMap = depth
                                self.depthPreviewImage = preview
                            }
                        },
                        onProgress: { frac, title, detail in
                            Task { @MainActor in
                                let overall = (Double(idx) + frac) / Double(max(totalCount, 1))
                                self.progress = overall
                                self.stageTitle = "\(prefix) \(title)"
                                self.stageDetail = "\(entry.sourceURL.lastPathComponent) • \(detail)"
                                self.updateBatchItemStatus(id: entry.id, status: .running(stage: title, progress: frac))
                            }
                        }
                    )

                    succeeded += 1
                    await MainActor.run {
                        self.lastDatasetResult = result.datasetResult
                        self.lastTrainingResult = result.trainingResult
                        self.lastExportedURL = result.exportedURL
                        self.previewCloud = result.previewCloud
                        self.updateBatchItemStatus(
                            id: entry.id,
                            status: .completed(outputURL: result.exportedURL, durationSeconds: result.elapsedSeconds)
                        )
                    }
                } catch is CancellationError {
                    cancelled = true
                    await MainActor.run {
                        self.updateBatchItemStatus(id: entry.id, status: .cancelled)
                    }
                    break
                } catch {
                    // Resilient overnight behavior: log failure on this item and continue with remaining panoramas!
                    failed += 1
                    let msg = error.localizedDescription
                    await MainActor.run {
                        self.updateBatchItemStatus(id: entry.id, status: .failed(message: msg))
                    }
                }
            }

            let totalElapsed = Self.formatDuration(Date().timeIntervalSince(batchStartTime))
            await MainActor.run {
                self.isRunning = false
                self.isRunningBatch = false
                self.batchActiveItemID = nil
                self.batchTask = nil

                if cancelled {
                    self.stageTitle = "Batch Cancelled (\(succeeded)/\(totalCount) completed)"
                    self.stageDetail = "Stopped after \(totalElapsed)."
                    self.batchSummaryText = "Cancelled — \(succeeded) completed, \(failed) failed (\(totalElapsed))"
                } else {
                    self.progress = 1.0
                    let summary = failed == 0
                        ? "Completed \(succeeded)/\(totalCount) splats in \(totalElapsed)"
                        : "Completed \(succeeded)/\(totalCount) (\(failed) failed) in \(totalElapsed)"
                    self.stageTitle = failed == 0 ? "Batch Complete (\(succeeded)/\(totalCount))" : "Batch Finished with \(failed) Error(s)"
                    self.stageDetail = summary
                    self.batchSummaryText = summary
                    if self.settings.playAlertSounds {
                        if succeeded > 0 {
                            SoundAlertService.shared.playSuccess()
                        } else {
                            SoundAlertService.shared.playError()
                        }
                    }
                }
            }
        }
    }

    public func cancelBatchQueue() {
        batchTask?.cancel()
        batchTask = nil
    }

    private func updateBatchItemStatus(id: UUID, status: BatchItemStatus) {
        if let idx = batchItems.firstIndex(where: { $0.id == id }) {
            batchItems[idx].status = status
        }
    }

    public func revealLastOutputInFinder() {
        guard let url = lastExportedURL else { return }
        NativeFileDialogs.revealInFinder(url)
    }

    // MARK: - Helpers

    private func syncOutputURLForCurrentMode() {
        let baseName: String
        if hasUserEditedOutputName && !editableOutputName.isEmpty {
            baseName = editableOutputName
        } else if let panorama {
            baseName = NativeFileDialogs.sanitizedShortBaseName(from: panorama.baseName)
            editableOutputName = baseName
        } else {
            baseName = editableOutputName.isEmpty ? "pano_splat" : editableOutputName
        }

        let parentDir = outputURL?.deletingLastPathComponent()
            ?? panorama?.sourceURL.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        outputURL = Self.buildOutputURL(in: parentDir, baseName: baseName, mode: settings.exportMode)
    }

    private static func buildOutputURL(in directory: URL, baseName: String, mode: ExportMode) -> URL {
        let cleanBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = cleanBase.isEmpty ? "pano_splat" : cleanBase
        switch mode {
        case .plySplat:
            let fileName = safeBase.lowercased().hasSuffix(".ply") ? safeBase : "\(safeBase).ply"
            return directory.appendingPathComponent(fileName, isDirectory: false)
        case .colmapDataset:
            let folderName = safeBase.hasSuffix("_colmap") ? safeBase : "\(safeBase)_colmap"
            return directory.appendingPathComponent(folderName, isDirectory: true)
        }
    }

    private func persistSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        }
    }

    private static func loadPersistedSettings() -> GenerationSettings? {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey) else { return nil }
        return try? JSONDecoder().decode(GenerationSettings.self, from: data)
    }

    private nonisolated static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
