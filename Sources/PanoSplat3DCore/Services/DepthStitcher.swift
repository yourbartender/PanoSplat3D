import Foundation
import simd

/// 12 overlapping wide-FOV (`105°`) perspective faces covering the entire 360° × 180° sphere
/// with 40°–50° overlap between neighbors and **no isolated nadir/zenith faces**.
///
/// Every face includes horizon/midground context (`0°`, `+45°`, and `-45°` pitch at `105°` FOV reaches
/// `±97.5°` past both poles while still seeing the horizon), eliminating the classic cubemap `±45°`
/// edge steps and bright ground-triangle artifacts.
public struct DepthSamplingFace: Sendable, Equatable {
    public let index: Int
    public let label: String
    public let yawDegrees: Double
    public let pitchDegrees: Double
    public let fovDegrees: Double

    public init(index: Int, label: String, yawDegrees: Double, pitchDegrees: Double, fovDegrees: Double = 105.0) {
        self.index = index
        self.label = label
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.fovDegrees = fovDegrees
    }

    public func makeCameraPose(cameraID: Int = 100) -> VirtualCameraPose {
        VirtualCameraPose(
            imageID: index + 1,
            name: "depth_face_\(String(format: "%02d", index)).png",
            cameraID: cameraID,
            worldPosition: .zero,
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees
        )
    }

    /// Standard 12-face horizon-anchored wide-overlap depth rig:
    /// - 6 horizon faces (`pitch = 0°`, every `60°` yaw, `105°` FOV → `45°` horizontal overlap)
    /// - 3 upper faces (`pitch = +45°`, every `120°` yaw, `105°` FOV → reaches past zenith `+97.5°` AND overlaps horizon)
    /// - 3 lower faces (`pitch = -45°`, every `120°` yaw, `105°` FOV → reaches past nadir `-97.5°` AND sees horizon/trees)
    public static let standard12Faces: [DepthSamplingFace] = {
        var faces: [DepthSamplingFace] = []
        for i in 0..<6 {
            let yaw = Double(i) * 60.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Horizon \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: 0.0, fovDegrees: 105.0))
        }
        for i in 0..<3 {
            let yaw = 30.0 + Double(i) * 120.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Upper \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: 45.0, fovDegrees: 105.0))
        }
        for i in 0..<3 {
            let yaw = 90.0 + Double(i) * 120.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Lower \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: -45.0, fovDegrees: 105.0))
        }
        return faces
    }()

    /// Compact 8-face horizon-anchored wide-overlap rig (`115°` FOV) for very heavy `1536×1536` models (Apple Depth Pro).
    /// Covers 100% of the 360°×180° sphere with ≥25° overlap everywhere and zero isolated nadir/zenith faces,
    /// cutting inference time by 33% compared to 12 faces.
    public static let compact8Faces: [DepthSamplingFace] = {
        var faces: [DepthSamplingFace] = []
        for i in 0..<4 {
            let yaw = Double(i) * 90.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Horizon \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: 0.0, fovDegrees: 115.0))
        }
        for i in 0..<2 {
            let yaw = 45.0 + Double(i) * 180.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Upper \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: 48.0, fovDegrees: 115.0))
        }
        for i in 0..<2 {
            let yaw = 135.0 + Double(i) * 180.0
            faces.append(DepthSamplingFace(index: faces.count, label: "Lower \(Int(yaw))°", yawDegrees: yaw, pitchDegrees: -48.0, fovDegrees: 115.0))
        }
        return faces
    }()
}

/// Legacy 6-face enum retained for backwards compatibility with unit tests & external callers.
public enum CubemapFaceKind: Int, CaseIterable, Sendable {
    case front = 0
    case right = 1
    case back = 2
    case left = 3
    case up = 4
    case down = 5

    public var label: String {
        switch self {
        case .front: return "Front"
        case .right: return "Right"
        case .back: return "Back"
        case .left: return "Left"
        case .up: return "Up"
        case .down: return "Down"
        }
    }

    public var yawDegrees: Double {
        switch self {
        case .front: return 0
        case .right: return 90
        case .back: return 180
        case .left: return -90
        case .up: return 0
        case .down: return 0
        }
    }

