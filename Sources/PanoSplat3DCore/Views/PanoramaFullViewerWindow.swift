import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native AppKit `NSWindow` controller for the dedicated 360° Panorama & Depth Viewer.
/// Owning the `NSWindow` directly guarantees true edge-to-edge macOS Full Screen (`collectionBehavior = .fullScreenPrimary`),
/// reliable `⌘F` / `Esc` fullscreen toggling that never affects the main control window, and zero stale state across close/reopen.
@MainActor
@Observable
public final class PanoramaViewerWindowController: NSObject, NSWindowDelegate {
    public static let shared = PanoramaViewerWindowController()

    public private(set) var isFullScreen: Bool = false
    private var viewerWindow: NSWindow?
    private weak var boundCoordinator: PipelineCoordinator?
    private var keyMonitor: Any?

    private override init() {
        super.init()
    }

    /// Installs a lightweight local key monitor so `⌘F` toggles true fullscreen exclusively on the
    /// 360° viewer window (unless typing in a text field) and `Esc` always exits fullscreen.
    public func installKeyMonitor(coordinator: PipelineCoordinator) {
        self.boundCoordinator = coordinator
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Esc (keyCode 53) exits true fullscreen on the 360° viewer window immediately
            if event.keyCode == 53,
               let win = self.viewerWindow,
               win.styleMask.contains(.fullScreen) {
                win.toggleFullScreen(nil)
                return nil
            }

            // ⌘F toggles true fullscreen exclusively on the 360° viewer window (never the main UI)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f",
               let coord = self.boundCoordinator,
               coord.panorama != nil {
                // Allow normal Cmd+F if the user is actively editing text inside a TextField / TextEditor
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    return event
                }
                self.toggleFullScreen(coordinator: coord)
                return nil
            }

            return event
        }
    }

    /// Opens the dedicated 360° Panorama Viewer window (optionally transitioning directly into true macOS Full Screen).
    public func openViewer(coordinator: PipelineCoordinator, enterFullScreen: Bool = false) {
        self.boundCoordinator = coordinator

        let window: NSWindow
        if let existing = viewerWindow {
            window = existing
        } else {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "360° Panorama Viewer"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.appearance = NSAppearance(named: .darkAqua)
            win.isReleasedWhenClosed = false
            win.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
            win.collectionBehavior = [.fullScreenPrimary, .managed]
            win.minSize = NSSize(width: 720, height: 460)
            win.center()
            win.delegate = self
            win.contentView = NSHostingView(rootView: PanoramaFullViewerWindow(coordinator: coordinator))
            self.viewerWindow = win
            window = win
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if enterFullScreen && !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }

    /// Toggles true edge-to-edge macOS Full Screen exclusively on the 360° Viewer window.
    public func toggleFullScreen(coordinator: PipelineCoordinator) {
        if let window = viewerWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        } else {
            openViewer(coordinator: coordinator, enterFullScreen: true)
        }
    }

    public func exitFullScreenIfNeeded() {
        guard let window = viewerWindow, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - NSWindowDelegate

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
    }

    public func windowWillClose(_ notification: Notification) {
        isFullScreen = false
        // Release the closed window cleanly so reopening always creates a fresh Metal layer & view hierarchy
        viewerWindow?.contentView = nil
        viewerWindow = nil
    }
}

