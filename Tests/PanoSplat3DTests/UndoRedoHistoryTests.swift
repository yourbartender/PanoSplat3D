import Foundation
import Testing
@testable import PanoSplat3DCore

@Suite("Standard macOS Edit Menu Undo / Redo History Stack")
struct UndoRedoHistoryTests {
    @Test("Multi-step undo and redo preserve exact state transitions and action names")
    func multiStepUndoRedoRoundTrip() {
        var stack = UndoRedoStack<String>(maxEntries: 5)
        var current = "original.png"

        #expect(!stack.canUndo)
        #expect(!stack.canRedo)

        // Edit 1: Seam Heal
        stack.recordBeforeChange(actionName: "Seam Heal", state: current)
        current = "seam_healed.png"
        #expect(stack.canUndo)
        #expect(stack.undoActionName == "Seam Heal")
        #expect(!stack.canRedo)

        // Edit 2: AI Upscale
        stack.recordBeforeChange(actionName: "AI Upscale", state: current)
        current = "seam_healed_2x.png"
        #expect(stack.undoActionName == "AI Upscale")

        // Undo 1 -> back to seam_healed.png
        let u1 = stack.undo(currentState: current)
        #expect(u1?.actionName == "AI Upscale")
        #expect(u1?.state == "seam_healed.png")
        current = u1!.state
        #expect(stack.canRedo)
        #expect(stack.redoActionName == "AI Upscale")
        #expect(stack.undoActionName == "Seam Heal")

        // Undo 2 -> back to original.png
        let u2 = stack.undo(currentState: current)
        #expect(u2?.actionName == "Seam Heal")
        #expect(u2?.state == "original.png")
        current = u2!.state
        #expect(!stack.canUndo)
        #expect(stack.redoActionName == "Seam Heal")

        // Redo 1 -> forward to seam_healed.png
        let r1 = stack.redo(currentState: current)
        #expect(r1?.actionName == "Seam Heal")
        #expect(r1?.state == "seam_healed.png")
        current = r1!.state
        #expect(stack.redoActionName == "AI Upscale")

        // New edit clears stale redo branch
        stack.recordBeforeChange(actionName: "Scene Preset", state: current)
        current = "seam_healed_preset.png"
        #expect(!stack.canRedo)
        #expect(stack.undoActionName == "Scene Preset")
    }

    @Test("UndoRedoStack enforces maxEntries cap to bound memory for large 360° images")
    func boundedCapacityEvictsOldest() {
        var stack = UndoRedoStack<Int>(maxEntries: 3)
        for i in 1...5 {
            stack.recordBeforeChange(actionName: "Step \(i)", state: i)
        }
        #expect(stack.undoStack.count == 3)
        #expect(stack.undoStack.first?.state == 3)
        #expect(stack.undoStack.last?.state == 5)
    }
}
