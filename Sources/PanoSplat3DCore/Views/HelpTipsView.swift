import SwiftUI

/// Collapsible quick-reference guide explaining Depth Scale, Parallax Baseline, Spherical Harmonics,
/// and one-click Real 360° Photo presets.
public struct HelpTipsView: View {
    @Bindable var coordinator: PipelineCoordinator
    @State private var isExpanded: Bool = false

    private struct ScenePreset: Identifiable {
        let id: String
        let sceneType: String
        let depthRangeLabel: String
        let baselineRangeLabel: String
        let depthValue: Double
        let baselineValue: Double
    }

    private let presets: [ScenePreset] = [
        ScenePreset(
            id: "indoor",
            sceneType: "Indoor room (1.7m tripod)",
            depthRangeLabel: "7m – 9m",
            baselineRangeLabel: "0.25m – 0.40m",
            depthValue: 8.0,
            baselineValue: 0.35
        ),
        ScenePreset(
            id: "outdoor",
            sceneType: "Outdoor street / forest / courtyard",
            depthRangeLabel: "10m – 15m",
            baselineRangeLabel: "0.40m – 0.65m",
            depthValue: 12.0,
            baselineValue: 0.50
        ),
        ScenePreset(
            id: "vista",
            sceneType: "Wide open vista (no close objects)",
            depthRangeLabel: "20m – 30m",
            baselineRangeLabel: "0.75m – 1.25m",
            depthValue: 24.0,
            baselineValue: 0.95
        )
    ]

    public init(coordinator: PipelineCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                // Quick Rule of Thumb table with one-click Apply presets
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Rule of Thumb for Real 360° Photos")
                        .font(.subheadline.weight(.semibold))

                    VStack(spacing: 0) {
                        // Table header
                        HStack {
                            Text("Scene Type")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Depth Scale")
                                .frame(width: 95, alignment: .center)
                            Text("Parallax")
                                .frame(width: 105, alignment: .center)
                            Text("Preset")
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))

                        ForEach(presets) { preset in
                            Divider()
                            HStack {
                                Text(preset.sceneType)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(preset.depthRangeLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 95, alignment: .center)
                                Text(preset.baselineRangeLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 105, alignment: .center)
                                Button("Apply") {
                                    coordinator.applyScenePreset(
                                        name: preset.sceneType,
                                        depthScaleMeters: preset.depthValue,
                                        parallaxBaselineMeters: preset.baselineValue
                                    )
                                }
                                .controlSize(.mini)
                                .disabled(coordinator.isRunning)
                                .frame(width: 64, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }

                // Parameter explanations
                VStack(alignment: .leading, spacing: 8) {
                    tipRow(
                        icon: "cpu",
                        title: "Depth AI Model:",
                        text: "Depth Anything V2 Small (~50 MB) is fastest (~1s). Depth Anything V3 Base (~233 MB, ~10–15s on Metal GPU) is the best all-around choice with cleaner 3D structure. Apple Depth Pro 1536px (~745 MB, ~2–3 min on Metal GPU) gives maximum edge sharpness on thin branches and foliage."
                    )
                    tipRow(
                        icon: "ruler",
                        title: "Depth Scale / Radius:",
                        text: "Sets the real-world physical scale of the 3D scene around your camera. Closest objects sit at ~0.22× Depth Scale (min 1.5m) and distant sky at ~3.8× (max 60m). Match it to your scene—larger values do not automatically improve quality."
                    )
                    tipRow(
                        icon: "camera.metering.multispot",
                        title: "Parallax Baseline & LaMa Void Fill:",
                        text: "Moves 24 extra views in two concentric rings (0.5× and 1.0× baseline) around the tripod for true 3D depth separation. With Fill voids (LaMa) enabled, CoreML LaMa automatically inpaints hidden snow/forest/sky behind foreground trees & rocks instead of leaving black parallax voids. (Auto-clamped to 40% of closest surface depth.)"
                    )
                    tipRow(
                        icon: "sun.max",
                        title: "Spherical Harmonics (SH 1 / 2 / 3):",
                        text: "Controls view-dependent color & reflections. SH 1 is fastest with the smallest .ply file. SH 2 (recommended for SuperSplat/SplatScene) balances highlights and file size. Use SH 3 (45 f_rest properties) for maximum specular realism or viewers like RadianceView that require full SH 3 PLY headers."
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Tips & Parameter Guide (360° Depth, Parallax & SH)", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func tipRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)
            Text(LocalizedStringKey("**\(title)** \(text)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