    public var pitchDegrees: Double {
        switch self {
        case .front, .right, .back, .left: return 0
        case .up: return 90
        case .down: return -90
        }
    }

    public func makeCameraPose(cameraID: Int = 100) -> VirtualCameraPose {
        VirtualCameraPose(
            imageID: rawValue + 1,
            name: "depth_face_\(label.lowercased()).png",
            cameraID: cameraID,
            worldPosition: .zero,
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees
        )
    }
}

/// Raw monocular disparity buffer predicted on a single perspective face.
public struct CubemapFaceDisparity: Sendable {
    public let faceIndex: Int
    public let pose: VirtualCameraPose
    public let fovDegrees: Double
    public let width: Int
    public let height: Int
    /// Planar relative disparity values (higher = closer to camera), row-major top-to-bottom.
    public let values: [Float]

    public init(
        faceIndex: Int,
        pose: VirtualCameraPose,
        fovDegrees: Double = 105.0,
        width: Int,
        height: Int,
        values: [Float]
    ) {
        self.faceIndex = faceIndex
        self.pose = pose
        self.fovDegrees = fovDegrees
        self.width = width
        self.height = height
        self.values = values
    }

    public init(
        face: CubemapFaceKind,
        pose: VirtualCameraPose,
        fovDegrees: Double = 95.0,
        width: Int,
        height: Int,
        values: [Float]
    ) {
        self.faceIndex = face.rawValue
        self.pose = pose
        self.fovDegrees = fovDegrees
        self.width = width
        self.height = height
        self.values = values
    }
}

/// Aligns scale & shift across arbitrary overlapping perspective faces (e.g. 12 wide-FOV faces or 6 cubemap faces)
/// via global least-squares with **zero per-face bias** (pinning only global mean scale & shift),
/// and blends them with wide raised-cosine feathering into a seamless 360° equirectangular metric depth buffer `R(u, v)`.
public enum DepthStitcher {
    public static let minMetricRadiusMeters: Double = 1.5
    public static let maxMetricRadiusMeters: Double = 60.0

    /// Stitches `N` overlapping perspective face disparity maps into a seamless equirectangular depth map.
    public static func stitch(
        faces: [CubemapFaceDisparity],
        outputWidth: Int = 1024,
        outputHeight: Int = 512,
        depthScaleMeters: Double = 12.0
    ) -> EquirectangularDepthMap {
        let orderedFaces = faces.sorted { $0.faceIndex < $1.faceIndex }
        let faceCount = orderedFaces.count
        precondition(faceCount >= 6, "DepthStitcher requires at least 6 overlapping faces.")

        // 1. Convert each face's planar Z-disparity to spherical radial inverse-distance:
        //    d_radial = d_planar * cos(angle_from_optical_axis)
        var radialFaces: [[Float]] = []
        radialFaces.reserveCapacity(faceCount)
        var tanHalfFovs: [Double] = []
        tanHalfFovs.reserveCapacity(faceCount)

        for face in orderedFaces {
            let tanHalf = tan((face.fovDegrees * 0.5) * (.pi / 180.0))
            tanHalfFovs.append(tanHalf)
            radialFaces.append(convertPlanarToRadialAndNormalize(face: face, tanHalfFov: tanHalf))
        }

        // 2. Solve global 2N-variable least-squares alignment (scale s_i, shift b_i) across all overlapping regions
        //    using a pure global-mean gauge constraint so individual faces can freely match each other with zero step!
        let (scales, shifts) = solveGlobalScaleShiftAlignment(
            faces: orderedFaces,
            radialValues: radialFaces,
            tanHalfFovs: tanHalfFovs
        )

        // 3. Blend aligned faces onto a seamless 2:1 equirectangular disparity buffer D(u, v)
        //    using wide cosine-squared feathering over the outer 35% of each face (matching 40°+ overlap).
        let pixelCount = outputWidth * outputHeight
        var equirectDisparity = [Float](repeating: 0, count: pixelCount)
        let featherBand = faceCount >= 10 ? 0.35 : 0.12

        for y in 0..<outputHeight {
            let v = (Double(y) + 0.5) / Double(outputHeight)
            let rowOffset = y * outputWidth
            for x in 0..<outputWidth {
                let u = (Double(x) + 0.5) / Double(outputWidth)
                let worldDir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)

                var weightedSum = 0.0
                var totalWeight = 0.0

                for i in 0..<faceCount {
                    let face = orderedFaces[i]
                    guard let uv = projectDirectionToFaceUV(
                        worldDir: worldDir,
                        pose: face.pose,
                        tanHalfFov: tanHalfFovs[i]
                    ) else {
                        continue
                    }

                    // Separable smooth raised-cosine feather on both X and Y borders
                    let marginX = min(uv.x, 1.0 - uv.x)
                    let marginY = min(uv.y, 1.0 - uv.y)
                    let tx = min(max(marginX / featherBand, 0.0), 1.0)
                    let ty = min(max(marginY / featherBand, 0.0), 1.0)
                    let wx = 0.5 - 0.5 * cos(tx * .pi)
                    let wy = 0.5 - 0.5 * cos(ty * .pi)
                    let weight = max((wx * wy) * (wx * wy), 1e-6)

                    let sampledRadial = sampleBilinear(
                        values: radialFaces[i],
                        width: face.width,
                        height: face.height,
                        u: uv.x,
                        v: uv.y
                    )
                    let alignedValue = scales[i] * sampledRadial + shifts[i]

                    weightedSum += weight * alignedValue
                    totalWeight += weight
                }

                equirectDisparity[rowOffset + x] = totalWeight > 0 ? Float(weightedSum / totalWeight) : 0
            }
        }

