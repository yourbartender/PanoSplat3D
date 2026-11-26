# PanoSplat3D — Technical Specification

## 1. User Workflow (100% GUI — Single-Window macOS App)
1. **Engine Setup (Automatic or One-Click GUI Picker):**
   - Top status bar shows **Brush Engine** status.
   - Automatically detects `Brush.app` in `/Applications` or `~/Applications` and resolves `Brush.app/Contents/MacOS/brush`.
   - Clicking **"Change..."** or **"Locate Brush..."** opens a native macOS `NSOpenPanel` where the user can click `Brush.app` directly (using `treatsFilePackagesAsDirectories = false` and inspecting `Bundle(url:)?.executableURL` automatically).
2. **Input Selection (Drag & Drop or GUI File Picker):**
   - Main drop zone accepts any 2:1 equirectangular `.png`, `.jpg`, or `.exr` panorama via drag-and-drop OR clicking **"Choose 360° Image..."** (`NSOpenPanel`).
   - Displays a thumbnail preview, resolution badge, and 2:1 aspect-ratio validation.
3. **Output Destination (Native Save Dialog / Folder Picker):**
   - Destination row displays the chosen output path with a **"Choose Output..."** button (`NSSavePanel` for `.ply` export, or `NSOpenPanel` for COLMAP folder export), defaulting to the same folder as the input image (`<input_name>.ply`).
4. **Configure Parameters (Clean Sliders & Presets):**
   - **Depth Scale / Room Radius:** Slider `2.0m – 50.0m` (default `12.0m`).
   - **Parallax Baseline (Camera Offset Radius):** Slider `0.0m – 2.0m` (default `0.75m`).
   - **Training Steps:** Segmented control (`5,000` Fast / `8,000` Balanced / `15,000` High; default `8,000`).
   - **Spherical Harmonics Degree:** Segmented control `1`, `2`, or `3` (default `2`).
   - **Export Mode:** Toggle between **Export `.ply` Splat** (runs Brush silently in background) and **Export COLMAP Dataset Only** (writes folder for manual inspection).
5. **One-Click Generation & Completion:**
   - User clicks **Generate 3D Splat**.
   - Live progress bar and status label update across 4 stages:
     - `1/4 Estimating 360° Depth (CoreML)...`
     - `2/4 Building Depth-Displaced Point Cloud...`
     - `3/4 Rendering Multi-View Parallax Cameras & Occlusion Masks...`
     - `4/4 Training 3D Gaussian Splat (Step X / Y)...`
   - When finished, displays a **"Reveal in Finder"** button (`NSWorkspace.shared.activateFileViewerSelecting(...)`) and an interactive 3D preview.

---

## 2. Core Algorithms & Data Formats

### A. Seamless 360° Depth Estimation (CoreML)
- Slice the 2:1 equirectangular panorama into 6 overlapping `95°` FOV perspective faces (`front, right, back, left, up, down`) so poles and wrap-around seams do not distort monocular depth inference.
- Run `DepthAnythingV2SmallF16.mlpackage` (`MLComputeUnits.all`) on each face, align scale/shift across overlapping borders via least-squares edge matching, and blend back into a seamless equirectangular depth buffer `D(u, v)`.
- Convert relative disparity `D(u, v)` into bounded metric radius `R(u, v)` clamped to `[1.5m, 60.0m]`.

### B. Depth-Displaced 3D Point Cloud (`init.ply`)
- Sample ~`150,000` points across the panorama (importance-sampled by image gradient so edges like tree trunks and architectural silhouettes get dense points while uniform sky gets sparse points).
- Compute 3D world positions using `R(u, v)` in `+Y Up` right-handed coordinates so foreground subjects sit closer to the origin and distant elements sit further away.
- Write `init.ply` with `x, y, z, red, green, blue` properties.

### C. Multi-Position Re-Projection + Disocclusion Masks (True 3D Parallax)
- Place virtual cameras at **multiple 3D positions** to provide true stereo parallax:
  - Center origin `(0, 0, 0)`: 12 views (`0°`, `+40°`, `-40°` pitch rings).
  - Offset ring at radius `baseline` (`0.75m`): 16 views distributed around a horizontal circle + vertical offset (`±0.25m`), looking outward.
- Project the depth-displaced 3D surface into each virtual camera via a Metal Z-buffer render pass.
- **Disocclusion Masking (`masks/view_XXX.png`):** Write **black (`0`)** where no valid surface projects (disoccluded holes behind foreground objects) and **white (`255`)** where valid pixels project. Brush natively reads `masks/` and ignores black pixels during training loss so holes do not smear black artifacts.

### D. Temporary Dataset & Background Brush Execution
- Write the intermediate COLMAP dataset to `FileManager.default.temporaryDirectory` (or the user's chosen folder if **Export COLMAP Dataset Only** is selected):
  ```text
  dataset/
  ├── init.ply
  ├── images/
  │   └── view_000.png ... view_027.png
  ├── masks/
  │   └── view_000.png ... view_027.png
  └── sparse/
      └── 0/
          ├── cameras.txt    # SIMPLE_PINHOLE
          ├── images.txt     # Camera quaternions + 3D translation vectors (tx, ty, tz)
          └── points3D.txt   # Empty (Brush loads init.ply)
