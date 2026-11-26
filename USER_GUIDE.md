# PanoSplat3D — User Guide & Manual

**PanoSplat3D** is a 100% native Apple Silicon macOS application (Swift 6, SwiftUI, Metal, CoreML) that converts 2:1 equirectangular 360° panoramas (`.png`, `.jpg`, HDR `.exr`) into parallax-enabled **3D Gaussian Splatting (`.ply`)** environments ready for **SuperSplat**, **Unreal Engine 5.8**, and **Assimilate Live FX**—with zero Terminal commands and zero Python setup.

---

## 1. Getting Started

1. **Launch the App:** Double-click `PanoSplat3D.app` in Finder.
2. **Check the Top Status Bar:**
   - **Brush Engine:** Automatically detects `brush_app` in the project folder, `Brush.app` in `/Applications` or `~/Applications`, or a standalone `brush` binary. If not found, click **Locate Brush App / Binary...** and pick `Brush.app` or `brush_app` directly.
   - **Depth AI Model:** Choose between **Depth Anything V2 Small** (~50 MB, fastest), **Depth Anything V3 Base** (~233 MB, cleaner 3D geometry), or **Apple Depth Pro 1536px** (~745 MB, ultra-sharp thin branches & foliage). Each model downloads and compiles automatically for Apple Silicon on first use (or via **Download Now** in the status bar) and caches locally in `~/Library/Application Support/PanoSplat3D/Models/`.

---

## 2. Step-by-Step Workflow

### Step 1 — Load, Generate, or AI-Upscale Your 360° Panorama
- **Load a file:** Drag and drop any **2:1 equirectangular** `.png`, `.jpg`, or HDR `.exr` image onto the drop zone, **drag it directly onto the `PanoSplat3D.app` icon**, right-click any image in Finder and choose **Open With → PanoSplat3D**, or click **Choose 360° Image...** (`⌘O`).
- **Or generate via Draw Things:** Click **Generate via Draw Things...** (requires Draw Things open with *Settings → API Server → HTTP, Port 7860, Server Online*, or click **Open Draw Things** right inside the sheet). Click **Sync** to pull your active Draw Things **Model, Steps, Shift, Resolution-Dependent Shift, Guidance, Sampler, and Upscaler** automatically, use **Enhance 360°** if you want a structured 360° VP prompt, and click **Generate & Load 360°**.
- **Inspect in 360° & Fullscreen Viewer:** Switch between **`2:1 Equirect`**, **`360° Viewer`**, and **`3D Splat`** along the top of the preview card, toggle **`RGB`** vs **`Depth`**, or click the **Expand (`⤢`)** button (`⌘⇧F`) to open the dedicated **Large / Fullscreen 360° & Depth Viewer**:
  - **Drag** to look 360° × 180°; **scroll** to zoom Field of View (`35° – 110°`).
  - Click **Back Seam 180°** to jump straight to the `0° / 360°` wrap seam with an amber dashed guide line.
  - Inside the Large / Fullscreen Viewer, press **`D`** to toggle RGB / Depth (or click **Depth** to run a quick standalone 360° depth pass), **`H`** to hide/show the HUD for unobstructed fullscreen viewing, **`0`** to recenter, or drop another 360° photo directly onto the viewer.
- **360°-Wrap-Safe AI Upscaling (2×) + 1-Click A/B Testing & Save:** Choose between three CoreML upscalers via the **`Model · Strength`** popover on either the preview card or Parameters panel:
  - **RealPLKSR 2× Natural (Recommended Default, ~15 MB, MIT):** Non-GAN MSSIM super-resolution running on Metal GPU. Sharpens moss, bark, rocks, and water naturally without waxy GAN blobs.
  - **4xNomosWebPhoto (~15 MB, CC-BY-4.0):** RealPLKSR trained on Nomos-v2 real photography (`4×→2×` supersampled on ANE+GPU) for crisp organic detail.
  - **Real-ESRGAN x4+ (~34 MB, BSD-3-Clause):** Strongest edge sharpening; pair with 70–80% strength to preserve natural texture.
  - **AI Detail Strength (`50% – 100%`, default `80%`):** Blends AI output with a 360°-wrap-safe bicubic resize of the original panorama to dial back plasticity while preserving sharp edges.
  - Click **Upscale 2×** (or **Re-test 2×** after switching model/strength) to A/B test directly from the original source, toggle **Original / Upscaled** inside the `360° Viewer`, click **Undo** to revert, or click **Save 2×...** to export the upscaled panorama as PNG or JPEG. Leave **Auto-upscale 2×** checked so **Generate 3D Splat** still runs the whole pipeline under one button.
