import SwiftUI
import UniformTypeIdentifiers

public struct PanoramaDropZoneView: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case equirect2to1 = "2:1 Equirect"
        case viewer360 = "360° Viewer"
        case splat3D = "3D Splat"
        var id: String { rawValue }
    }

    private enum ImageLayer: String, CaseIterable, Identifiable {
        case rgb = "RGB"
        case depth = "Depth"
        var id: String { rawValue }
    }

    @Bindable var coordinator: PipelineCoordinator
    @State private var isDropTargeted = false
    @State private var viewMode: ViewMode = .equirect2to1
    @State private var imageLayer: ImageLayer = .rgb
    @State private var resetCameraToken: Int = 0
    @State private var isShowingDrawThingsSheet: Bool = false
    @State private var isShowingSeamHealSheet: Bool = false
    @State private var isShowingUpscalerPopover: Bool = false
    @State private var showingPreUpscaleOriginal: Bool = false
    @State private var showingPreSeamOriginal: Bool = false

    // Interactive 360° viewer state
    @State private var viewer360TargetYaw: Double = 0
    @State private var viewer360TargetPitch: Double = 0
    @State private var viewer360PresetToken: Int = 0
    @State private var showSeamGuide: Bool = false
    @State private var currentYawDegrees: Double = 0
    @State private var currentPitchDegrees: Double = 0
    @State private var currentFovDegrees: Double = 75

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    private var availableViewModes: [ViewMode] {
        guard coordinator.panorama != nil else { return [] }
        var modes: [ViewMode] = [.equirect2to1, .viewer360]
        if coordinator.previewCloud != nil {
            modes.append(.splat3D)
        }
        return modes
    }

    private var showsLayerPicker: Bool {
        coordinator.depthPreviewImage != nil && viewMode != .splat3D
    }

    private var isInteractiveViewport: Bool {
        viewMode == .viewer360 || viewMode == .splat3D
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Input 360° Panorama & Preview")
                    .font(.headline)

                Spacer()

                if availableViewModes.count > 1 {
                    Picker("", selection: $viewMode) {
                        ForEach(availableViewModes) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: CGFloat(availableViewModes.count) * 88)
                    .controlSize(.small)
                }

                if showsLayerPicker {
                    Picker("", selection: $imageLayer) {
                        ForEach(ImageLayer.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                    .controlSize(.small)
                    .help("Switch between the RGB panorama and the estimated 360° Depth map")
                }

                if coordinator.panorama != nil {
                    Button {
                        PanoramaViewerWindowController.shared.openViewer(coordinator: coordinator, enterFullScreen: false)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .controlSize(.small)
                    .help("Open 360° & Depth Viewer Window (⌘⇧F) • Press ⌘F for True Full Screen")

                    Button {
                        isShowingDrawThingsSheet = true
                    } label: {
                        Label("Draw Things...", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)

                    Button("Choose...") {
                        coordinator.chooseInputPanoramaViaDialog()
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.primary.opacity(0.14),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.25, dash: coordinator.panorama == nil ? [6, 5] : [])
                            )
                    )

                if coordinator.isLoadingPanorama {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Decoding 360° Panorama...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                } else if viewMode == .splat3D, let cloud = coordinator.previewCloud {
                    interactive3DPreview(cloud)
                } else if viewMode == .viewer360, let asset = coordinator.panorama {
                    interactive360PanoramaPreview(asset)
                } else if let asset = coordinator.panorama {
                    loadedPanoramaContent(asset)
                } else {
                    emptyDropZoneContent
                }
            }
            .frame(minHeight: isInteractiveViewport ? 235 : 165, maxHeight: isInteractiveViewport ? 275 : 190)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
            .onChange(of: coordinator.previewCloud != nil) { _, hasCloud in
                if hasCloud {
                    viewMode = .splat3D
                } else if viewMode == .splat3D {
                    viewMode = .equirect2to1
                }
            }
            .onChange(of: coordinator.depthPreviewImage == nil) { _, isNil in
                if isNil {
                    imageLayer = .rgb
                }
            }
            .onChange(of: coordinator.panorama?.sourceURL) { _, _ in
                viewer360TargetYaw = 0
                viewer360TargetPitch = 0
                viewer360PresetToken += 1
                showSeamGuide = false
                imageLayer = .rgb
                showingPreUpscaleOriginal = false
                showingPreSeamOriginal = false
            }
            .onChange(of: coordinator.isCurrentPanoramaUpscaled) { _, upscaled in
                if !upscaled {
                    showingPreUpscaleOriginal = false
                }
            }
            .onChange(of: coordinator.isCurrentPanoramaSeamHealed) { _, healed in
                if !healed {
                    showingPreSeamOriginal = false
                }
            }
            .onChange(of: coordinator.requestSwitchTo360ViewToken) { _, _ in
                if coordinator.panorama != nil {
                    viewMode = .viewer360
                    imageLayer = .rgb
                }
            }
            .onChange(of: coordinator.requestJumpToBackSeamToken) { _, _ in
                if coordinator.panorama != nil {
                    viewMode = .viewer360
                    imageLayer = .rgb
                    viewer360TargetYaw = 180
                    viewer360TargetPitch = 0
                    showSeamGuide = true
                    viewer360PresetToken += 1
                }
            }
            .sheet(isPresented: $isShowingDrawThingsSheet) {
                DrawThingsSheetView(coordinator: coordinator)
            }
            .sheet(isPresented: $isShowingSeamHealSheet) {
                SeamHealSheetView(coordinator: coordinator)
            }

            if let error = coordinator.panoramaError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func interactive360PanoramaPreview(_ asset: PanoramaAsset) -> some View {
        let baseRGBImage: CGImage = {
            if showingPreSeamOriginal, let orig = coordinator.previousPanoramaBeforeSeamHeal {
                return orig.cgImage
            }
            if showingPreUpscaleOriginal, let orig = coordinator.previousPanoramaBeforeUpscale {
                return orig.cgImage
            }
            return asset.cgImage
        }()
        let textureImage = (imageLayer == .depth ? coordinator.depthPreviewImage : nil) ?? baseRGBImage

        return ZStack {
            Panorama360View(
                image: textureImage,
                imageKey: "\(coordinator.panoramaRevision)|\(imageLayer.rawValue)|\(showingPreUpscaleOriginal)|\(showingPreSeamOriginal)",
                targetYawDegrees: viewer360TargetYaw,
                targetPitchDegrees: viewer360TargetPitch,
                cameraPresetToken: viewer360PresetToken,
                showSeamGuide: showSeamGuide
            ) { yaw, pitch, fov in
                currentYawDegrees = yaw
                currentPitchDegrees = pitch
                currentFovDegrees = fov
            }
            .id("\(coordinator.panoramaRevision)|\(showingPreUpscaleOriginal)|\(showingPreSeamOriginal)")
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(1)

            VStack {
                HStack(spacing: 6) {
                    let shownAsset = (showingPreUpscaleOriginal ? coordinator.previousPanoramaBeforeUpscale : nil) ?? asset
                    HStack(spacing: 5) {
                        Text(String(format: "Yaw %+.0f° • Pitch %+.0f° • FOV %.0f°", currentYawDegrees, currentPitchDegrees, currentFovDegrees))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                        Text("• \(shownAsset.width)×\(shownAsset.height)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(
                                coordinator.isCurrentPanoramaUpscaled
                                    ? (showingPreUpscaleOriginal ? Color.yellow : Color.cyan)
                                    : Color.white.opacity(0.75)
                            )
                        if coordinator.isCurrentPanoramaUpscaled {
                            Text(showingPreUpscaleOriginal ? "ORIG" : (coordinator.lastUpscaleSummary ?? "2×"))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(showingPreUpscaleOriginal ? Color.yellow : Color.cyan)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.60), in: Capsule())

                    Spacer()

                    if coordinator.isCurrentPanoramaSeamHealed && imageLayer == .rgb {
                        Button {
                            showingPreSeamOriginal.toggle()
                        } label: {
                            Label(
                                showingPreSeamOriginal ? "Original Seam" : "Healed Seam",
                                systemImage: "eye"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(showingPreSeamOriginal ? .yellow : .mint)
                        .help("Toggle instantly between original and healed seam to decide whether to keep or redo")

                        Button {
                            showingPreSeamOriginal = false
                            coordinator.undoSeamHeal()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(coordinator.isRunning)
                        .help("Discard seam heal and restore original panorama")
                    } else if coordinator.isCurrentPanoramaUpscaled && imageLayer == .rgb {
                        Button {
                            showingPreUpscaleOriginal.toggle()
                        } label: {
                            Label(
                                showingPreUpscaleOriginal ? "Original" : "Upscaled",
                                systemImage: "eye"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(showingPreUpscaleOriginal ? .yellow : .cyan)
                        .help("Toggle instantly between the original and AI-upscaled panorama to check sharpness & texture.")
                    }

                    Button {
                        viewer360TargetYaw = 0
                        viewer360TargetPitch = 0
                        viewer360PresetToken += 1
                    } label: {
                        Text("Front 0°")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)

                    Button {
                        viewer360TargetYaw = 180
                        viewer360TargetPitch = 0
                        showSeamGuide = true
                        viewer360PresetToken += 1
                    } label: {
                        Label("Back Seam 180°", systemImage: "scissors")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Jump to the 0°/360° wrap seam to inspect stitching quality before generating a splat")

                    Button {
                        isShowingSeamHealSheet = true
                    } label: {
                        Label(
                            coordinator.isCurrentPanoramaSeamHealed ? "Redo Heal" : "Heal Seam",
                            systemImage: "bandage"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.mint)
                    .disabled(coordinator.isRunning)
                    .help("Shift 180° and inpaint the back seam via Draw Things while keeping outer pixels bit-exact")

                    Button {
                        showSeamGuide.toggle()
                    } label: {
                        Image(systemName: showSeamGuide ? "grid.circle.fill" : "grid.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(showSeamGuide ? .orange : .white)
                    .help("Toggle 0°/360° seam & horizon overlay")

                    Button {
                        PanoramaViewerWindowController.shared.toggleFullScreen(coordinator: coordinator)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                    .help("Enter True Full Screen 360° Viewer (⌘F • Esc to exit)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(8)

                Spacer()

                HStack {
                    Text("Drag to look 360° • Scroll to zoom FOV • Check seam before training")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                }
                .padding(10)
            }
        }
    }

    private func interactive3DPreview(_ cloud: PLYPreviewCloud) -> some View {
        ZStack(alignment: .topTrailing) {
            SplatPreviewView(cloud: cloud, resetToken: resetCameraToken)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(1)

            HStack(spacing: 8) {
                Label(
                    cloud.isGaussianSplat
                        ? "\(cloud.totalVertexCount.formatted()) 3D Gaussians • SuperSplat Ready"
                        : "\(cloud.totalVertexCount.formatted()) Init Points",
                    systemImage: cloud.isGaussianSplat ? "sparkles" : "point.3.connected.trianglepath.dotted"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.65), in: Capsule())

                Button {
                    resetCameraToken += 1
                } label: {
                    Label("Reset View", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)
            }
            .padding(10)

            VStack {
                Spacer()
                HStack {
                    Text("Drag to orbit • Scroll to zoom • Right-drag to pan")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                }
                .padding(10)
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyDropZoneContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "pano.badge.play")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Drop a 2:1 Equirectangular 360° Panorama Here")
                    .font(.title3.weight(.medium))
                Text("Supports .png, .jpg, and HDR .exr panoramas")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    coordinator.chooseInputPanoramaViaDialog()
                } label: {
                    Label("Choose 360° Image...", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isShowingDrawThingsSheet = true
                } label: {
                    Label("Generate via Draw Things...", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
            }
        }
        .padding(20)
    }

    private func loadedPanoramaContent(_ asset: PanoramaAsset) -> some View {
        let displayedImage: CGImage = (imageLayer == .depth ? coordinator.depthPreviewImage : nil) ?? asset.thumbnail

        return HStack(spacing: 16) {
            Image(decorative: displayedImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(asset.fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Label(asset.resolutionBadge, systemImage: "viewfinder")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.14), in: Capsule())

                    Label(
                        asset.aspectValidation.badgeText,
                        systemImage: asset.aspectValidation.isExactEquirectangular ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(asset.aspectValidation.isExactEquirectangular ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (asset.aspectValidation.isExactEquirectangular ? Color.green : Color.orange).opacity(0.14),
                        in: Capsule()
                    )

                    if let upSummary = coordinator.lastUpscaleSummary {
                        Label(upSummary, systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.14), in: Capsule())
                    }
                }

                if let depthMap = coordinator.depthMap {
                    Label(
                        String(format: "360° Metric Depth: %.1fm – %.1fm (median %.1fm)", depthMap.minRadiusMeters, depthMap.maxRadiusMeters, depthMap.medianRadiusMeters),
                        systemImage: "cube.transparent"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                }

                if !asset.aspectValidation.isExactEquirectangular {
                    Text("Expected a 2:1 equirectangular panorama. Projection may appear stretched.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        viewMode = .viewer360
                    } label: {
                        Label("Inspect 360°", systemImage: "globe")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.small)

                    Button {
                        isShowingSeamHealSheet = true
                    } label: {
                        Label(
                            coordinator.isCurrentPanoramaSeamHealed ? "Redo Heal" : "Heal Seam",
                            systemImage: "bandage"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)
                    .help("Shift 180° and inpaint the 0°/360° seam locally (CoreML LaMa) or via Draw Things")

                    if !coordinator.isUpscalingPanorama {
                        let baseWidth = coordinator.previousPanoramaBeforeUpscale?.width ?? asset.width
                        if baseWidth <= 4096 {
                            Button {
                                coordinator.upscaleCurrentPanorama(factor: .x2)
                            } label: {
                                Label(
                                    coordinator.isCurrentPanoramaUpscaled ? "Re-test 2×" : "Upscale 2×",
                                    systemImage: "arrow.up.left.and.arrow.down.right.circle"
                                )
                                .font(.caption.weight(.medium))
                            }
                            .controlSize(.small)
                            .disabled(coordinator.isRunning)
                            .help("Run 1-click 360°-wrap-safe CoreML 2× upscale using \(coordinator.settings.upscalerModel.displayName) (\(Int((coordinator.settings.upscalerBlendStrength * 100).rounded()))% strength).")

                            Button {
                                isShowingUpscalerPopover.toggle()
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .disabled(coordinator.isRunning)
                            .help("Choose CoreML upscaler model & AI blend strength for 1-click testing")
                            .popover(isPresented: $isShowingUpscalerPopover, arrowEdge: .bottom) {
                                UpscalerOptionsPopoverView(coordinator: coordinator)
                            }
                        }

                        if coordinator.canUndoUpscale {
                            Button {
                                coordinator.undoUpscale()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .help("Undo upscale and restore original panorama")

                            Button {
                                coordinator.saveUpscaledPanoramaViaDialog()
                            } label: {
                                Label("Save 2×...", systemImage: "square.and.arrow.down")
                                    .font(.caption.weight(.medium))
                            }
                            .controlSize(.small)
                            .help("Export the upscaled 360° panorama as PNG or JPEG")
                        }
                    }
                }

                if coordinator.isUpscalingPanorama {
                    HStack(spacing: 8) {
                        ProgressView(value: coordinator.upscaleProgress, total: 1.0)
                            .frame(width: 140)
                        Text(coordinator.upscaleStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Cancel") {
                            coordinator.cancelUpscale()
                        }
                        .controlSize(.mini)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .padding(14)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            return false
        }

        if fileProviders.count == 1, let provider = fileProviders.first {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let nsString = item as? NSString {
                    resolvedURL = URL(string: nsString as String)
                } else {
                    resolvedURL = nil
                }

                if let fileURL = resolvedURL, fileURL.isFileURL {
                    Task { @MainActor in
                        coordinator.loadPanorama(from: fileURL)
                    }
                }
            }
            return true
        }

        // Multiple dropped files → queue all supported 360° panoramas into the Overnight Batch Queue!
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let nsString = item as? NSString {
                    resolvedURL = URL(string: nsString as String)
                } else {
                    resolvedURL = nil
                }

                if let fileURL = resolvedURL, fileURL.isFileURL {
                    Task { @MainActor in
                        coordinator.addURLsToBatch([fileURL])
                        if !coordinator.batchItems.isEmpty {
                            coordinator.isShowingBatchSheet = true
                        }
                    }
                }
            }
        }
        return true
    }
}
