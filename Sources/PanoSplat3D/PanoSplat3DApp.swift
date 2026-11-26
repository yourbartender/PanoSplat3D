import AppKit
import PanoSplat3DCore
import SwiftUI

@main
struct PanoSplat3DApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: PipelineCoordinator

    init() {
        let shared = PipelineCoordinator()
        _coordinator = State(initialValue: shared)
        AppFileOpenRouter.shared.attach(coordinator: shared)
        PanoramaViewerWindowController.shared.installKeyMonitor(coordinator: shared)
    }

    var body: some Scene {
        Window("PanoSplat3D", id: "main") {
            ContentView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleExternalOpenedFile(url)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 840, height: 740)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(coordinator.undoMenuTitle) {
                    coordinator.performEditMenuUndo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!coordinator.canPerformEditMenuUndo)

                Button(coordinator.redoMenuTitle) {
                    coordinator.performEditMenuRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!coordinator.canPerformEditMenuRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open 360° Image...") {
                    coordinator.chooseInputPanoramaViaDialog()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(coordinator.isRunning)

                Button("Overnight Batch Queue...") {
                    coordinator.isShowingBatchSheet = true
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Open 360° Viewer Window") {
                    PanoramaViewerWindowController.shared.openViewer(coordinator: coordinator, enterFullScreen: false)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(coordinator.panorama == nil)

                Button("360° Viewer Full Screen") {
                    PanoramaViewerWindowController.shared.toggleFullScreen(coordinator: coordinator)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(coordinator.panorama == nil)
            }
        }
    }
}

/// Bridges macOS AppDelegate `application(_:open:)` events (Dock/Finder icon drag-and-drop & "Open With")
/// cleanly into the shared `PipelineCoordinator`, even when files arrive during cold app launch.
@MainActor
final class AppFileOpenRouter {
    static let shared = AppFileOpenRouter()

    private weak var coordinator: PipelineCoordinator?
    private var pendingURLs: [URL] = []

    func attach(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            dispatch(urls: urls, to: coordinator)
        }
    }

    func handleIncomingURLs(_ urls: [URL]) {
        let supported = urls.filter { PipelineCoordinator.isSupportedPanoramaURL($0) }
        guard !supported.isEmpty else { return }
        if let coordinator {
            dispatch(urls: supported, to: coordinator)
        } else {
            pendingURLs.append(contentsOf: supported)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func dispatch(urls: [URL], to coordinator: PipelineCoordinator) {
        if urls.count == 1, let single = urls.first {
            coordinator.handleExternalOpenedFile(single)
        } else {
            coordinator.addURLsToBatch(urls)
            coordinator.isShowingBatchSheet = true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppFileOpenRouter.shared.handleIncomingURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
