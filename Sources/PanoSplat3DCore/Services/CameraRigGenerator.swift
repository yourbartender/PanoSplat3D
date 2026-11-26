import Foundation
import simd

/// Generates virtual camera poses in standard COLMAP RDF world space (`+X` right, `+Y` down, `+Z` forward).
public enum CameraRigGenerator {
    /// Generates a high-density 20-camera center spherical rig covering 100% of the 360° × 180° sphere
    /// with minimal perspective edge distortion at `82°` FOV:
    /// - 8 horizon views (`pitch = 0°`, every `45°` yaw)
    /// - 5 upper views (`pitch = +44°`, every `72°` yaw)
    /// - 5 lower views (`pitch = -44°`, every `72°` yaw)
    /// - 1 zenith view (`pitch = +90°`) + 1 nadir view (`pitch = -90°`)
    public static func makeCenterSphericalRig(cameraID: Int = 1) -> [VirtualCameraPose] {
        var poses: [VirtualCameraPose] = []
        var imageID = 1

        func appendPose(yaw: Double, pitch: Double) {
            let fileIndex = imageID - 1
            let name = String(format: "view_%03d.png", fileIndex)
            poses.append(
                VirtualCameraPose(
                    imageID: imageID,
                    name: name,
                    cameraID: cameraID,
                    worldPosition: .zero,
                    yawDegrees: yaw,
                    pitchDegrees: pitch
                )
            )
            imageID += 1
        }

        // Horizon ring (0° pitch, 8 views every 45°)
        for i in 0..<8 {
            appendPose(yaw: Double(i) * 45.0, pitch: 0.0)
        }

        // Upper ring (+44° pitch, 5 views every 72°)
        for i in 0..<5 {
            appendPose(yaw: 18.0 + Double(i) * 72.0, pitch: 44.0)
        }

        // Lower ring (-44° pitch, 5 views every 72°)
        for i in 0..<5 {
            appendPose(yaw: 54.0 + Double(i) * 72.0, pitch: -44.0)
        }

        // Zenith & Nadir caps
        appendPose(yaw: 0.0, pitch: 90.0)
        appendPose(yaw: 0.0, pitch: -90.0)

        return poses
    }

    /// Generates the two-ring multi-position parallax camera rig (44 views total when `baselineMeters > 0.01`):
    /// - 20 crisp ground-truth center-origin views (`view_000.png ... view_019.png`) locking in sharp textures everywhere
    /// - 12 inner-ring parallax views (`view_020.png ... view_031.png`) at `0.5 × baselineMeters` (every `30°`, `±0.12m` vertical)
    /// - 12 outer-ring parallax views (`view_032.png ... view_043.png`) at `1.0 × baselineMeters` (staggered `15°`, opposite lateral shift, `±0.20m` vertical)
    ///
    /// Two concentric parallax rings constrain foreground depth smoothly across small and medium camera translations
    /// without increasing Brush step training time.
    public static func makeParallaxRig(
        baselineMeters: Double,
        verticalOffsetMeters: Double = 0.20,
        cameraID: Int = 1
    ) -> [VirtualCameraPose] {
        var poses = makeCenterSphericalRig(cameraID: cameraID)

        guard baselineMeters > 0.01 else {
            return poses
        }

        let ringConfigs: [(radiusScale: Double, yawOffsetDeg: Double, lateralFlip: Double, verticalScale: Double)] = [
            (0.50, 0.0, 1.0, 0.60),   // Inner ring: gentle half-baseline parallax
            (1.00, 15.0, -1.0, 1.00)  // Outer ring: full baseline, staggered yaw & opposite lateral side
        ]

        let viewsPerRing = 12
        for ring in ringConfigs {
            let ringRadius = baselineMeters * ring.radiusScale
            let effectiveVertical = min(verticalOffsetMeters * ring.verticalScale, ringRadius * 0.35)

            for i in 0..<viewsPerRing {
                let imageID = poses.count + 1
                let fileIndex = imageID - 1
                let name = String(format: "view_%03d.png", fileIndex)

                let azimuthDeg = (Double(i) * (360.0 / Double(viewsPerRing)) + ring.yawOffsetDeg)
                    .truncatingRemainder(dividingBy: 360.0)
                let azimuthRad = azimuthDeg * (.pi / 180.0)

                // Lateral baseline offset perpendicular to viewing direction in COLMAP RDF
                let lateralSign = ((i % 2 == 0) ? 1.0 : -1.0) * ring.lateralFlip
                let yOffset = (i % 2 == 0) ? -effectiveVertical : effectiveVertical

                let worldPosition = SIMD3<Double>(
                    ringRadius * lateralSign * cos(azimuthRad),
                    yOffset,
                    -ringRadius * lateralSign * sin(azimuthRad)
                )

                let pitchDeg = (i % 4 == 0) ? 5.0 : ((i % 4 == 2) ? -5.0 : 0.0)

                poses.append(
                    VirtualCameraPose(
                        imageID: imageID,
                        name: name,
                        cameraID: cameraID,
                        worldPosition: worldPosition,
                        yawDegrees: azimuthDeg,
                        pitchDegrees: pitchDeg
                    )
                )
            }
        }

        return poses
    }
}