        // 4. Convert seamless relative disparity D(u, v) to bounded metric radius R(u, v) in [1.5m, 60.0m].
        let metricRadius = convertDisparityToMetricRadius(
            disparity: equirectDisparity,
            depthScaleMeters: depthScaleMeters
        )

        return EquirectangularDepthMap(
            width: outputWidth,
            height: outputHeight,
            disparity: equirectDisparity,
            metricRadiusMeters: metricRadius
        )
    }

    /// Converts planar perspective Z-disparity `d_z ~ 1/Z` to radial spherical inverse-distance `d_r ~ 1/R`
    /// via `d_r = d_z * (d · f)` so overlapping faces agree geometrically across the entire overlap band.
    private static func convertPlanarToRadialAndNormalize(
        face: CubemapFaceDisparity,
        tanHalfFov: Double
    ) -> [Float] {
        let w = face.width
        let h = face.height
        let count = w * h
        var radial = [Float](repeating: 0, count: count)

        for y in 0..<h {
            let ny = (2.0 * ((Double(y) + 0.5) / Double(h)) - 1.0) * tanHalfFov
            let rowOffset = y * w
            for x in 0..<w {
                let nx = (2.0 * ((Double(x) + 0.5) / Double(w)) - 1.0) * tanHalfFov
                let cosGamma = Float(1.0 / sqrt(1.0 + nx * nx + ny * ny))
                let raw = face.values[rowOffset + x]
                radial[rowOffset + x] = max(raw, 0) * cosGamma
            }
        }

        let strideStep = max(1, count / 2048)
        var samples: [Float] = []
        samples.reserveCapacity(2048)
        var idx = 0
        while idx < count {
            let val = radial[idx]
            if val.isFinite {
                samples.append(val)
            }
            idx += strideStep
        }
        samples.sort()

        guard !samples.isEmpty else { return radial }
        let p02 = samples[Int(Double(samples.count - 1) * 0.02)]
        let p98 = samples[Int(Double(samples.count - 1) * 0.98)]
        let span = max(p98 - p02, 1e-4)

        for i in 0..<count {
            let val = radial[i].isFinite ? radial[i] : p02
            radial[i] = (val - p02) / span
        }
        return radial
    }

    private static func projectDirectionToFaceUV(
        worldDir: SIMD3<Double>,
        pose: VirtualCameraPose,
        tanHalfFov: Double
    ) -> SIMD2<Double>? {
        let z = simd_dot(worldDir, pose.cameraForward)
        guard z > 1e-5 else { return nil }

        let x = simd_dot(worldDir, pose.cameraRight) / (z * tanHalfFov)
        let y = simd_dot(worldDir, pose.cameraDown) / (z * tanHalfFov)
        guard abs(x) <= 1.0, abs(y) <= 1.0 else { return nil }

        return SIMD2<Double>(0.5 * (x + 1.0), 0.5 * (y + 1.0))
    }

    /// Solves the 2N×2N least-squares system aligning `(s_i * d_i + b_i) ≈ (s_j * d_j + b_j)` across all
    /// overlapping regions, using a **global-mean gauge constraint** `(mean(s) = 1, mean(b) = 0)` so
    /// individual faces with narrower depth ranges can freely scale/shift without seam steps.
    private static func solveGlobalScaleShiftAlignment(
        faces: [CubemapFaceDisparity],
        radialValues: [[Float]],
        tanHalfFovs: [Double]
    ) -> (scales: [Double], shifts: [Double]) {
        let faceCount = faces.count
        let n = 2 * faceCount // [s0, b0, s1, b1, ..., s_{N-1}, b_{N-1}]
        var matrix = [Double](repeating: 0.0, count: n * n)
        var rhs = [Double](repeating: 0.0, count: n)
        var totalCorrespondenceWeight = 0.0

        // Dense spherical sampling grid covering all overlapping face regions
        let latSteps = 72
        let lonSteps = 144

        for yi in 0..<latSteps {
            let v = (Double(yi) + 0.5) / Double(latSteps)
            let sinTheta = max(sin(v * .pi), 0.05)
            for xi in 0..<lonSteps {
                let u = (Double(xi) + 0.5) / Double(lonSteps)
                let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)

                var observations: [(faceIdx: Int, value: Double, interiorWeight: Double)] = []
                observations.reserveCapacity(4)

                for i in 0..<faceCount {
                    if let uv = projectDirectionToFaceUV(
                        worldDir: dir,
                        pose: faces[i].pose,
                        tanHalfFov: tanHalfFovs[i]
                    ) {
                        let margin = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y))
                        if margin > 0.01 {
                            let val = sampleBilinear(
                                values: radialValues[i],
                                width: faces[i].width,
                                height: faces[i].height,
                                u: uv.x,
                                v: uv.y
                            )
                            let interiorW = min(margin / 0.10, 1.0)
                            observations.append((i, val, interiorW))
                        }
                    }
                }

                guard observations.count >= 2 else { continue }

                for a in 0..<observations.count {
                    for b in (a + 1)..<observations.count {
                        let i = observations[a].faceIdx
                        let j = observations[b].faceIdx
                        let vi = observations[a].value
                        let vj = observations[b].value
                        let w = sinTheta * observations[a].interiorWeight * observations[b].interiorWeight

                        let indices = [2 * i, 2 * i + 1, 2 * j, 2 * j + 1]
                        let coeffs = [vi, 1.0, -vj, -1.0]

                        for r in 0..<4 {
                            let row = indices[r] * n
                            let cr = w * coeffs[r]
                            for c in 0..<4 {
                                matrix[row + indices[c]] += cr * coeffs[c]
                            }
                        }
                        totalCorrespondenceWeight += w
                    }
                }
            }
        }

        // Pure global-mean gauge constraint:
        //   w_gauge * ( (1/N) * sum(s_i) - 1 )^2  +  w_gauge * ( (1/N) * sum(b_i) )^2
        // This eliminates the trivial zero solution WITHOUT pulling individual faces away from their true relative scale!
        let gaugeWeight = max(totalCorrespondenceWeight * 0.25, 10.0)
        let invN = 1.0 / Double(faceCount)
        let gaugeCoeffSq = gaugeWeight * invN * invN

        for i in 0..<faceCount {
            let si = 2 * i
            let bi = 2 * i + 1
            rhs[si] += gaugeWeight * invN
            for j in 0..<faceCount {
                let sj = 2 * j
                let bj = 2 * j + 1
                matrix[si * n + sj] += gaugeCoeffSq
                matrix[bi * n + bj] += gaugeCoeffSq
            }
        }

        // Microscopic Tikhonov stabilizer only to guarantee invertibility on completely uniform images (e.g. blank test frames)
        let tinyRidge = max(totalCorrespondenceWeight * 1e-6, 1e-4)
        for i in 0..<faceCount {
            let si = 2 * i
            let bi = 2 * i + 1
            matrix[si * n + si] += tinyRidge
            rhs[si] += tinyRidge * 1.0
            matrix[bi * n + bi] += tinyRidge
        }

        guard let solution = solveLinearSystem(matrix: matrix, rhs: rhs, size: n) else {
            return (Array(repeating: 1.0, count: faceCount), Array(repeating: 0.0, count: faceCount))
        }

        var scales = [Double](repeating: 1.0, count: faceCount)
        var shifts = [Double](repeating: 0.0, count: faceCount)
        for i in 0..<faceCount {
            scales[i] = min(max(solution[2 * i], 0.05), 10.0)
            shifts[i] = solution[2 * i + 1]
        }
        return (scales, shifts)
    }

    private static func solveLinearSystem(matrix: [Double], rhs: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var b = rhs

        for col in 0..<n {
            var pivotRow = col
            var maxAbs = abs(a[col * n + col])
            for row in (col + 1)..<n {
                let candidate = abs(a[row * n + col])
                if candidate > maxAbs {
                    maxAbs = candidate
                    pivotRow = row
                }
            }
            guard maxAbs > 1e-12 else { return nil }

            if pivotRow != col {
                for k in col..<n {
                    a.swapAt(col * n + k, pivotRow * n + k)
                }
                b.swapAt(col, pivotRow)
            }

            let pivot = a[col * n + col]
            for row in (col + 1)..<n {
                let factor = a[row * n + col] / pivot
                a[row * n + col] = 0.0
                for k in (col + 1)..<n {
                    a[row * n + k] -= factor * a[col * n + k]
                }
                b[row] -= factor * b[col]
            }
        }

        var x = [Double](repeating: 0.0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row * n + k] * x[k]
            }
            x[row] = sum / a[row * n + row]
        }
        return x
    }

    private static func convertDisparityToMetricRadius(
        disparity: [Float],
        depthScaleMeters: Double
    ) -> [Float] {
        guard !disparity.isEmpty else { return [] }

        let strideStep = max(1, disparity.count / 8192)
        var samples: [Float] = []
        samples.reserveCapacity(8192)
        var idx = 0
        while idx < disparity.count {
            let v = disparity[idx]
            if v.isFinite {
                samples.append(v)
            }
            idx += strideStep
        }
        samples.sort()

        let pLow = Double(samples.isEmpty ? 0 : samples[Int(Double(samples.count - 1) * 0.02)])
        let pHigh = Double(samples.isEmpty ? 1 : samples[Int(Double(samples.count - 1) * 0.98)])
        let span = max(pHigh - pLow, 1e-5)

        let rNear = min(max(depthScaleMeters * 0.22, minMetricRadiusMeters), 20.0)
        let rFar = min(max(depthScaleMeters * 3.8, rNear + 2.5), maxMetricRadiusMeters)
        let invNear = 1.0 / rNear
        let invFar = 1.0 / rFar
        let invSpan = invNear - invFar

        var radii = [Float](repeating: Float(depthScaleMeters), count: disparity.count)
        for i in 0..<disparity.count {
            let d = disparity[i].isFinite ? Double(disparity[i]) : pLow
            let t = min(max((d - pLow) / span, 0.0), 1.0)
            let invR = invFar + t * invSpan
            let radius = min(max(1.0 / max(invR, 1e-6), minMetricRadiusMeters), maxMetricRadiusMeters)
            radii[i] = Float(radius)
        }
        return radii
    }

    private static func sampleBilinear(
        values: [Float],
        width: Int,
        height: Int,
        u: Double,
        v: Double
    ) -> Double {
        let fx = u * Double(width) - 0.5
        let fy = v * Double(height) - 0.5

        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let tx = fx - Double(x0)
        let ty = fy - Double(y0)

        let cx0 = min(max(x0, 0), width - 1)
        let cx1 = min(max(x0 + 1, 0), width - 1)
        let cy0 = min(max(y0, 0), height - 1)
        let cy1 = min(max(y0 + 1, 0), height - 1)

        let v00 = Double(values[cy0 * width + cx0])
        let v10 = Double(values[cy0 * width + cx1])
        let v01 = Double(values[cy1 * width + cx0])
        let v11 = Double(values[cy1 * width + cx1])

        let top = v00 * (1.0 - tx) + v10 * tx
        let bottom = v01 * (1.0 - tx) + v11 * tx
        return top * (1.0 - ty) + bottom * ty
    }
}
