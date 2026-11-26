import SwiftUI

/// Compact status strip showing Brush Engine & active CoreML Depth AI readiness on one row,
/// expanding smoothly only when downloading, compiling, or showing an error.
public struct BrushStatusBarView: View {
    @Bindable var coordinator: PipelineCoordinator

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Brush Engine status pill
                if let engine = coordinator.brushEngine {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Brush: Ready")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .help("\(engine.displayName) (\(engine.source.rawValue))\n\(engine.executableURL.path)")

                    Button("Change") {
                        coordinator.locateBrushViaDialog()
                    }
                    .controlSize(.mini)
                    .disabled(coordinator.isRunning)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Brush: Missing")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.16), in: Capsule())

                    Button("Locate Brush...") {
                        coordinator.locateBrushViaDialog()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

                Divider()
                    .frame(height: 16)

                // Depth AI compact status inline
                depthModelInlineStatus

                Spacer(minLength: 0)
            }

            if let brushError = coordinator.brushError {
                Label(brushError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var depthModelInlineStatus: some View {
        let model = coordinator.settings.depthModel
        switch coordinator.depthModelState {
        case .ready:
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Depth AI: Ready")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.14), in: Capsule())

                Text(model.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(model.shortDescription)

        case .downloading(let progress, let downloadedMB, let totalMB):
            HStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0)
                    .frame(width: 110)
                Text(String(format: "Downloading %@ (%.0f/%.0f MB)", model.displayName, downloadedMB, totalMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .compiling:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("Preparing \(model.displayName)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .notDownloaded:
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Depth AI: ~\(model.approximateSizeMB) MB")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.14), in: Capsule())

                Text(model.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Download") {
                    coordinator.downloadDepthModel()
                }
                .controlSize(.mini)
                .disabled(coordinator.isRunning)
            }
            .help("\(model.displayName) downloads automatically on first run, or click Download now.")

        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)

                Button("Retry") {
                    coordinator.downloadDepthModel()
                }
                .controlSize(.mini)
            }
        }
    }
}
