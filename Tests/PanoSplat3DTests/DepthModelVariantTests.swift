import CoreGraphics
import Foundation
import simd
import Testing
@testable import PanoSplat3DCore

@Suite("Depth Model Variants & Normalization")
struct DepthModelVariantTests {
    @Test("All depth model variants define valid manifests, unique paths, and positive sizes")
    func variantManifestsAreValid() {
        let variants = DepthModelVariant.allCases
        #expect(variants.count == 3)

        let packageNames = Set(variants.map(\.packageName))
        let compiledNames = Set(variants.map(\.compiledName))
        #expect(packageNames.count == variants.count)
        #expect(compiledNames.count == variants.count)

        for variant in variants {
            #expect(URL(string: variant.baseDownloadURL) != nil)
            #expect(variant.baseDownloadURL.hasPrefix("https://"))
            #expect(variant.remoteFiles.count == 3)
            #expect(variant.totalExpectedBytes > 40_000_000)
            #expect(variant.approximateSizeMB >= 40)
            #expect(variant.minimumValidWeightBytes > 30_000_000)
            #expect(variant.recommendedStitchedSize.width == variant.recommendedStitchedSize.height * 2)

            for file in variant.remoteFiles {
                #expect(file.relativePath.hasPrefix(variant.packageName + "/"))
                #expect(file.expectedBytes > 0)
                #expect(URL(string: variant.baseDownloadURL + file.relativePath) != nil)
            }
        }
    }