/// Dedicated resizable & true edge-to-edge fullscreen 360° / 2:1 Panorama & Depth Viewer view.
/// Turns PanoSplat3D into a standalone Metal 360° image & depth viewer while staying synced with the main window.
public struct PanoramaFullViewerWindow: View {
    public static let windowID = "viewer360"

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case sphere360 = "360° Sphere"
        case flat2to1 = "2:1 Flat"
        var id: String { rawValue }
    }

    private enum LayerMode: String, CaseIterable, Identifiable {
        case rgb = "RGB"
        case depth = "Depth"
        var id: String { rawValue }
    }

    @Bindable var coordinator: PipelineCoordinator
    @State private var windowController = PanoramaViewerWindowController.shared
    @State private var displayMode: DisplayMode = .sphere360
    @State private var layerMode: LayerMode = .rgb
    @State private var targetYawDegrees: Double = 0
    @State private var targetPitchDegrees: Double = 0
    @State private var cameraPresetToken: Int = 0
    @State private var showSeamGuide: Bool = false
    @State private var currentYawDegrees: Double = 0
    @State private var currentPitchDegrees: Double = 0
    @State private var currentFovDegrees: Double = 75
    @State private var hideHUD: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isShowingSeamHealSheet: Bool = false
    @State private var showingPreUpscaleOriginal: Bool = false
    @State private var showingPreSeamOriginal: Bool = false

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            if let asset = coordinator.panorama {
                let rgbImage: CGImage = {
                    if showingPreSeamOriginal, let orig = coordinator.previousPanoramaBeforeSeamHeal {
                        return orig.cgImage
                    }
                    if showingPreUpscaleOriginal, let orig = coordinator.previousPanoramaBeforeUpscale {
                        return orig.cgImage
                    }
                    return asset.cgImage
                }()
                let activeImage: CGImage = (layerMode == .depth ? coordinator.depthPreviewImage : nil) ?? rgbImage

                if displayMode == .sphere360 {
                    Panorama360View(
                        image: activeImage,
                        imageKey: "\(coordinator.panoramaRevision)|\(layerMode.rawValue)|\(showingPreUpscaleOriginal)|\(showingPreSeamOriginal)",
                        targetYawDegrees: targetYawDegrees,
                        targetPitchDegrees: targetPitchDegrees,
                        cameraPresetToken: cameraPresetToken,
                        showSeamGuide: showSeamGuide
                    ) { yaw, pitch, fov in
                        currentYawDegrees = yaw
                        currentPitchDegrees = pitch
                        currentFovDegrees = fov
                    }
                    .id("\(coordinator.panoramaRevision)|\(showingPreUpscaleOriginal)|\(showingPreSeamOriginal)")
                    .ignoresSafeArea()
                } else {
                    Image(decorative: activeImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(hideHUD ? 0 : 18)
                }

                if !hideHUD {
                    hudOverlay(asset: asset)
                } else {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                hideHUD = false
                            } label: {
                                Label("Show Controls (H)", systemImage: "eye")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.white)
                            .padding(.top, windowController.isFullScreen ? 14 : 34)
                            .padding(.trailing, 14)
                        }
                        Spacer()
                    }
                }
            } else {
                emptyViewerPrompt
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.10))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        // Always render viewer controls in dark appearance so segmented labels & icons stay crisp white on the dark HUD backdrop even in macOS Light Mode
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: coordinator.depthPreviewImage == nil) { _, isNil in
            if isNil { layerMode = .rgb }
        }
        .onChange(of: coordinator.panorama?.sourceURL) { _, _ in
            targetYawDegrees = 0
            targetPitchDegrees = 0
            cameraPresetToken += 1
            showSeamGuide = false
            layerMode = .rgb
            showingPreUpscaleOriginal = false
            showingPreSeamOriginal = false
        }
        .onChange(of: coordinator.isCurrentPanoramaUpscaled) { _, upscaled in
            if !upscaled { showingPreUpscaleOriginal = false }
        }
        .onChange(of: coordinator.isCurrentPanoramaSeamHealed) { _, healed in
            if !healed { showingPreSeamOriginal = false }
        }
        .onChange(of: coordinator.requestJumpToBackSeamToken) { _, _ in
            targetYawDegrees = 180
            targetPitchDegrees = 0
            showSeamGuide = true
            cameraPresetToken += 1
            layerMode = .rgb
        }
        .sheet(isPresented: $isShowingSeamHealSheet) {
            SeamHealSheetView(coordinator: coordinator)
        }
        // Hidden keyboard shortcuts for cinema-style viewing (H toggles HUD, D toggles Depth, 0 recenters)
        .background {
            VStack {
                Button("") { hideHUD.toggle() }
                    .keyboardShortcut("h", modifiers: [])
                Button("") {
                    PanoramaViewerWindowController.shared.exitFullScreenIfNeeded()
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    if coordinator.depthPreviewImage != nil {
                        layerMode = (layerMode == .rgb) ? .depth : .rgb
                    }
                }
                .keyboardShortcut("d", modifiers: [])
                Button("") {
                    targetYawDegrees = 0
                    targetPitchDegrees = 0
                    cameraPresetToken += 1
                }
                .keyboardShortcut("0", modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func hudOverlay(asset: PanoramaAsset) -> some View {
        VStack {
            // Top Floating Toolbar (clears traffic lights cleanly when windowed, sits flush in true fullscreen)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    let displayedAsset = (showingPreUpscaleOriginal ? coordinator.previousPanoramaBeforeUpscale : nil) ?? asset
                    Text(displayedAsset.fileName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 48, maxWidth: 190, alignment: .leading)
                    Text("• \(displayedAsset.resolutionBadge)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.80))
                        .fixedSize()
                    if coordinator.isCurrentPanoramaUpscaled {
                        if showingPreUpscaleOriginal {
                            Text("ORIGINAL")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.yellow.opacity(0.20), in: Capsule())
                                .fixedSize()
                        } else if let summary = coordinator.lastUpscaleSummary {
                            Text(summary)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.22), in: Capsule())
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.62), in: Capsule())
                .layoutPriority(0)

                if coordinator.isCurrentPanoramaSeamHealed && layerMode == .rgb {
                    HStack(spacing: 6) {
                        Button {
                            showingPreSeamOriginal.toggle()
                        } label: {
                            Label(showingPreSeamOriginal ? "Show Healed" : "Compare Original", systemImage: "eye")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(showingPreSeamOriginal ? .yellow : .mint)
                        .help("Flip between original and healed seam in fullscreen")

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
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                } else if coordinator.isCurrentPanoramaUpscaled && layerMode == .rgb {
                    Button {
                        showingPreUpscaleOriginal.toggle()
                    } label: {
                        Label(showingPreUpscaleOriginal ? "Show Upscaled" : "Compare Original", systemImage: "eye")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(showingPreUpscaleOriginal ? .yellow : .cyan)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .help("Instantly flip between Original and AI-Upscaled panorama in fullscreen")
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Picker("", selection: $displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 176)
                    .controlSize(.small)

                    if coordinator.depthPreviewImage != nil {
                        Picker("", selection: $layerMode) {
                            ForEach(LayerMode.allCases) { layer in
                                Text(layer.rawValue).tag(layer)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 112)
                        .controlSize(.small)
                        .help("Toggle between RGB image and 360° Depth map (shortcut: D)")
                    } else {
                        Button {
                            coordinator.estimateDepthOnly {
                                layerMode = .depth
                            }
                        } label: {
                            if coordinator.isRunning {
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("\(Int((coordinator.progress * 100).rounded()))%")
                                        .font(.caption.monospacedDigit())
                                }
                            } else {
                                Label("Depth", systemImage: "cube.transparent")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.purple)
                        .disabled(coordinator.isRunning)
                        .help("Estimate a 360° depth map with the selected Depth AI model so you can inspect Depth in fullscreen")
                    }

                    if displayMode == .sphere360 {
                        Button("0°") {
                            targetYawDegrees = 0
                            targetPitchDegrees = 0
                            cameraPresetToken += 1
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white)
                        .help("Center Front 0° (shortcut: 0)")

                        Button {
                            targetYawDegrees = 180
                            targetPitchDegrees = 0
                            showSeamGuide = true
                            cameraPresetToken += 1
                        } label: {
                            Label("Seam", systemImage: "scissors")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                        .help("Jump to 180° wrap seam")

                        Button {
                            isShowingSeamHealSheet = true
                        } label: {
                            Label("Heal", systemImage: "bandage")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.mint)
                        .disabled(coordinator.isRunning)
                        .help("Shift 180° and inpaint the wrap seam via Draw Things")

                        Button {
                            showSeamGuide.toggle()
                        } label: {
                            Image(systemName: showSeamGuide ? "grid.circle.fill" : "grid.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(showSeamGuide ? .orange : .white)
                        .help("Toggle seam & horizon guide")
                    }

                    Button {
                        coordinator.chooseInputPanoramaViaDialog()
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                    .disabled(coordinator.isRunning)
                    .help("Open another 360° panorama")

                    Button {
                        hideHUD = true
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                    .help("Hide controls for unobstructed viewing (shortcut: H)")

                    Button {
                        PanoramaViewerWindowController.shared.toggleFullScreen(coordinator: coordinator)
                    } label: {
                        Image(
                            systemName: windowController.isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                    .help(windowController.isFullScreen ? "Exit Full Screen (⌘F or Esc)" : "Enter True Full Screen (⌘F)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
            }
            .padding(.top, windowController.isFullScreen ? 14 : 34)
            .padding(.horizontal, 14)

            Spacer()

            // Bottom Floating Telemetry Pill
            HStack(spacing: 10) {
                if displayMode == .sphere360 {
                    Text(String(format: "Yaw %+.0f° • Pitch %+.0f° • FOV %.0f°", currentYawDegrees, currentPitchDegrees, currentFovDegrees))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.60), in: Capsule())
                }

                if layerMode == .depth, let depth = coordinator.depthMap {
                    Text(String(format: "Depth: %.1fm – %.1fm (median %.1fm)", depth.minRadiusMeters, depth.maxRadiusMeters, depth.medianRadiusMeters))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.65), in: Capsule())
                }

                Spacer()

                Text("Drag to look 360° • Scroll to zoom • ⌘F Full Screen • Esc Exit • H Hide HUD")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .padding(14)
        }
    }

    private var emptyViewerPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text("Drop a 360° Equirectangular Image Here")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
            Button {
                coordinator.chooseInputPanoramaViaDialog()
            } label: {
                Label("Choose 360° Image...", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
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
}
