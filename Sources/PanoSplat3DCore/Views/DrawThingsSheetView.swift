import SwiftUI

/// Native macOS sheet for generating 2:1 360° panoramas via Draw Things' local HTTP API (`localhost:7860`),
/// with live settings sync (`GET /`) and explicit controls for Steps, Shift, Guidance/CFG, Sampler, and Upscaler.
public struct DrawThingsSheetView: View {
    @Bindable var coordinator: PipelineCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var promptStyle: PanoramaPromptStyle = .photorealVP
    @State private var previousPromptBeforeEnhance: String?
    @State private var previousNegativeBeforeEnhance: String?

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    Label("Generate 360° Panorama via Draw Things", systemImage: "wand.and.stars")
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
                    .disabled(coordinator.isGeneratingWithDrawThings)
                }

                // Server Connection Bar
                HStack(spacing: 10) {
                    statusBadge

                    Spacer()

                    HStack(spacing: 4) {
                        Text("Port:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("7860", value: $coordinator.drawThingsPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(coordinator.isGeneratingWithDrawThings)
                    }

                    if !coordinator.drawThingsStatus.isOnline && DrawThingsClient.installedDrawThingsAppURL() != nil {
                        Button("Open Draw Things") {
                            coordinator.launchDrawThingsAndCheck()
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isGeneratingWithDrawThings)
                    }

                    Button("Sync") {
                        coordinator.checkDrawThingsServer(applySyncedSettings: true)
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isGeneratingWithDrawThings)
                    .help("Connect to Draw Things HTTP API and sync active Steps, Shift, Guidance, Sampler, and Upscaler")
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                if !coordinator.drawThingsStatus.isOnline {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("In Draw Things, open Settings → API Server → switch Protocol to HTTP (Port \(coordinator.drawThingsPort)) and enable Server Online. Clicking Sync imports your active Steps, Shift, Sampler, and Guidance automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                // Prompt + 360° Prompt Enhancer
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("360° Panorama Prompt")
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        Picker("", selection: $promptStyle) {
                            ForEach(PanoramaPromptStyle.allCases) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 148)
                        .disabled(coordinator.isGeneratingWithDrawThings)

                        Button {
                            let currentPrompt = coordinator.drawThingsPrompt
                            let currentNeg = coordinator.drawThingsNegativePrompt
                            let result = PanoramaPromptEnhancer.enhance(
                                prompt: currentPrompt,
                                existingNegativePrompt: currentNeg,
                                style: promptStyle
                            )
                            if result.prompt != currentPrompt || result.negativePrompt != currentNeg {
                                previousPromptBeforeEnhance = currentPrompt
                                previousNegativeBeforeEnhance = currentNeg
                                coordinator.drawThingsPrompt = result.prompt
                                coordinator.drawThingsNegativePrompt = result.negativePrompt
                            }
                        } label: {
                            Label("Enhance 360°", systemImage: "sparkles")
                        }
                        .controlSize(.small)
                        .disabled(
                            coordinator.isGeneratingWithDrawThings
                            || coordinator.drawThingsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .help("Expand your prompt with 360° equirectangular framing, seamless wrap, level horizon, and depth-friendly lighting cues")

                        if let prevPrompt = previousPromptBeforeEnhance {
                            Button("Undo") {
                                coordinator.drawThingsPrompt = prevPrompt
                                if let prevNeg = previousNegativeBeforeEnhance {
                                    coordinator.drawThingsNegativePrompt = prevNeg
                                }
                                previousPromptBeforeEnhance = nil
                                previousNegativeBeforeEnhance = nil
                            }
                            .controlSize(.small)
                            .disabled(coordinator.isGeneratingWithDrawThings)
                        }
                    }

                    TextEditor(text: $coordinator.drawThingsPrompt)
                        .font(.body)
                        .frame(height: 86)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                        )
                        .disabled(coordinator.isGeneratingWithDrawThings)
                }

                // Negative Prompt
                VStack(alignment: .leading, spacing: 5) {
                    Text("Negative Prompt (Optional)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("blurry, seam, distorted horizon, watermark...", text: $coordinator.drawThingsNegativePrompt)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.isGeneratingWithDrawThings)
                }

                // Generation Controls (Steps, Shift, Guidance, Sampler, Upscaler, Size, Seed)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Generation Settings (Synced with Draw Things)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if coordinator.drawThingsStatus.isOnline {
                            Button("Pull Active from Draw Things") {
                                coordinator.checkDrawThingsServer(applySyncedSettings: true)
                            }
                            .controlSize(.mini)
                            .disabled(coordinator.isGeneratingWithDrawThings)
                        }
                    }

                    // Size & Seed row
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Size")
                                .font(.caption.weight(.medium))
                                .frame(width: 58, alignment: .leading)
                            Picker("", selection: $coordinator.drawThingsSizePreset) {
                                ForEach(DrawThingsSizePreset.allCases) { preset in
                                    Text(preset.label).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .disabled(coordinator.isGeneratingWithDrawThings)
                        }

                        HStack(spacing: 6) {
                            Text("Seed")
                                .font(.caption.weight(.medium))
                            TextField("-1", value: $coordinator.drawThingsSeed, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 88)
                                .disabled(coordinator.isGeneratingWithDrawThings)
                        }
                    }

                    // Steps & Guidance row
                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Text("Steps")
                                .font(.caption.weight(.medium))
                                .frame(width: 58, alignment: .leading)
                            TextField("8", value: $coordinator.drawThingsSteps, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 56)
                                .disabled(coordinator.isGeneratingWithDrawThings)
                            Stepper("", value: $coordinator.drawThingsSteps, in: 1...100, step: 1)
                                .labelsHidden()
                                .disabled(coordinator.isGeneratingWithDrawThings)
                        }

                        HStack(spacing: 6) {
                            Text("Guidance")
                                .font(.caption.weight(.medium))
                            Slider(value: $coordinator.drawThingsGuidanceScale, in: 1.0...15.0, step: 0.5)
                                .disabled(coordinator.isGeneratingWithDrawThings)
                            Text(String(format: "%.1f", coordinator.drawThingsGuidanceScale))
                                .font(.caption.monospacedDigit())
                                .frame(width: 34, alignment: .trailing)
                        }
                    }

                    // Shift & Resolution-Dependent Shift row (critical for Qwen 2.1 Turbo / Flux / SD3)
                    HStack(spacing: 12) {
                        Text("Shift")
                            .font(.caption.weight(.medium))
                            .frame(width: 58, alignment: .leading)
                        Slider(value: $coordinator.drawThingsShift, in: 0.1...10.0, step: 0.1)
                            .disabled(coordinator.isGeneratingWithDrawThings)
                        Text(String(format: "%.2f", coordinator.drawThingsShift))
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                        Toggle("Res-Dependent", isOn: $coordinator.drawThingsResolutionDependentShift)
                            .font(.caption)
                            .disabled(coordinator.isGeneratingWithDrawThings)
                    }
                    .help("Noise schedule shift for flow-matching models (Qwen 2.1 Turbo / Flux / SD3). Wrong shift values can add noisy artifact textures—click Sync to pull Draw Things' active shift.")

                    // Sampler row
                    HStack(spacing: 8) {
                        Text("Sampler")
                            .font(.caption.weight(.medium))
                            .frame(width: 58, alignment: .leading)
                        Picker("", selection: $coordinator.drawThingsSampler) {
                            ForEach(DrawThingsSamplerOption.allCases) { opt in
                                Text(opt.rawValue).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .disabled(coordinator.isGeneratingWithDrawThings)
                    }

                    // Upscaler row
                    HStack(spacing: 8) {
                        Text("Upscaler")
                            .font(.caption.weight(.medium))
                            .frame(width: 58, alignment: .leading)
                        Picker("", selection: $coordinator.drawThingsUpscaler) {
                            ForEach(DrawThingsUpscalerOption.allCases) { opt in
                                Text(opt.label).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .disabled(coordinator.isGeneratingWithDrawThings)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                if let error = coordinator.drawThingsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if coordinator.isGeneratingWithDrawThings {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(coordinator.drawThingsProgressText)
                                .font(.caption.weight(.medium))
                            Spacer()
                            if coordinator.drawThingsProgress > 0 {
                                Text("\(Int((coordinator.drawThingsProgress * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if coordinator.drawThingsProgress > 0 {
                            ProgressView(value: coordinator.drawThingsProgress, total: 1.0)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                }

                Divider()

                HStack {
                    if coordinator.isGeneratingWithDrawThings {
                        Button("Cancel Generation", role: .cancel) {
                            coordinator.cancelDrawThingsGeneration()
                        }
                    } else {
                        Button("Close") {
                            dismiss()
                        }
                    }

                    Spacer()

                    Button {
                        coordinator.generatePanoramaWithDrawThings {
                            dismiss()
                        }
                    } label: {
                        Label("Generate & Load 360°", systemImage: "sparkles")
                            .frame(minWidth: 165)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        coordinator.isGeneratingWithDrawThings
                        || coordinator.drawThingsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(20)
        }
        .frame(width: 580, height: 610)
        .onAppear {
            coordinator.checkDrawThingsServer(applySyncedSettings: !coordinator.hasSyncedDrawThingsOnce)
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