- **Overnight Batch Processing Queue (`⌘B`):** Click **Batch Queue...** in the footer (or drag multiple 360° images at once onto the drop zone / app icon) to queue 10–20+ panoramas for sequential overnight rendering using your current settings. Outputs are saved to your chosen folder with automatic collision-safe naming (`_2`, `_3`), and any failed item is logged and skipped so overnight runs never stall.

### Step 2 — Set Your Output Destination & Name
- Type a short, clean filename directly into the **Output Destination** text field (long AI-prompt filenames are automatically shortened to ≤36 characters).
- Click **Choose Folder & Name...** to pick both the destination folder and filename via macOS's native Save dialog.

### Step 3 — Choose Export Mode & Parameters
- **Export `.ply` Splat (Recommended Default):** Runs all **4 stages automatically** in one click:
  1. **1/4 Estimating 360° Depth (CoreML)** — Slices 12 wide-FOV (`105°`) horizon-anchored overlapping faces, runs the selected CoreML depth model (DA2 Small, DA3 Base, or Apple Depth Pro 1536px) on each face, aligns scale/shift across all overlaps via unbiased global-mean least-squares, blends into a seamless 360° metric depth buffer `R(u, v)` clamped to `[1.5m, 60.0m]`, and snaps silhouettes via circular-wrap RGB-guided joint bilateral filtering.
  2. **2/4 Building Depth-Displaced Point Cloud** — Importance-samples `220,000` points along image edges with flying-pixel depth-cliff suppression into `init.ply`.
  3. **3/4 Rendering Multi-View Parallax Cameras & Occlusion Masks** — Renders `20` sharp center views (`82°` FOV) plus `24` two-ring offset parallax views (`0.5×` inner ring + `1.0×` outer ring) via a Metal Z-buffer pass with grazing-angle triangle tearing and 4px-eroded black (`0`) disocclusion masks (`masks/`).
  4. **4/4 Training 3D Gaussian Splat (Brush)** — Runs Brush headlessly on Metal with live `Step X / Y`, splat count, and ETA progress, scale/opacity regularization (`--scale-loss-weight`, `--opac-loss-weight`, `--mean-noise-weight`), and exports a ready-to-import `.ply`.
- **Export COLMAP Dataset Only:** Runs stages 1–3 only and saves the intermediate folder (`images/`, `masks/`, `sparse/0/`, `init.ply`) for manual inspection or custom Brush/COLMAP runs.
  > **Note:** `init.ply` inside a COLMAP folder is a raw initialization point cloud (for Brush/MeshLab/Blender), **not** a trained 3D Gaussian Splat. To open a file in **SuperSplat** or **Unreal Engine**, always use **Export `.ply` Splat**.

### Step 4 — Generate, Preview & Reveal in Finder
- Click **Generate 3D Splat**.
- When finished, PanoSplat3D plays the completion sound (`coin.wav`; mute/unmute via the speaker icon in the footer), switches to the interactive **3D Splat** preview (drag to orbit, scroll to zoom, right-drag to pan), and displays a **Reveal in Finder** button.

---

## 3. Settings & Parameter Tuning Guide

### Depth AI Model
Choose the CoreML monocular depth network used to lift your 2:1 panorama into 3D:
- **Depth Anything V2 Small (~50 MB, `518×392`):** Fastest (~1s on Apple Neural Engine). Great for rapid drafts and clean architectural/indoor spaces.
- **Depth Anything V3 Base (~233 MB, `504×504` square, Apache-2.0):** Upgraded multi-view-aware geometry prior with noticeably cleaner foreground/background separation and fewer stretched parallax surfaces (~10–15s on Metal GPU).
- **Apple Depth Pro 1536px (~745 MB, `1536×1536` quantized):** High-resolution boundary precision that cleanly separates thin tree trunks, branches, wires, and dense foliage (~2–3 min across 8 wide `115°` faces on Metal GPU, stitches into a `1536×768` depth map).

### Depth Scale / Radius (`2.0m – 50.0m`, default `12.0m`)
Sets the **real-world physical scale** of the 3D scene around the camera (monocular depth only estimates *relative* depth, so this anchors metric distance in meters):
- **Closest foreground objects** sit at roughly `0.22 × Depth Scale` (clamped between `1.5m` and `20m`).
- **Distant background / sky** sits at roughly `3.8 × Depth Scale` (clamped at `60m`).
- Increasing this value does **not** automatically improve quality—match it to the physical space in the photo.

