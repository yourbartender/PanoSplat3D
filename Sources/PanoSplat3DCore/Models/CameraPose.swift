import Foundation
import simd

/// COLMAP `SIMPLE_PINHOLE` camera intrinsics.
public struct PinholeCameraIntrinsics: Equatable, Sendable {
    public let cameraID: Int
    public let width: Int
    public let height: Int
    public let focalLength: Double
    public let cx: Double
    public let cy: Double

    public init(
        cameraID: Int = 1,
        width: Int,
        height: Int,
        fovDegrees: Double
    ) {
        self.cameraID = cameraID
        self.width = width
        self.height = height
        let halfFovRadians = (fovDegrees * 0.5) * (.pi / 180.0)
        self.focalLength = (Double(width) * 0.5) / tan(halfFovRadians)
        self.cx = Double(width) * 0.5
        self.cy = Double(height) * 0.5
    }

    /// Formats a line for COLMAP `cameras.txt`:
    /// `CAMERA_ID MODEL WIDTH HEIGHT PARAMS[]`
    public var colmapLine: String {
        String(
            format: "%d SIMPLE_PINHOLE %d %d %.6f %.6f %.6f",
            cameraID, width, height, focalLength, cx, cy
        )
    }
}

/// Virtual camera pose in standard **COLMAP / OpenCV right-handed RDF world space**
/// (`+X` Right, `+Y` Down, `+Z` Forward — i.e., `-Y` is Zenith / Up).
///
/// Using standard COLMAP RDF world space ensures `.ply` splats trained by Brush load **upright with zero
/// manual 180° flip** in SuperSplat, PlayCanvas, Unreal Engine 5.8, and Assimilate Live FX.
public struct VirtualCameraPose: Equatable, Sendable {
    public let imageID: Int
    public let name: String
    public let cameraID: Int
    /// Camera center `C_w` in COLMAP RDF world space (meters; `-Y` is up).
    public let worldPosition: SIMD3<Double>
    /// Yaw angle in degrees (`0°` = `+Z` forward, `+90°` = `+X` right, `-90°` = `-X` left, `±180°` = `-Z` back).
    public let yawDegrees: Double
    /// Pitch angle in degrees (`0°` = horizon, `+90°` = `-Y` zenith/up, `-90°` = `+Y` nadir/down).
    public let pitchDegrees: Double

    /// Camera basis vectors in COLMAP RDF world space (columns of `R_wc`, rows of `R_cw`):
    /// - `cameraRight`   = `+X_cam`
    /// - `cameraDown`    = `+Y_cam`
    /// - `cameraForward` = `+Z_cam`
    public let cameraRight: SIMD3<Double>
    public let cameraDown: SIMD3<Double>
    public let cameraForward: SIMD3<Double>

    public init(
        imageID: Int,
        name: String,
        cameraID: Int = 1,
        worldPosition: SIMD3<Double> = .zero,
        yawDegrees: Double,
        pitchDegrees: Double
    ) {
        self.imageID = imageID
        self.name = name
        self.cameraID = cameraID
        self.worldPosition = worldPosition
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees

        let yaw = yawDegrees * (.pi / 180.0)
        let pitch = pitchDegrees * (.pi / 180.0)

        // Forward (+Z_cam) in COLMAP RDF world space:
        //   yaw=0, pitch=0   -> (0, 0, +1)
        //   yaw=+90, pitch=0 -> (+1, 0, 0)
        //   yaw=0, pitch=+90 -> (0, -1, 0) [Zenith / Up]
        let forward = simd_normalize(SIMD3<Double>(
            cos(pitch) * sin(yaw),
            -sin(pitch),
            cos(pitch) * cos(yaw)
        ))

        // Analytical horizontal right (+X_cam), orthogonal to forward even at pitch = ±90° (zero gimbal lock):
        //   yaw=0   -> (+1, 0, 0)
        //   yaw=+90 -> (0, 0, -1)
        let right = simd_normalize(SIMD3<Double>(
            cos(yaw),
            0.0,
            -sin(yaw)
        ))

        // Camera Down (+Y_cam) = forward × right
        // Check at yaw=0, pitch=0: (0,0,1) × (1,0,0) = (0,+1,0) [+Y down]
        // Determinant det([right, down, forward]) = (right × down) · forward = +1 (proper SO(3))
        let down = simd_normalize(simd_cross(forward, right))

        self.cameraRight = right
        self.cameraDown = down
        self.cameraForward = forward
    }

