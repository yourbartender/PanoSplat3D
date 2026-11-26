import CoreGraphics
import Foundation

/// Single entry stored on an undo or redo stack, pairing a human-readable macOS Edit menu
/// action name (e.g. `"Seam Heal"`, `"AI Upscale"`, `"Batch Queue Edit"`) with the captured state.
public struct UndoEntry<State: Sendable>: Sendable {
    public let actionName: String
    public let state: State

    public init(actionName: String, state: State) {
        self.actionName = actionName
        self.state = state
    }
}

/// Bounded multi-step Undo / Redo history stack following macOS HIG conventions.
/// Automatically evicts the oldest entries beyond `maxEntries` so large 360° panorama images never bloat RAM.
public struct UndoRedoStack<State: Sendable>: Sendable {
    public let maxEntries: Int
    public private(set) var undoStack: [UndoEntry<State>] = []
    public private(set) var redoStack: [UndoEntry<State>] = []

    public init(maxEntries: Int = 10) {
        self.maxEntries = max(1, maxEntries)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var undoActionName: String? { undoStack.last?.actionName }
    public var redoActionName: String? { redoStack.last?.actionName }

    /// Records the state *before* an edit takes place and clears any stale redo branch.
    public mutating func recordBeforeChange(actionName: String, state: State) {
        undoStack.append(UndoEntry(actionName: actionName, state: state))
        if undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }
        redoStack.removeAll()
    }

    /// Pops the most recent undo entry, pushing `currentState` onto the redo stack with the same action name.
    public mutating func undo(currentState: State) -> UndoEntry<State>? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(UndoEntry(actionName: entry.actionName, state: currentState))
        if redoStack.count > maxEntries {
            redoStack.removeFirst(redoStack.count - maxEntries)
        }
        return entry
    }

    /// Pops the most recent redo entry, pushing `currentState` back onto the undo stack with the same action name.
    public mutating func redo(currentState: State) -> UndoEntry<State>? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(UndoEntry(actionName: entry.actionName, state: currentState))
        if undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }
        return entry
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// Complete undoable document state for `PipelineCoordinator`.
public struct CoordinatorUndoSnapshot: Sendable {
    public let panorama: PanoramaAsset?
    public let previousPanoramaBeforeUpscale: PanoramaAsset?
    public let lastUpscaleSummary: String?
    public let previousPanoramaBeforeSeamHeal: PanoramaAsset?
    public let previousPanoramaURLBeforeSeamHeal: URL?
    public let depthMap: EquirectangularDepthMap?
    public let depthPreviewImage: CGImage?
    public let settings: GenerationSettings
    public let batchItems: [BatchQueueItem]
    public let editableOutputName: String
    public let outputURL: URL?

    public init(
        panorama: PanoramaAsset?,
        previousPanoramaBeforeUpscale: PanoramaAsset?,
        lastUpscaleSummary: String?,
        previousPanoramaBeforeSeamHeal: PanoramaAsset?,
        previousPanoramaURLBeforeSeamHeal: URL?,
        depthMap: EquirectangularDepthMap?,
        depthPreviewImage: CGImage?,
        settings: GenerationSettings,
        batchItems: [BatchQueueItem],
        editableOutputName: String,
        outputURL: URL?
    ) {
        self.panorama = panorama
        self.previousPanoramaBeforeUpscale = previousPanoramaBeforeUpscale
        self.lastUpscaleSummary = lastUpscaleSummary
        self.previousPanoramaBeforeSeamHeal = previousPanoramaBeforeSeamHeal
        self.previousPanoramaURLBeforeSeamHeal = previousPanoramaURLBeforeSeamHeal
        self.depthMap = depthMap
        self.depthPreviewImage = depthPreviewImage
        self.settings = settings
        self.batchItems = batchItems
        self.editableOutputName = editableOutputName
        self.outputURL = outputURL
    }
}