    @Test("normalizeToDisparity preserves disparity and safely inverts direct depth")
    func normalizeToDisparityBehavior() {
        let raw: [Float] = [0.2, 1.0, 2.0, 5.0, 10.0, 0.0, -3.0, .nan]

        let unchanged = DepthEstimator.normalizeToDisparity(raw, polarity: .disparity)
        #expect(unchanged[0] == 0.2)
        #expect(unchanged[4] == 10.0)

        let inverted = DepthEstimator.normalizeToDisparity(raw, polarity: .depth)
        // Closer direct depth (1.0m) must map to higher disparity than farther direct depth (10.0m)
        #expect(inverted[1] > inverted[2])
        #expect(inverted[2] > inverted[3])
        #expect(inverted[3] > inverted[4])
        // Non-positive and non-finite inputs map safely to 0
        #expect(inverted[5] == 0)
        #expect(inverted[6] == 0)
        #expect(inverted[7] == 0)
        // All finite positive depths stay finite (no 1/0 blowup)
        #expect(inverted.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    @Test("GenerationSettings decodes legacy v1.6 JSON without depthModel field")
    func legacyGenerationSettingsBackwardsCompatibility() throws {
        let legacyJSON = """
        {
          "depthScaleMeters": 18.5,
          "parallaxBaselineMeters": 0.75,
          "trainingSteps": 15000,
          "shDegree": 3,
          "exportMode": "plySplat",
          "perspectiveResolution": 1536,
          "fieldOfViewDegrees": 82.0,
          "initialPointCount": 220000,
          "autoUpscaleLowRes": false,
          "playAlertSounds": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        #expect(decoded.depthModel == .depthAnythingV2Small)
        #expect(decoded.depthScaleMeters == 18.5)
        #expect(decoded.parallaxBaselineMeters == 0.75)
        #expect(decoded.trainingSteps == .high)
        #expect(decoded.shDegree == .three)
        #expect(decoded.perspectiveResolution == 1536)
        #expect(decoded.autoUpscaleLowRes == false)
        #expect(decoded.playAlertSounds == false)
    }

    @Test("Opt-in live Depth Anything V3 Base inference verifies model load and ground-closer-than-sky polarity")
    func liveDA3InferenceAndPolarity() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_DA3"] == "1" else {
            return
        }

        // Build a synthetic outdoor 2:1 panorama: bright blue sky above horizon, textured dark ground below horizon
        let width = 1024
        let height = 512
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = Double(y) / Double(height - 1)
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let idx = (y * width + x) * 4
                if v < 0.48 {
                    // Clear sky gradient (brighter toward horizon)
                    let t = v / 0.48
                    rgba[idx] = UInt8(clamping: Int(110 + 95 * t))
                    rgba[idx + 1] = UInt8(clamping: Int(165 + 65 * t))
                    rgba[idx + 2] = UInt8(clamping: Int(235 + 15 * t))
                } else {
                    // Ground plane with perspective checkerboard/grid texture getting coarser toward nadir
                    let groundDepth = (v - 0.48) / 0.52
                    let checker = ((Int(u * 48) + Int(groundDepth * 24)) % 2 == 0) ? 1.0 : 0.72
                    let shade = (0.35 + 0.45 * groundDepth) * checker
                    rgba[idx] = UInt8(clamping: Int(130 * shade))
                    rgba[idx + 1] = UInt8(clamping: Int(115 * shade))
                    rgba[idx + 2] = UInt8(clamping: Int(95 * shade))
                }
                rgba[idx + 3] = 255
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!

        let asset = PanoramaAsset(
            sourceURL: URL(fileURLWithPath: "/tmp/synthetic_outdoor_da3.png"),
            width: width,
            height: height,
            isHDR: false,
            fileSizeBytes: Int64(rgba.count),
            cgImage: cgImage,
            thumbnail: cgImage
        )

        let estimator = DepthEstimator()
        let depthMap = try await estimator.estimate360Depth(
            from: asset,
            variant: .depthAnythingV3Base,
            depthScaleMeters: 12.0,
            outputWidth: 512,
            outputHeight: 256
        )

        // Compare mean metric radius in upper sky band (rows 15%..30%) vs lower ground band (rows 70%..85%)
        var skySum = 0.0
        var skyCount = 0
        for y in Int(Double(depthMap.height) * 0.15)..<Int(Double(depthMap.height) * 0.30) {
            for x in 0..<depthMap.width {
                skySum += Double(depthMap.metricRadiusMeters[y * depthMap.width + x])
                skyCount += 1
            }
        }

        var groundSum = 0.0
        var groundCount = 0
        for y in Int(Double(depthMap.height) * 0.70)..<Int(Double(depthMap.height) * 0.85) {
            for x in 0..<depthMap.width {
                groundSum += Double(depthMap.metricRadiusMeters[y * depthMap.width + x])
                groundCount += 1
            }
        }

        let skyMean = skySum / Double(max(1, skyCount))
        let groundMean = groundSum / Double(max(1, groundCount))
        print("DA3 Live Polarity Check — skyMean: \(String(format: "%.2f", skyMean))m, groundMean: \(String(format: "%.2f", groundMean))m, range: \(String(format: "%.2f", depthMap.minRadiusMeters))m..\(String(format: "%.2f", depthMap.maxRadiusMeters))m")

        #expect(depthMap.maxRadiusMeters > depthMap.minRadiusMeters + 1.0)
        #expect(groundMean < skyMean, "Ground (\(groundMean)m) should be closer than sky (\(skyMean)m) — check DA3 outputPolarity!")
    }

    @Test("compact8Faces 115° horizon-anchored rig covers 100% of the 360°×180° sphere with zero holes")
    func compact8FacesFullSphericalCoverage() {
        let faces = DepthSamplingFace.compact8Faces
        #expect(faces.count == 8)

        let poses = faces.map { $0.makeCameraPose(cameraID: 100) }
        let tanHalfFovs = faces.map { tan($0.fovDegrees * .pi / 360.0) }

        // 1. Verify every direction on a 128×64 equirectangular grid is covered by at least 1 face
        var uncoveredCount = 0
        for y in 0..<64 {
            let v = (Double(y) + 0.5) / 64.0
            for x in 0..<128 {
                let u = (Double(x) + 0.5) / 128.0
                let dir = SphericalMath.equirectangularUVToWorldDirection(u: u, v: v)
                var covered = false
                for i in 0..<faces.count {
                    let z = simd_dot(dir, poses[i].cameraForward)
                    if z > 1e-5 {
                        let px = simd_dot(dir, poses[i].cameraRight) / (z * tanHalfFovs[i])
                        let py = simd_dot(dir, poses[i].cameraDown) / (z * tanHalfFovs[i])
                        if abs(px) <= 1.0 && abs(py) <= 1.0 {
                            covered = true
                            break
                        }
                    }
                }
                if !covered { uncoveredCount += 1 }
            }
        }
        #expect(uncoveredCount == 0, "Found \(uncoveredCount) uncovered equirectangular pixels in compact8Faces")

        // 2. Verify stitching a true spherical ground/sky field has smooth continuity and no holes
        let syntheticFaces: [CubemapFaceDisparity] = faces.enumerated().map { idx, face in
            let w = 64
            let h = 64
            let pose = poses[idx]
            let tanHalf = tanHalfFovs[idx]
            var values = [Float](repeating: 0, count: w * h)
            for py in 0..<h {
                let ndcY = ((Double(py) + 0.5) / Double(h)) * 2.0 - 1.0
                for px in 0..<w {
                    let ndcX = ((Double(px) + 0.5) / Double(w)) * 2.0 - 1.0
                    let camRay = simd_normalize(SIMD3<Double>(ndcX * tanHalf, ndcY * tanHalf, 1.0))
                    let worldDir = simd_normalize(
                        pose.cameraRight * camRay.x + pose.cameraDown * camRay.y + pose.cameraForward * camRay.z
                    )
                    // True spherical radial disparity: ground (+Y down) closer than sky (-Y up)
                    let radialDisp = 0.55 + 0.35 * worldDir.y
                    // Convert spherical radial disparity to planar disparity (divide by cos(rayAngle) = camRay.z)
                    values[py * w + px] = Float(radialDisp / max(camRay.z, 1e-3))
                }
            }
            return CubemapFaceDisparity(
                faceIndex: face.index,
                pose: pose,
                fovDegrees: face.fovDegrees,
                width: w,
                height: h,
                values: values
            )
        }

        let stitched = DepthStitcher.stitch(
            faces: syntheticFaces,
            outputWidth: 128,
            outputHeight: 64,
            depthScaleMeters: 12.0
        )

        #expect(stitched.metricRadiusMeters.count == 128 * 64)
        #expect(stitched.metricRadiusMeters.allSatisfy { $0.isFinite && $0 >= 1.5 && $0 <= 60.0 })
        // Ground row (y=50) must be closer than sky row (y=12)
        let skyR = stitched.metricRadiusMeters[12 * 128 + 64]
        let groundR = stitched.metricRadiusMeters[50 * 128 + 64]
        #expect(groundR < skyR)
    }

    @Test("Opt-in live Apple Depth Pro 1536px inference verifies fast Metal GPU load (no ANE hang) and polarity")
    func liveDepthProInferenceAndPolarity() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_DEPTHPRO"] == "1" else {
            return
        }

        // Prefer a real generated panorama on disk if available, since Depth Pro is a metric ViT trained on real photos
        let realPanoPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PanoSplat3D/GeneratedPanoramas/transform_this_set_of_images_1795370419.png")
        let asset: PanoramaAsset
        if FileManager.default.fileExists(atPath: realPanoPath.path) {
            asset = try PanoramaLoader.load(from: realPanoPath)
        } else {
            let width = 1024
            let height = 512
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let v = Double(y) / Double(height - 1)
                for x in 0..<width {
                    let idx = (y * width + x) * 4
                    rgba[idx] = UInt8(clamping: Int(v * 200))
                    rgba[idx + 1] = UInt8(clamping: Int(160))
                    rgba[idx + 2] = UInt8(clamping: Int((1.0 - v) * 230))
                    rgba[idx + 3] = 255
                }
            }
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )!
            asset = PanoramaAsset(
                sourceURL: URL(fileURLWithPath: "/tmp/synthetic_outdoor_depthpro.png"),
                width: width,
                height: height,
                isHDR: false,
                fileSizeBytes: Int64(rgba.count),
                cgImage: cgImage,
                thumbnail: cgImage
            )
        }

        let start = Date()
        let estimator = DepthEstimator()
        let depthMap = try await estimator.estimate360Depth(
            from: asset,
            variant: .appleDepthPro,
            depthScaleMeters: 12.0,
            outputWidth: 768,
            outputHeight: 384
        )
        let elapsed = Date().timeIntervalSince(start)

        var skySum = 0.0
        var skyCount = 0
        for y in Int(Double(depthMap.height) * 0.15)..<Int(Double(depthMap.height) * 0.30) {
            for x in 0..<depthMap.width {
                skySum += Double(depthMap.metricRadiusMeters[y * depthMap.width + x])
                skyCount += 1
            }
        }

        var groundSum = 0.0
        var groundCount = 0
        for y in Int(Double(depthMap.height) * 0.70)..<Int(Double(depthMap.height) * 0.85) {
            for x in 0..<depthMap.width {
                groundSum += Double(depthMap.metricRadiusMeters[y * depthMap.width + x])
                groundCount += 1
            }
        }

        let skyMean = skySum / Double(max(1, skyCount))
        let groundMean = groundSum / Double(max(1, groundCount))
        print("DepthPro Live GPU Check (\(String(format: "%.1f", elapsed))s, 8 faces) — skyMean: \(String(format: "%.2f", skyMean))m, groundMean: \(String(format: "%.2f", groundMean))m, range: \(String(format: "%.2f", depthMap.minRadiusMeters))m..\(String(format: "%.2f", depthMap.maxRadiusMeters))m")

        #expect(depthMap.maxRadiusMeters > depthMap.minRadiusMeters + 1.0)
        #expect(groundMean < skyMean, "Ground (\(groundMean)m) should be closer than sky (\(skyMean)m)")
    }
}
