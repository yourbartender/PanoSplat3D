import SwiftUI
import UniformTypeIdentifiers

/// Native macOS sheet for queuing multiple 360° panoramas for sequential overnight splat generation
/// using the exact active settings from the main window.
public struct BatchQueueSheetView: View {
    @Bindable var coordinator: PipelineCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted: Bool = false

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    private var activeSettingsSummary: String {
        let s = coordinator.settings
        var parts: [String] = [
            s.depthModel.displayName,
            String(format: "%.0fm", s.depthScaleMeters),
            String(format: "Parallax %.2fm", s.parallaxBaselineMeters),
            "\(s.perspectiveResolution)px"
        ]
        if s.autoUpscaleLowRes {
            let pct = Int((s.upscalerBlendStrength * 100).rounded())
            parts.append("\(s.upscalerModel.shortBadgeName) \(pct)%")
        }
        if s.inpaintParallaxHoles && s.parallaxBaselineMeters > 0.01 {
            parts.append("LaMa")
        }
        if s.exportMode == .plySplat {
            parts.append("\(s.trainingSteps.rawValue / 1000)K")
            parts.append("SH \(s.shDegree.label)")
        } else {
            parts.append("COLMAP Only")
        }
        return parts.joined(separator: " • ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Overnight Batch Queue", systemImage: "square.stack.3d.up.fill")
                        .font(.title3.weight(.semibold))
                    Text("Processes each queued 360° panorama sequentially using your current settings. Failed items are skipped automatically so overnight runs never stall.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            // Active settings summary strip
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(activeSettingsSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Output folder selector row
            HStack(spacing: 8) {
                Text("Output Folder:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let dir = coordinator.batchOutputDirectory {
                    Text(abbreviatedPath(dir.path))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(dir.path)
                } else {
                    Text("Same folder as each source panorama")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Choose Folder...") {
                    coordinator.chooseBatchOutputDirectoryViaDialog()
                }
                .controlSize(.small)
                .disabled(coordinator.isRunningBatch)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // Queue list / Drop target
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: coordinator.batchItems.isEmpty ? [6, 5] : [])
                            )
                    )

                if coordinator.batchItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Drop Multiple 360° Panoramas Here")
                            .font(.headline)
                        Text("Or click “Add 360° Images…” below to select 10–20 panoramas for overnight rendering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            coordinator.addFilesToBatchViaDialog()
                        } label: {
                            Label("Add 360° Images...", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(coordinator.batchItems.enumerated()), id: \.element.id) { index, item in
                                batchItemRow(index: index + 1, item: item)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleMultiDrop(providers: providers)
            }

            if !coordinator.batchSummaryText.isEmpty {
                Label(coordinator.batchSummaryText, systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if coordinator.settings.exportMode == .plySplat && coordinator.brushEngine == nil {
                Label("Brush engine not located yet — locate Brush.app in the main window top bar before starting batch .ply export.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Footer controls
            HStack(spacing: 8) {
                Button {
                    coordinator.addFilesToBatchViaDialog()
                } label: {
                    Label("Add Images...", systemImage: "plus")
                }
                .controlSize(.regular)
                .disabled(coordinator.isRunningBatch)

                if coordinator.batchCompletedCount > 0 && !coordinator.isRunningBatch {
                    Button("Clear Done") {
                        coordinator.clearCompletedBatchItems()
                    }
                    .controlSize(.regular)
                }

                if coordinator.batchFailedOrCancelledCount > 0 && !coordinator.isRunningBatch {
                    Button("Retry Failed") {
                        coordinator.retryFailedBatchItems()
                    }
                    .controlSize(.regular)
                }

                if !coordinator.batchItems.isEmpty && !coordinator.isRunningBatch {
                    Button("Clear All") {
                        coordinator.clearBatchQueue()
                    }
                    .controlSize(.regular)
                }

                Spacer()

                if coordinator.isRunningBatch {
                    Button("Cancel Batch", role: .destructive) {
                        coordinator.cancelBatchQueue()
                    }
                    .controlSize(.regular)
                } else {
                    Button {
                        coordinator.startBatchQueue()
                    } label: {
                        Label(
                            "Start Batch (\(coordinator.batchPendingCount))",
                            systemImage: "play.fill"
                        )
                        .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!coordinator.canStartBatch)
                }
            }
        }
        .padding(16)
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private func batchItemRow(index: Int, item: BatchQueueItem) -> some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch item.status {
                case .queued:
                    let ext = coordinator.settings.exportMode == .plySplat ? ".ply" : "_colmap/"
                    Text("Queued → \(item.baseOutputName)\(ext)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .running(let stage, let progress):
                    HStack(spacing: 6) {
                        ProgressView(value: progress, total: 1.0)
                            .frame(width: 110)
                        Text("\(Int((progress * 100).rounded()))% • \(stage)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .completed(let outURL, let duration):
                    Text("Saved \(outURL.lastPathComponent) • \(formatDuration(duration))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .failed(let message):
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .cancelled:
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 6)

            switch item.status {
            case .queued:
                Text("Queued")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.14), in: Capsule())

                if !coordinator.isRunningBatch {
                    Button {
                        coordinator.removeBatchItem(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from batch queue")
                }

            case .running:
                ProgressView()
                    .controlSize(.small)

            case .completed(let outURL, _):
                Button {
                    NativeFileDialogs.revealInFinder(outURL)
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.caption2)
                }
                .controlSize(.mini)

            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if !coordinator.isRunningBatch {
                    Button {
                        coordinator.removeBatchItem(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.orange)
                if !coordinator.isRunningBatch {
                    Button {
                        coordinator.removeBatchItem(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            item.status.isRunning ? Color.accentColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func handleMultiDrop(providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }

        for provider in matching {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let nsString = item as? NSString {
                    resolvedURL = URL(string: nsString as String)
                } else {
                    resolvedURL = nil
                }
                if let fileURL = resolvedURL, fileURL.isFileURL {
                    Task { @MainActor in
                        coordinator.addURLsToBatch([fileURL])
                    }
                }
            }
        }
        return true
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
