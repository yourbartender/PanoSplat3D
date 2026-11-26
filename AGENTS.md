# Project Rules & Engineering Standards

## Role & Architecture
You are building **PanoSplat3D**, a native macOS application (Apple Silicon / Metal) written in **Swift 6** and **SwiftUI** that converts 2:1 equirectangular 360° panoramas into parallax-enabled 3D Gaussian Splatting (`.ply`) environments for Virtual Production (Unreal Engine 5.8 / Assimilate Live FX / SuperSplat).

## Strict Technical & UX Constraints
1. **Zero Terminal / 100% Native GUI:** The end user must NEVER open Terminal, run CLI commands, type file paths, or install Python/Conda packages. Every single path (the Brush engine location, input panorama, and output `.ply` / folder destination) must be selected via native macOS **`NSOpenPanel` / `NSSavePanel`** dialogs or drag-and-drop, and persisted across launches via `UserDefaults` / security-scoped bookmarks.
2. **Automatic Brush Discovery + GUI File Picker:** On launch, automatically scan standard macOS paths (`/Applications/Brush.app/Contents/MacOS/brush`, `~/Applications/Brush.app/Contents/MacOS/brush`, `/usr/local/bin/brush`, `~/.cargo/bin/brush`) and check the app's own `Bundle.main.resourceURL`. If found, display a green status badge (`Brush Engine: Ready`). If not found, show a prominent **"Locate Brush App / Binary..."** button in the GUI that opens a native macOS file picker (`NSOpenPanel`) allowing the user to select either `Brush.app` (automatically resolving `Contents/MacOS/brush` inside the `.app` bundle) or a standalone `brush` executable.
3. **Zero Python Runtime:** Do NOT use Python, `pip`, Conda, or `py360convert` anywhere in the app bundle. All equirectangular projection, spherical depth displacement, multi-camera re-projection, and occlusion masking must run natively in **Swift + Metal / Accelerate / CoreML**.
4. **Apple Silicon Native:** Target **macOS 15+ (arm64)**. Bundle or auto-download the CoreML **Depth Anything V2** model (`DepthAnythingV2SmallF16.mlpackage`) via native `URLSession` inside the GUI (with a progress bar) so the user never has to manually download or move model files.
5. **Coordinate System Hygiene:** Enforce **+Y Up** right-handed world space (or clean COLMAP-to-Unreal orientation) so exported `.ply` files load upright without 90° Z-axis roll in SuperSplat and Unreal Engine.
6. **No Placeholders or Stubs:** Implement complete, compilable Swift and Metal shader code. Every milestone must build cleanly with `xcodebuild` or `swift build`.

## Build & Verification Workflow
- Build incrementally in 4 milestones:
  1. **Milestone 1:** SwiftUI Drag-and-Drop window + native `NSOpenPanel`/`NSSavePanel` pickers + automatic `Brush.app` bundle resolver + Metal/CPU equirectangular-to-perspective slicer + COLMAP dataset writer (`cameras.txt`, `images.txt`, `points3D.txt`, `init.ply`).
  2. **Milestone 2:** CoreML `DepthAnythingV2` integration (cubemap/overlapping perspective depth estimation stitched back into a seamless 360° metric depth map) + depth-displaced 3D `init.ply` generation.
  3. **Milestone 3:** Multi-position virtual camera rig (center + offset ring at `±0.5m` to `±1.5m` translation) re-projecting the depth-displaced surface with **disocclusion masks** (`masks/` folder where black = disoccluded hole ignored by Brush, white = valid pixels).
  4. **Milestone 4:** Background `Process` runner invoking the located `brush` executable headlessly (`--total-steps`, `--sh-degree`, `--export-path`, `--export-name`) with real-time progress parsing, SceneKit/Metal `.ply` preview, and a **"Reveal in Finder"** button upon completion.
- After implementing each milestone, compile the project and verify zero compiler errors before moving to the next milestone.