### Parallax Baseline (`0.0m – 2.0m`, default `0.50m`)
Controls the **virtual camera movement radius** used to render the 24 extra stereo-parallax views in two concentric rings (`0.5×` inner ring + `1.0×` outer ring, including `±0.20m` vertical shift) around the tripod center. *(This is not the horizon height.)*
- **`0.0m`:** Center views only—sharpest reproduction from the exact tripod point, minimal parallax if you translate the camera in 3D.
- **`0.30m – 0.60m` (Recommended):** Natural 3D depth separation for Virtual Production camera tracking/dollying without introducing large disocclusion holes.
- **`0.75m – 1.25m+`:** Best reserved for **wide open landscapes** with no close foreground objects (`Depth Scale ≥ 20m`). Pushing too high in tight rooms or dense forests exposes large occluded areas behind near objects and can soften edges.
- *(Safety clamp: PanoSplat3D automatically limits the effective baseline to at most `40%` of the closest surface radius so offset cameras never clip inside nearby walls or floors.)*

> Both **Depth Scale** and **Parallax Baseline** apply in **both** *Export `.ply` Splat* and *Export COLMAP Dataset Only* modes (they shape `init.ply`, the offset camera poses in `images.txt`, and `masks/`).

### Quick Rule of Thumb for Real 360° Photos (1.7m Tripod / Head Height)
| Scene Type | Depth Scale | Parallax Baseline |
| :--- | :---: | :---: |
| **Indoor room (1.7m tripod)** | `7m – 9m` | `0.25m – 0.40m` |
| **Outdoor street / forest / courtyard** | `10m – 15m` | `0.40m – 0.65m` |
| **Wide open vista (no close objects)** | `20m – 30m` | `0.75m – 1.25m` |

*(You can apply any of these presets in one click inside the collapsible **Tips & Parameter Guide** in the app.)*

### View Resolution (`768` / `1024` / `1280` / `1536`)
Controls the square pixel resolution of the 44 sliced training views **and** Brush's `--max-resolution`—this is the main lever for trading training speed against detail on high-resolution (e.g. `5952 × 2976`) Insta360 photos:
- **`768 (Fast)`:** ~2.5× faster Brush training; ideal for quick depth/parallax drafts.
- **`1024`:** ~1.5× faster than `1280` with clean everyday quality.
- **`1280 (Sharp — Default)`:** Best match for 4K–6K panoramas (including `5952 × 2976` Insta360 X3 exports).
- **`1536 (Ultra)`:** Maximum detail for 72MP Insta360 / 8K DSLR panoramas (longer training time).

### Training Steps (`5,000` / `8,000` / `15,000`)
- **5,000 (Fast):** Great for quick look-dev tests and checking parallax depth.
- **8,000 (Balanced — Default):** Clean balance of detail and speed.
- **15,000 (High):** Maximum edge sharpness and fine foliage/architectural clarity.
- PanoSplat3D automatically stops Gaussian splitting at **70% of total steps** (`--growth-stop-iter`) so the final 30% of training cleanly converges and sharpens every splat.

### Spherical Harmonics (`SH 1` / `SH 2` / `SH 3`)
Controls view-dependent color, highlights, and reflections (applies in *Export `.ply` Splat* mode):
- **SH 1:** Fastest training and smallest `.ply` file size. Best for overcast/diffuse scenes or quick previews.
- **SH 2 (Recommended Default):** Captures realistic specular highlights, foliage sheen, and sky gradients without excessive file size.
- **SH 3:** Maximum view-dependent specular & metallic variation at roughly ~2× larger `.ply` file size.

---

## 4. Virtual Production Import Notes

- **Orientation:** Exported `.ply` splats use standard **COLMAP / OpenCV RDF** coordinates (`+X` right, `+Y` down, `+Z` forward, matching Brush's `comment Vertical axis: y`), so they load **upright with zero manual rotation** in:
  - **SuperSplat** (drag and drop the `.ply` directly into the browser)
  - **Unreal Engine 5.8** (Luma / XV3DGS / Jawset / Brush plugins)
  - **Assimilate Live FX**
- **Camera Source Tips:**
  - **Insta360 X3 / X4 / Ricoh Theta:** Export stitched 2:1 equirectangular JPG/PNG from **Insta360 Studio** (with Optical Flow Stitching + FlowState Leveling enabled) for the cleanest seam-free 3D splats.
  - **AI Panoramas (e.g. Draw Things):** Aim for **`3072×1536`** or higher (4K `4096×2048` ideal) and use **Back Seam 180°** in the `360° View` tab to check wrap continuity before training.

---

## 5. Rebuilding from Source (Developers)

```bash
# Run unit & Metal integration tests
swift test

# Build, bundle shaders/sounds/icon, and ad-hoc sign PanoSplat3D.app
./Scripts/build_app.sh
```
