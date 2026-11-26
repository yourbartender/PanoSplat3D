import SwiftUI

/// Compact popover for selecting the CoreML 360° upscaler architecture, adjusting AI-to-bicubic
/// blend strength, and launching a 1-click A/B test on the loaded panorama.
public struct UpscalerOptionsPopoverView: View {
    @Bindable var coordinator: PipelineCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    private var strengthPercent: Int {
        Int((coordinator.settings.upscalerBlendStrength * 100).rounded())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("360° AI Upscaler Settings", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                if coordinator.upscalerModelState.isReady {
                    Label("Cached", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Text("~\(coordinator.settings.upscalerModel.approximateSizeMB) MB download")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CoreML Model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: $coordinator.settings.upscalerModel) {
                    ForEach(UpscalerModelVariant.allCases) { variant in
                        Text(variant.pickerLabel).tag(variant)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .disabled(coordinator.isRunning || coordinator.isUpscalingPanorama)

                Text(coordinator.settings.upscalerModel.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AI Detail Strength")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(strengthPercent)%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }

                Slider(
                    value: $coordinator.settings.upscalerBlendStrength,
                    in: 0.50...1.0,
                    step: 0.05
                )
                .disabled(coordinator.isRunning || coordinator.isUpscalingPanorama)

                Text("Blends AI super-resolution with a 360°-wrap-safe bicubic base. 75–85% keeps crisp edges while preserving natural moss, stone & water grain.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.panorama != nil {
                Divider()

                HStack(spacing: 8) {
                    if coordinator.canUndoUpscale {
                        Button {
                            coordinator.undoUpscale()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                    }

                    if coordinator.isCurrentPanoramaUpscaled {
                        Button {
                            coordinator.saveUpscaledPanoramaViaDialog()
                        } label: {
                            Label("Save Upscaled...", systemImage: "square.and.arrow.down")
                        }
                        .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        dismiss()
                        coordinator.upscaleCurrentPanorama(factor: .x2)
                    } label: {
                        Label(
                            coordinator.isCurrentPanoramaUpscaled ? "Re-test 2× Now" : "1-Click Test 2×",
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning || coordinator.isUpscalingPanorama)
                }
            }
        }
        .padding(14)
        .frame(width: 370)
    }
}
