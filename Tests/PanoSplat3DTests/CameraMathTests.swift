import Foundation
import Testing
import simd
@testable import PanoSplat3DCore

@Suite("Camera & Spherical Coordinate Math (COLMAP RDF <-> SuperSplat / UE5 Upright)")
struct CameraMathTests {
    @Test("Equirectangular cardinal directions map to standard COLMAP RDF (+X right, +Y down, +Z forward)")
    func cardinalDirections() {
        let forward = SphericalMath.equirectangularUVToWorldDirection(u: 0.5, v: 0.5)
        #expect(simd_distance(forward, SIMD3<Double>(0, 0, 1)) < 1e-6)

        let right = SphericalMath.equirectangularUVToWorldDirection(u: 0.75, v: 0.5)
        #expect(simd_distance(right, SIMD3<Double>(1, 0, 0)) < 1e-6)

        let left = SphericalMath.equirectangularUVToWorldDirection(u: 0.25, v: 0.5)
        #expect(simd_distance(left, SIMD3<Double>(-1, 0, 0)) < 1e-6)

        let back = SphericalMath.equirectangularUVToWorldDirection(u: 0.0, v: 0.5)
        #expect(simd_distance(back, SIMD3<Double>(0, 0, -1)) < 1e-6)

        let zenith = SphericalMath.equirectangularUVToWorldDirection(u: 0.5, v: 0.0)
        #expect(simd_distance(zenith, SIMD3<Double>(0, -1, 0)) < 1e-6)

        let nadir = SphericalMath.equirectangularUVToWorldDirection(u: 0.5, v: 1.0)
        #expect(simd_distance(nadir, SIMD3<Double>(0, 1, 0)) < 1e-6)
    }

    @Test("Equirectangular UV <-> World Direction round-trip")
    func uvRoundTrip() {
        for u in stride(from: 0.05, through: 0.95, by: 0.15) {
            for v in stride(from: 0.1, through: 0.9, by: 0.2) {
                let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)
                let uv = SphericalMath.worldDirectionToEquirectangularUV(dir)
                #expect(abs(uv.x - u) < 1e-6)
                #expect(abs(uv.y - v) < 1e-6)
            }
        }
    }

    @Test("All center rig poses are proper SO(3) rotations and quaternion matches R_cw")
    func centerRigOrthonormalityAndQuaternion() {
        let poses = CameraRigGenerator.makeCenterSphericalRig()
        #expect(poses.count == 20)

        // Forward camera (yaw=0, pitch=0) has exact identity rotation R_cw = I in standard COLMAP RDF
        let forwardQ = poses[0].colmapQuaternion
        #expect(abs(forwardQ.qw - 1.0) < 1e-6)
        #expect(abs(forwardQ.qx) < 1e-6)
        #expect(abs(forwardQ.qy) < 1e-6)
        #expect(abs(forwardQ.qz) < 1e-6)

        let testVector = SIMD3<Double>(1.5, -2.25, 4.0)

        for pose in poses {
            let r = pose.worldToCameraRotation
            let det = simd_determinant(r)
            #expect(abs(det - 1.0) < 1e-6)

            let qTuple = pose.colmapQuaternion
            let q = simd_quatd(ix: qTuple.qx, iy: qTuple.qy, iz: qTuple.qz, r: qTuple.qw)
            let norm = sqrt(qTuple.qw * qTuple.qw + qTuple.qx * qTuple.qx + qTuple.qy * qTuple.qy + qTuple.qz * qTuple.qz)
            #expect(abs(norm - 1.0) < 1e-6)

            let rotatedByMatrix = r * testVector
            let rotatedByQuat = q.act(testVector)
            #expect(simd_distance(rotatedByMatrix, rotatedByQuat) < 1e-6)
        }
    }

    @Test("COLMAP projection maps +X Right and -Y Up (Zenith) world point to upper-right image quadrant")
    func colmapProjectionSignHygiene() {
        let intrinsics = PinholeCameraIntrinsics(width: 1000, height: 1000, fovDegrees: 90.0)
        #expect(abs(intrinsics.focalLength - 500.0) < 1e-6)

        let forwardPose = VirtualCameraPose(
            imageID: 1,
            name: "view_000.png",
            worldPosition: SIMD3<Double>(0, 0, 0),
            yawDegrees: 0,
            pitchDegrees: 0
        )

        // Point 1m right (+X), 2m UP (-Y in COLMAP RDF), 10m forward (+Z)
        let worldPt = SIMD3<Double>(1.0, -2.0, 10.0)
        let projected = forwardPose.project(worldPt, intrinsics: intrinsics)
        #expect(projected != nil)
        if let px = projected {
            // u = 500 + 500*(1/10) = 550 (right of center)
            // v = 500 + 500*(-2/10) = 400 (above center in top-left image coordinates)
            #expect(abs(px.x - 550.0) < 1e-6)
            #expect(abs(px.y - 400.0) < 1e-6)
        }
    }

    @Test("Translated camera pose satisfies t_cw = -R_cw * C_w")
    func translatedPoseExtrinsics() {
        let center = SIMD3<Double>(0.75, -0.20, 0.5)
        let pose = VirtualCameraPose(
            imageID: 2,
            name: "view_001.png",
            worldPosition: center,
            yawDegrees: 60.0,
            pitchDegrees: 15.0
        )
        let reconstructedCenter = -(pose.cameraToWorldRotation * pose.colmapTranslation)
        #expect(simd_distance(reconstructedCenter, center) < 1e-6)

        let centerInCam = pose.worldToCamera(center)
        #expect(simd_length(centerInCam) < 1e-6)
    }
}
