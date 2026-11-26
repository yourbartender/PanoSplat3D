import SwiftUI

/// Compact inline output filename + folder chooser card.
public struct OutputDestinationView: View {
    @Bindable var coordinator: PipelineCoordinator

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: coordinator.settings.exportMode == .plySplat ? "cube.transparent" : "folder.badge.gearshape")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(
                    coordinator.settings.exportMode == .plySplat ? "Output filename" : "Dataset folder name",
                    text: Binding(
                        get: { coordinator.editableOutputName },
                        set: { coordinator.applyEditedOutputName($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(coordinator.isRunning)

                Text(coordinator.settings.exportMode == .plySplat ? ".ply" : "_colmap/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button("Choose Folder...") {
                    coordinator.chooseOutputDestinationViaDialog()
                }
                .controlSize(.small)
                .disabled(coordinator.isRunning)
            }

            HStack(spacing: 10) {
                if let outputURL = coordinator.outputURL {
                    Text(abbreviatedPath(outputURL.path))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(outputURL.path)
                } else {
                    Text("Defaults to last output folder or input image's folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Toggle("Remember last folder", isOn: $coordinator.settings.saveToLastUsedFolder)
                    .font(.caption2)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .disabled(coordinator.isRunning)
                    .help("When enabled, new panoramas automatically save into your last chosen output folder instead of the source image's folder.")
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
