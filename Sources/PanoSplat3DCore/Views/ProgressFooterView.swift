import SwiftUI

public struct ProgressFooterView: View {
    @Bindable var coordinator: PipelineCoordinator

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = coordinator.pipelineError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(coordinator.stageTitle)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if coordinator.isRunning || coordinator.progress > 0 {
                        Text("\(Int((coordinator.progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: coordinator.progress, total: 1.0)
                    .progressViewStyle(.linear)

                Text(coordinator.stageDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button {
                    coordinator.settings.playAlertSounds.toggle()
                } label: {
                    Image(systemName: coordinator.settings.playAlertSounds ? "speaker.wave.2.fill" : "speaker.slash")
                        .foregroundStyle(coordinator.settings.playAlertSounds ? .secondary : .tertiary)
                }
                .buttonStyle(.borderless)
                .help(coordinator.settings.playAlertSounds ? "Completion & error alert sounds enabled (click to mute)" : "Alert sounds muted (click to enable)")

                if coordinator.lastExportedURL != nil {
                    Button {
                        coordinator.revealLastOutputInFinder()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .controlSize(.regular)
                }

                Button {
                    coordinator.isShowingBatchSheet = true
                } label: {
                    let count = coordinator.batchItems.count
                    if coordinator.isRunningBatch {
                        Label("Batch (\(coordinator.batchCompletedCount)/\(count))", systemImage: "square.stack.3d.up.fill")
                    } else if count > 0 {
                        Label("Batch Queue (\(count))", systemImage: "square.stack.3d.up")
                    } else {
                        Label("Batch Queue...", systemImage: "square.stack.3d.up")
                    }
                }
                .controlSize(.regular)
                .help("Queue 10–20+ 360° panoramas for sequential overnight rendering using your current settings.")

                Spacer()

                if coordinator.isRunning {
                    Button("Cancel", role: .cancel) {
                        coordinator.cancelGeneration()
                    }
                    .controlSize(.regular)
                }

                Button {
                    coordinator.startGeneration()
                } label: {
                    Label(
                        coordinator.primaryActionTitle,
                        systemImage: coordinator.settings.exportMode == .plySplat ? "sparkles" : "square.and.arrow.down.on.square"
                    )
                    .frame(minWidth: 175)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!coordinator.canGenerate)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .sheet(isPresented: $coordinator.isShowingBatchSheet) {
            BatchQueueSheetView(coordinator: coordinator)
        }
    }
}
