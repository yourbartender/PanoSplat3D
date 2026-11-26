import SwiftUI

/// Native sheet for 1-click 180°-shifted 360° seam healing using either:
/// 1. **Fast Local (CoreML LaMa ~2s):** Runs natively on Apple Silicon on a 1:1 centered crop (zero Draw Things needed).
/// 2. **Draw Things Inpaint:** Sends the 180°-shifted strip to Draw Things `/sdapi/v1/img2img` with automatic LoRA bypass.
public struct SeamHealSheetView: View {
    @Bindable var coordinator: PipelineCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var previewImage: CGImage?

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    Label("Heal 360° Back Seam (180° Shift)", systemImage: "bandage")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(coordinator.isHealingSeam)
                }

                // Engine Selector (Fast Local CoreML LaMa vs Draw Things Inpaint)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $coordinator.seamHealEngine) {
                        ForEach(SeamHealEngine.allCases) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(coordinator.isHealingSeam)

                    Text(engineSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Draw Things Connection Bar (only shown in Draw Things API mode)
                if coordinator.seamHealEngine == .drawThings {
                    HStack(spacing: 10) {
                        statusBadge
                        Spacer()
                        if !coordinator.drawThingsStatus.isOnline && DrawThingsClient.installedDrawThingsAppURL() != nil {
                            Button("Open Draw Things") {
                                coordinator.launchDrawThingsAndCheck()
                            }
                            .controlSize(.small)
                            .disabled(coordinator.isHealingSeam)
                        }
                        Button("Sync") {
                            coordinator.checkDrawThingsServer(applySyncedSettings: true)
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isHealingSeam)
                        .help("Sync active Model, Steps, Shift, Guidance, and Sampler from Draw Things")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                // Shifted 180° Seam Preview with Orange Mask Band
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("180°-Shifted Seam Preview (Orange Band = Healed Zone)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Outer ~\(Int(((1.0 - coordinator.seamHealStripWidth.coreWidthFraction - coordinator.seamHealStripWidth.featherFraction * 2) * 100).rounded()))% stays bit-exact")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let previewImage {
                        Image(decorative: previewImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(2.0, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                            .onDrag {
                                if let fileURL = coordinator.prepareDraggableShifted180FileURL() {
                                    return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
                                }
                                return NSItemProvider()
                            }
                            .help("Drag this 180°-shifted panorama directly onto Draw Things' canvas!")
                    }

                    if coordinator.seamHealEngine == .manualShift180 {
                        Text("Tip: Drag the preview image above directly onto Draw Things' canvas, or use Copy / Save below.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Controls
                if coordinator.seamHealEngine == .manualShift180 {
                    manualShift180Card
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        // Seam Strip Width (shared by API & Local LaMa engines)
                        HStack(spacing: 10) {
                            Text("Seam Width")
                                .font(.caption.weight(.semibold))
                                .frame(width: 82, alignment: .leading)
                            Picker("", selection: $coordinator.seamHealStripWidth) {
                                ForEach(SeamStripWidth.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .disabled(coordinator.isHealingSeam)
                        }

                        if coordinator.seamHealEngine == .drawThings {
                            // Installed Draw Things Model Selector (scanned directly from Draw Things' Models folder)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("Model")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 82, alignment: .leading)

                                    Picker("", selection: $coordinator.seamHealModelOverride) {
                                        Text("Keep Draw Things Active").tag("")
                                        ForEach(coordinator.installedDrawThingsModels, id: \.self) { modelFile in
                                            Text(modelFile).tag(modelFile)
                                        }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .disabled(coordinator.isHealingSeam)

                                    Button {
                                        coordinator.refreshInstalledDrawThingsModels()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption)
                                    }
                                    .controlSize(.small)
                                    .disabled(coordinator.isHealingSeam)
                                    .help("Rescan Draw Things' Models folder for newly downloaded checkpoints")
                                }

                                if let presetHint = selectedModelPresetHint {
                                    Text(presetHint)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 90)
                                }
                            }

                            // Inpaint Denoise Strength
                            HStack(spacing: 10) {
                                Text("Strength")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 82, alignment: .leading)
                                Slider(value: $coordinator.seamHealStrength, in: 0.20...0.90, step: 0.02)
                                    .disabled(coordinator.isHealingSeam)
                                Text(String(format: "%.0f%%", coordinator.seamHealStrength * 100))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .help("35–48% keeps walls, logs & horizon tightly locked (prevents hallucinated pillars/objects). 55–68% bridges larger lighting splits.")

                            // Working 1:1 Center Crop Resolution & Seed
                            HStack(spacing: 14) {
                                HStack(spacing: 8) {
                                    Text("Crop Size")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 82, alignment: .leading)
                                    Picker("", selection: $coordinator.seamHealSizePreset) {
                                        Text("768 × 768 (Fast ~8s)").tag(DrawThingsSizePreset.size1536x768)
                                        Text("512 × 512 (Ultra-Fast)").tag(DrawThingsSizePreset.size1024x512)
                                        Text("1024 × 1024 (High)").tag(DrawThingsSizePreset.size2048x1024)
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .disabled(coordinator.isHealingSeam)
                                }

                                HStack(spacing: 6) {
                                    Text("Seed")
                                        .font(.caption.weight(.semibold))
                                    TextField("-1", value: $coordinator.drawThingsSeed, format: .number.grouping(.never))
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                        .frame(width: 78)
                                        .disabled(coordinator.isHealingSeam)
                                }
                            }

                            // Prompt guiding the seam fill
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Continuation Prompt")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Generic") {
                                        coordinator.seamHealPrompt = PipelineCoordinator.defaultGenericSeamPrompt
                                    }
                                    .controlSize(.mini)
                                    .disabled(coordinator.isHealingSeam)

                                    if !coordinator.drawThingsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Button("Use Last Gen Prompt") {
                                            coordinator.seamHealPrompt = coordinator.drawThingsPrompt
                                        }
                                        .controlSize(.mini)
                                        .disabled(coordinator.isHealingSeam)
                                    }
                                }
                                TextField(
                                    "seamless natural continuation matching surrounding scene...",
                                    text: $coordinator.seamHealPrompt
                                )
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .disabled(coordinator.isHealingSeam)
                            }

                            // Automatic LoRA bypass toggle
                            HStack(spacing: 6) {
                                Toggle(
                                    "Automatically disable LoRAs during seam inpaint (sends loras: [])",
                                    isOn: $coordinator.seamHealDisableLoRAs
                                )
                                .font(.caption)
                                .toggleStyle(.checkbox)
                                .disabled(coordinator.isHealingSeam)
                                Spacer()
                            }
                            .help("Turns off your 360° generation LoRA for this seam-inpaint call only, leaving your Draw Things UI LoRA active for normal 360° generation.")
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                if let error = coordinator.seamHealError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if coordinator.isHealingSeam {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(coordinator.seamHealStatusText)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text("\(Int((coordinator.seamHealProgress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: coordinator.seamHealProgress, total: 1.0)
                    }
                }

                Divider()

                HStack {
                    if coordinator.isHealingSeam {
                        Button("Cancel", role: .cancel) {
                            coordinator.cancelSeamHeal()
                        }
                    } else {
                        Button("Close") {
                            dismiss()
                        }
                    }

                    if coordinator.previousPanoramaURLBeforeSeamHeal != nil && !coordinator.isHealingSeam {
                        Button {
                            coordinator.undoSeamHeal()
                            refreshPreview()
                        } label: {
                            Label("Undo Last Heal", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.regular)
                    }

                    Spacer()

                    if coordinator.seamHealEngine != .manualShift180 {
                        Button {
                            coordinator.healCurrentPanoramaSeam {
                                dismiss()
                            }
                        } label: {
                            Label(
                                coordinator.seamHealEngine == .localLaMa ? "Heal Seam Locally (~2s)" : "Heal Seam via Draw Things",
                                systemImage: coordinator.seamHealEngine == .localLaMa ? "bolt.fill" : "bandage"
                            )
                            .frame(minWidth: 175)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.isHealingSeam || coordinator.panorama == nil)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 580, height: sheetHeight)
        .onAppear {
            coordinator.refreshInstalledDrawThingsModels()
            if coordinator.seamHealEngine == .drawThings {
                coordinator.checkDrawThingsServer(applySyncedSettings: !coordinator.hasSyncedDrawThingsOnce)
            }
            refreshPreview()
        }
        .onChange(of: coordinator.seamHealEngine) { _, newEngine in
            if newEngine == .drawThings {
                coordinator.refreshInstalledDrawThingsModels()
                coordinator.checkDrawThingsServer(applySyncedSettings: !coordinator.hasSyncedDrawThingsOnce)
            }
        }
        .onChange(of: coordinator.seamHealStripWidth) { _, _ in
            refreshPreview()
        }
        .onChange(of: coordinator.panoramaRevision) { _, _ in
            refreshPreview()
        }
    }

    private var selectedModelPresetHint: String? {
        let chosen = coordinator.seamHealModelOverride
        guard !chosen.isEmpty else { return nil }
        if DrawThingsClient.isLikelySDXLModel(chosen) {
            return "Auto SDXL preset (20 steps • CFG 5.5 • Shift 1.0 • DPM++ 2M Karras • Upscaler & LoRAs off). Normal UI model stays untouched."
        } else if DrawThingsClient.isLikelyFluxKleinDistilled(chosen) {
            return "Auto FLUX.2 Klein Distilled preset (4 steps • CFG 1.0 • Euler A Trailing • LoRAs off). Normal UI model stays untouched."
        } else if DrawThingsClient.isLikelyQwenTurbo(chosen) {
            return "Auto Qwen Turbo preset (8 steps • CFG 1.0 • Euler A Trailing • LoRAs off). Normal UI model stays untouched."
        } else if DrawThingsClient.isLikelySD15Model(chosen) {
            return "Auto SD 1.5 preset (24 steps • CFG 7.0 • Shift 1.0 • DPM++ 2M Karras • LoRAs off). Normal UI model stays untouched."
        }
        return "Sent per-request with LoRAs off — your normal Draw Things UI model stays untouched."
    }

    private var engineSubtitle: String {
        switch coordinator.seamHealEngine {
        case .manualShift180:
            return "Zero Photoshop needed: export or copy your 180°-shifted panorama straight into Draw Things' native Eraser Inpaint (true mask!), then paste or import it back to roll 180°."
        case .drawThings:
            return "Automated HTTP img2img pass on the pre-bridged 180°-shifted seam with automatic LoRA bypass (composites only the center strip back onto your original pixels)."
        case .localLaMa:
            return "Runs CoreML LaMa locally in ~2 seconds on a sharp 1:1 crop around the seam (offline, zero Draw Things wait). Best for uniform sky/snow seams."
        }
    }

    private var sheetHeight: CGFloat {
        switch coordinator.seamHealEngine {
        case .manualShift180: return 590
        case .localLaMa: return 470
        case .drawThings: return 700
        }
    }

    @ViewBuilder
    private var manualShift180Card: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step 1: Send 180°-shifted panorama to Draw Things
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 1 — Send 180°-Shifted Panorama to Draw Things")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 8) {
                    Button {
                        coordinator.copyShifted180PanoramaToClipboard()
                    } label: {
                        Label("Copy 180°-Shifted", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(coordinator.panorama == nil)
                    .help("Copies PNG + TIFF + file URL to the clipboard so you can switch to Draw Things and press ⌘V.")

                    Button {
                        coordinator.exportShifted180PanoramaViaDialog()
                    } label: {
                        Label("Save 180°-Shifted PNG...", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(coordinator.panorama == nil)

                    if let exportedURL = coordinator.lastExportedShifted180URL {
                        Button {
                            NativeFileDialogs.revealInFinder(exportedURL)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .controlSize(.small)
                        .help("Reveal \(exportedURL.lastPathComponent) in Finder")
                    }

                    if DrawThingsClient.installedDrawThingsAppURL() != nil {
                        Button("Open DT") {
                            coordinator.launchDrawThingsAndCheck()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            // Step 2: Quick Draw Things Eraser Inpaint checklist
            VStack(alignment: .leading, spacing: 4) {
                Text("Step 2 — Inpaint Only the Center Strip Inside Draw Things")
                    .font(.caption.weight(.semibold))
                Text("• Disable your 360° LoRA • Paint a vertical strip down the center with the Eraser tool")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• Strength 100% • Mask Blur 8–12 • Preserve Original After Inpaint ON")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• Speed tip: switch to a 4–8 step model (e.g. FLUX.2 Klein 9B Distilled / Qwen Turbo) for ~20–45s inpaint!")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Step 3: Bring the inpainted image back and roll back 180°
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 3 — Bring Inpainted Panorama Back & Roll Back 180°")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 8) {
                    Button {
                        coordinator.pasteAndRollBack180FromClipboard {
                            dismiss()
                        }
                    } label: {
                        Label("Paste & Roll Back 180°", systemImage: "clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(coordinator.panorama == nil)

                    Button {
                        coordinator.importAndRollBack180ViaDialog {
                            dismiss()
                        }
                    } label: {
                        Label("Import File & Roll Back 180°...", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                    .disabled(coordinator.panorama == nil)
                }
            }

            if let statusMsg = coordinator.manualShiftStatusMessage {
                Label(statusMsg, systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func refreshPreview() {
        guard let cgImage = (coordinator.previousPanoramaBeforeSeamHeal ?? coordinator.panorama)?.cgImage else {
            previewImage = nil
            return
        }
        let strip = coordinator.seamHealStripWidth
        Task.detached(priority: .userInitiated) {
            let preview = SeamHealerService.makeShiftedSeamPreview(panorama: cgImage, stripWidth: strip)
            await MainActor.run {
                self.previewImage = preview
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch coordinator.drawThingsStatus {
        case .online(let snap):
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Draw Things API: Online")
                        .font(.caption.weight(.semibold))
                    if let model = snap.model, !model.isEmpty {
                        let loraSuffix = snap.loras.isEmpty ? "" : " • \(snap.loras.count) LoRA\(snap.loras.count == 1 ? "" : "s") active"
                        Text("\(model)\(loraSuffix)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.14), in: Capsule())

        case .checking, .unknown:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking localhost:\(coordinator.drawThingsPort)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .offline:
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text("Draw Things API: Offline (Port \(coordinator.drawThingsPort))")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.15), in: Capsule())
        }
    }
}
