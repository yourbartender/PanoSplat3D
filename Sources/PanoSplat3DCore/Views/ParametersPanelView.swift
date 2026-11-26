import SwiftUI

/// Compact two-column parameters card designed to fit cleanly on MacBook laptop displays
/// without sacrificing control precision or tooltips.
public struct ParametersPanelView: View {
    @Bindable var coordinator: PipelineCoordinator
    @State private var isShowingUpscalerPopover: Bool = false

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Export Mode | Depth AI Model
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Export")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    Picker("", selection: $coordinator.settings.exportMode) {
                        Text(".ply Splat").tag(ExportMode.plySplat)
                        Text("COLMAP Only").tag(ExportMode.colmapDataset)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)
                }
                .frame(maxWidth: .infinity)
                .help(coordinator.settings.exportMode.shortDescription)

                HStack(spacing: 8) {
                    Text("Depth AI")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: $coordinator.settings.depthModel) {
                        Text("DA2 Small — Fast (~50 MB)").tag(DepthModelVariant.depthAnythingV2Small)
                        Text("DA3 Base — Detail (~233 MB)").tag(DepthModelVariant.depthAnythingV3Base)
                        Text("Depth Pro 1536px (~745 MB)").tag(DepthModelVariant.appleDepthPro)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(coordinator.isRunning || coordinator.depthModelState.isBusy)
                }
                .frame(maxWidth: .infinity)
                .help(coordinator.settings.depthModel.shortDescription)
            }

            // Row 2: Depth Scale | Parallax Baseline (two sliders side-by-side)
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Depth Scale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)

                    Slider(
                        value: $coordinator.settings.depthScaleMeters,
                        in: 2.0...50.0,
                        step: 0.5
                    )
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)

                    Text(String(format: "%.1fm", coordinator.settings.depthScaleMeters))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                .help("Real-world scene radius in meters (Indoor 7–9m, Outdoor 10–15m, Vista 20–30m). Closest objects sit at ~0.22× Depth Scale.")

                HStack(spacing: 8) {
                    Text("Parallax")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    Slider(
                        value: $coordinator.settings.parallaxBaselineMeters,
                        in: 0.0...2.0,
                        step: 0.05
                    )
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)

                    Text(String(format: "%.2fm", coordinator.settings.parallaxBaselineMeters))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                .help("Virtual camera shift radius for 24 two-ring parallax views (0.0m = tripod only, 0.30–0.60m = natural 3D depth).")
            }

            // Row 3: View Resolution | 360° AI Auto-Upscale
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("View Res")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    Picker("", selection: $coordinator.settings.viewResolutionPreset) {
                        Text("768").tag(ViewResolutionPreset.draft)
                        Text("1024").tag(ViewResolutionPreset.standard)
                        Text("1280").tag(ViewResolutionPreset.sharp)
                        Text("1536").tag(ViewResolutionPreset.ultra)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)
                }
                .frame(maxWidth: .infinity)
                .help("Perspective view size & Brush --max-resolution. 768/1024 train faster; 1280/1536 maximize detail on 6K+ Insta360 photos.")

                HStack(spacing: 8) {
                    Toggle("Auto-upscale 2×", isOn: $coordinator.settings.autoUpscaleLowRes)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .disabled(coordinator.isRunning)
                        .help("Automatically upgrades lower-resolution panoramas (<3072px wide) to 2× using your chosen 360°-wrap-safe CoreML upscaler & blend strength.")

                    Button {
                        isShowingUpscalerPopover.toggle()
                    } label: {
                        let pct = Int((coordinator.settings.upscalerBlendStrength * 100).rounded())
                        Label("\(coordinator.settings.upscalerModel.shortBadgeName) · \(pct)%", systemImage: "slider.horizontal.3")
                            .font(.caption2.weight(.medium))
                    }
                    .controlSize(.mini)
                    .disabled(coordinator.isRunning)
                    .help("Choose CoreML upscaler model (RealPLKSR 2× Natural, 4xNomosWebPhoto, Real-ESRGAN) and AI-to-bicubic strength blend.")
                    .popover(isPresented: $isShowingUpscalerPopover, arrowEdge: .bottom) {
                        UpscalerOptionsPopoverView(coordinator: coordinator)
                    }

                    Toggle("Fill voids (LaMa)", isOn: $coordinator.settings.inpaintParallaxHoles)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .disabled(coordinator.isRunning || coordinator.settings.parallaxBaselineMeters <= 0.01)
                        .help("Uses CoreML LaMa (~206 MB one-time) + 2-layer point seeding to fill black disocclusion voids behind foreground trees, rocks, and objects.")

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Row 4: Brush Training Steps | Spherical Harmonics Degree
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Steps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    Picker("", selection: $coordinator.settings.trainingSteps) {
                        Text("5K Fast").tag(TrainingStepsPreset.fast)
                        Text("8K Bal").tag(TrainingStepsPreset.balanced)
                        Text("15K High").tag(TrainingStepsPreset.high)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning || coordinator.settings.exportMode == .colmapDataset)
                }
                .frame(maxWidth: .infinity)
                .help("Brush 3DGS training iterations. Splitting stops at 70% so the final 30% converges cleanly.")

                HStack(spacing: 8) {
                    Text("SH Degree")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: $coordinator.settings.shDegree) {
                        ForEach(SphericalHarmonicsDegree.allCases) { degree in
                            Text("SH \(degree.label)").tag(degree)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning || coordinator.settings.exportMode == .colmapDataset)
                }
                .frame(maxWidth: .infinity)
                .help("SH 1 = smallest/fastest, SH 2 = balanced (SuperSplat/SplatScene), SH 3 = full 45 f_rest properties (required by RadianceView).")
            }
            .opacity(coordinator.settings.exportMode == .colmapDataset ? 0.45 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