    /// World-to-camera rotation matrix `R_cw` (rows are camera axes `+X_cam`, `+Y_cam`, `+Z_cam` in world coordinates).
    /// Maps a world point `P_w` to camera space via `P_c = R_cw * P_w + t_cw`.
    public var worldToCameraRotation: simd_double3x3 {
        simd_double3x3(rows: [cameraRight, cameraDown, cameraForward])
    }

    /// Camera-to-world rotation matrix `R_wc = R_cw^T`.
    public var cameraToWorldRotation: simd_double3x3 {
        simd_double3x3(columns: (cameraRight, cameraDown, cameraForward))
    }

    /// Unit quaternion `(qw, qx, qy, qz)` for `R_cw` in COLMAP Hamilton convention (scalar-first, normalized).
    public var colmapQuaternion: (qw: Double, qx: Double, qy: Double, qz: Double) {
        let q = simd_normalize(simd_quatd(worldToCameraRotation))
        if q.real < 0 {
            return (-q.real, -q.imag.x, -q.imag.y, -q.imag.z)
        }
        return (q.real, q.imag.x, q.imag.y, q.imag.z)
    }

    /// COLMAP translation vector `t_cw = -R_cw * C_w`.
    public var colmapTranslation: SIMD3<Double> {
        -(worldToCameraRotation * worldPosition)
    }

    /// Transforms a world point into camera space `P_c = R_cw * P_w + t_cw`.
    public func worldToCamera(_ worldPoint: SIMD3<Double>) -> SIMD3<Double> {
        worldToCameraRotation * worldPoint + colmapTranslation
    }

    /// Projects a world point into pixel coordinates `(x, y)` if in front of the camera (`z > 0`).
    public func project(_ worldPoint: SIMD3<Double>, intrinsics: PinholeCameraIntrinsics) -> SIMD2<Double>? {
        let pCam = worldToCamera(worldPoint)
        guard pCam.z > 1e-6 else { return nil }
        let u = intrinsics.focalLength * (pCam.x / pCam.z) + intrinsics.cx
        let v = intrinsics.focalLength * (pCam.y / pCam.z) + intrinsics.cy
        return SIMD2<Double>(u, v)
    }

    /// Formats the pose line for COLMAP `images.txt`:
    /// `IMAGE_ID QW QX QY QZ TX TY TZ CAMERA_ID NAME`
    public var colmapPoseLine: String {
        let q = colmapQuaternion
        let t = colmapTranslation
        return String(
            format: "%d %.9f %.9f %.9f %.9f %.9f %.9f %.9f %d %@",
            imageID,
            q.qw, q.qx, q.qy, q.qz,
            t.x, t.y, t.z,
            cameraID,
            name
        )
    }
}

/// Spherical equirectangular coordinate conversions in standard **COLMAP / OpenCV RDF world space**
/// (`+X` right, `+Y` down, `+Z` forward; `-Y` is zenith/up).
public enum SphericalMath {
    /// Converts normalized equirectangular coordinates `u in [0, 1]` (left to right), `v in [0, 1]` (top to bottom)
    /// into a unit 3D direction vector in COLMAP RDF world space.
    /// - `(u=0.5, v=0.5)` -> `(0, 0, +1)` (Forward)
    /// - `(u=0.75, v=0.5)` -> `(+1, 0, 0)` (Right)
    /// - `(u=0.25, v=0.5)` -> `(-1, 0, 0)` (Left)
    /// - `(u=0.0/1.0, v=0.5)` -> `(0, 0, -1)` (Back)
    /// - `(v=0.0)` -> `(0, -1, 0)` (Zenith / Sky / Up)
    /// - `(v=1.0)` -> `(0, +1, 0)` (Nadir / Ground / Down)
    public static func equirectangularUVToWorldDirection(u: Double, v: Double) -> SIMD3<Double> {
        let phi = (u - 0.5) * (2.0 * .pi)
        let theta = (0.5 - v) * .pi
        let cosTheta = cos(theta)
        return SIMD3<Double>(
            cosTheta * sin(phi),
            -sin(theta),
            cosTheta * cos(phi)
        )
    }

    /// Inverse mapping from unit COLMAP RDF world direction vector to normalized equirectangular UV in `[0, 1] x [0, 1]`.
    public static func worldDirectionToEquirectangularUV(_ dir: SIMD3<Double>) -> SIMD2<Double> {
        let d = simd_normalize(dir)
        let phi = atan2(d.x, d.z)
        let theta = asin(min(max(-d.y, -1.0), 1.0))
        var u = 0.5 + phi / (2.0 * .pi)
        if u < 0.0 { u += 1.0 }
        if u >= 1.0 { u -= 1.0 }
        let v = min(max(0.5 - theta / .pi, 0.0), 1.0)
        return SIMD2<Double>(u, v)
    }
}
