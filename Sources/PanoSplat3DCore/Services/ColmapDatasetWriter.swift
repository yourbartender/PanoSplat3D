import Foundation
import simd

/// Progress update emitted during COLMAP dataset generation.
public struct DatasetProgress: Sendable {
    public let fraction: Double
    public let stageTitle: String
    public let detail: String

    public init(fraction: Double, stageTitle: String, detail: String) {
        self.fraction = min(max(fraction, 0.0), 1.0)
        self.stageTitle = stageTitle
        self.detail = detail
    }
}

/// Summary of a generated COLMAP dataset folder.
public struct ColmapDatasetResult: Sendable, Equatable {
    public let datasetDirectory: URL
    public let imagesDirectory: URL
    public let masksDirectory: URL?
    public let sparseDirectory: URL
    public let initPLYURL: URL
    public let imageCount: Int
    public let parallaxViewCount: Int
    public let pointCount: Int
    public let usedMetal: Bool
    public let usedDepthDisplacement: Bool
    public let minDepthMeters: Float?
    public let maxDepthMeters: Float?

    public init(
        datasetDirectory: URL,
        imagesDirectory: URL,
        masksDirectory: URL? = nil,
        sparseDirectory: URL,
        initPLYURL: URL,
        imageCount: Int,
        parallaxViewCount: Int = 0,
        pointCount: Int,
        usedMetal: Bool,
        usedDepthDisplacement: Bool = false,
        minDepthMeters: Float? = nil,
        maxDepthMeters: Float? = nil
    ) {
        self.datasetDirectory = datasetDirectory
        self.imagesDirectory = imagesDirectory
        self.masksDirectory = masksDirectory
        self.sparseDirectory = sparseDirectory
        self.initPLYURL = initPLYURL
        self.imageCount = imageCount
        self.parallaxViewCount = parallaxViewCount
        self.pointCount = pointCount
        self.usedMetal = usedMetal
        self.usedDepthDisplacement = usedDepthDisplacement
        self.minDepthMeters = minDepthMeters
        self.maxDepthMeters = maxDepthMeters
    }
}

/// Writes a complete COLMAP dataset (`images/`, `masks/`, `sparse/0/{cameras.txt, images.txt, points3D.txt}`, `init.ply`).
public final class ColmapDatasetWriter: Sendable {
    private let slicer: EquirectangularSlicer

    public init(slicer: EquirectangularSlicer = EquirectangularSlicer()) {
        self.slicer = slicer
    }

    /// Generates and writes the complete COLMAP dataset for the given equirectangular panorama.
    /// - When `depthMap` is provided:
    ///   - Displaces `init.ply` vertices by metric radius `R(u, v)` in `+Y Up` right-handed world space.
    ///   - Builds the 28-camera multi-position parallax rig (`12` center + `16` offset ring views when `parallaxBaselineMeters > 0.01`).
    ///   - Renders offset views via hardware Metal Z-buffer re-projection and writes disocclusion masks to `masks/view_XXX.png`.
    public func writeDataset(
        from panorama: PanoramaAsset,
        depthMap: EquirectangularDepthMap? = nil,
        to datasetDirectory: URL,
        settings: GenerationSettings,
        stagePrefixPointCloud: String = "2/4 Building Depth-Displaced Point Cloud...",
        stagePrefixCameras: String = "3/4 Rendering Multi-View Parallax Cameras & Occlusion Masks...",
        onProgress: @Sendable (DatasetProgress) -> Void = { _ in }
    ) throws -> ColmapDatasetResult {
        let fm = FileManager.default
        let imagesDir = datasetDirectory.appendingPathComponent("images", isDirectory: true)
        let sparseDir = datasetDirectory.appendingPathComponent("sparse/0", isDirectory: true)
        let initPLYURL = datasetDirectory.appendingPathComponent("init.ply")

        // Clean stale images/masks in target folder if overwriting an existing dataset directory
        if fm.fileExists(atPath: imagesDir.path) {
            try? fm.removeItem(at: imagesDir)
        }
        let masksDir = datasetDirectory.appendingPathComponent("masks", isDirectory: true)
        if fm.fileExists(atPath: masksDir.path) {
            try? fm.removeItem(at: masksDir)
        }

        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparseDir, withIntermediateDirectories: true)

        let intrinsics = PinholeCameraIntrinsics(
            cameraID: 1,
            width: settings.perspectiveResolution,
            height: settings.perspectiveResolution,
            fovDegrees: settings.fieldOfViewDegrees
        )

        // Clamp parallax baseline safely inside the closest surface radius so offset cameras never clip near geometry
        let safeBaseline: Double
        if let depthMap {
            let maxSafeBaseline = max(0.0, Double(depthMap.minRadiusMeters) * 0.40)
            safeBaseline = min(settings.parallaxBaselineMeters, maxSafeBaseline)
        } else {
            safeBaseline = 0.0
        }

        let poses = (depthMap != nil)
            ? CameraRigGenerator.makeParallaxRig(baselineMeters: safeBaseline, cameraID: intrinsics.cameraID)
            : CameraRigGenerator.makeCenterSphericalRig(cameraID: intrinsics.cameraID)

        let centerPoses = poses.filter { simd_length($0.worldPosition) < 1e-5 }
        let offsetPoses = poses.filter { simd_length($0.worldPosition) >= 1e-5 }
        let writeMasks = (depthMap != nil && !offsetPoses.isEmpty)

        if writeMasks {
            try fm.createDirectory(at: masksDir, withIntermediateDirectories: true)
        }

        // 1. Generate gradient-importance-sampled 3D point cloud (depth-displaced when depthMap is provided)
        try Task.checkCancellation()
        let radiusDetail = depthMap.map {
            String(
                format: "Importance-sampling %@ points (%.1fm – %.1fm metric depth)",
                settings.initialPointCount.formatted(),
                $0.minRadiusMeters,
                $0.maxRadiusMeters
            )
        } ?? "Importance-sampling \(settings.initialPointCount.formatted()) points at \(String(format: "%.1fm", settings.depthScaleMeters)) radius"

        onProgress(DatasetProgress(
            fraction: 0.05,
            stageTitle: stagePrefixPointCloud,
            detail: radiusDetail
        ))

        let fallbackRadius = settings.depthScaleMeters
        let seedBgLayer = (depthMap != nil && !offsetPoses.isEmpty && settings.inpaintParallaxHoles)
        let points = PointCloudGenerator.generate(
            from: panorama.cgImage,
            targetPointCount: settings.initialPointCount,
            radiusAtUV: { u, v in
                depthMap?.radius(u: u, v: v) ?? fallbackRadius
            },
            seedBackgroundBehindOccluders: seedBgLayer
        )

        try Task.checkCancellation()
        onProgress(DatasetProgress(
            fraction: 0.22,
            stageTitle: stagePrefixPointCloud,
            detail: "Writing init.ply (\(points.count.formatted()) vertices)"
        ))
        try PLYWriter.write(points: points, to: initPLYURL)

        // 2. Render center-origin views with Metal equirectangular slicer (and solid white masks when masks/ is enabled)
        let totalViews = poses.count
        var renderedSoFar = 0
        let solidWhiteMask = writeMasks
            ? try ParallaxReprojector.makeSolidWhiteMask(width: intrinsics.width, height: intrinsics.height)
            : nil

        onProgress(DatasetProgress(
            fraction: 0.26,
            stageTitle: stagePrefixCameras,
            detail: "Slicing \(centerPoses.count) center views at \(intrinsics.width)×\(intrinsics.height)..."
        ))

        try slicer.sliceViews(
            from: panorama.cgImage,
            poses: centerPoses,
            intrinsics: intrinsics
        ) { index, _, viewImage in
            try Task.checkCancellation()
            let pose = centerPoses[index]
            try EquirectangularSlicer.writePNG(viewImage, to: imagesDir.appendingPathComponent(pose.name))
            if let solidWhiteMask {
                try EquirectangularSlicer.writePNG(solidWhiteMask, to: masksDir.appendingPathComponent(pose.name))
            }

            renderedSoFar += 1
            let viewFrac = Double(renderedSoFar) / Double(max(totalViews, 1))
            onProgress(DatasetProgress(
                fraction: 0.26 + 0.66 * viewFrac,
                stageTitle: stagePrefixCameras,
                detail: "Center view \(pose.name) (\(renderedSoFar) / \(totalViews))"
            ))
        }

        // 3. Render multi-position offset views via Metal Z-buffer parallax re-projection + disocclusion masks
        if let depthMap, !offsetPoses.isEmpty {
            let reprojector = try ParallaxReprojector()
            try reprojector.reprojectViews(
                panoramaImage: panorama.cgImage,
                depthMap: depthMap,
                poses: offsetPoses,
                intrinsics: intrinsics
            ) { index, _, result in
                try Task.checkCancellation()
                let pose = offsetPoses[index]
                try EquirectangularSlicer.writePNG(result.colorImage, to: imagesDir.appendingPathComponent(pose.name))
                try EquirectangularSlicer.writePNG(result.maskImage, to: masksDir.appendingPathComponent(pose.name))

                renderedSoFar += 1
                let viewFrac = Double(renderedSoFar) / Double(max(totalViews, 1))
                let validPct = Int((result.validPixelFraction * 100.0).rounded())
                onProgress(DatasetProgress(
                    fraction: 0.26 + 0.66 * viewFrac,
                    stageTitle: stagePrefixCameras,
                    detail: "Parallax view \(pose.name) (\(renderedSoFar) / \(totalViews), \(validPct)% unoccluded)"
                ))
            }
        }

        // 4. Write COLMAP sparse/0/{cameras.txt, images.txt, points3D.txt}
        try Task.checkCancellation()
        onProgress(DatasetProgress(
            fraction: 0.95,
            stageTitle: stagePrefixCameras,
            detail: "Writing COLMAP sparse/0 camera intrinsics & poses..."
        ))
        try writeCamerasTxt(intrinsics: intrinsics, to: sparseDir.appendingPathComponent("cameras.txt"))
        try writeImagesTxt(poses: poses, to: sparseDir.appendingPathComponent("images.txt"))
        try writePoints3DTxt(to: sparseDir.appendingPathComponent("points3D.txt"))

        onProgress(DatasetProgress(
            fraction: 1.0,
            stageTitle: "COLMAP Dataset Ready",
            detail: "Wrote \(poses.count) views (\(offsetPoses.count) parallax + masks) and \(points.count.formatted()) points"
        ))

        return ColmapDatasetResult(
            datasetDirectory: datasetDirectory,
            imagesDirectory: imagesDir,
            masksDirectory: writeMasks ? masksDir : nil,
            sparseDirectory: sparseDir,
            initPLYURL: initPLYURL,
            imageCount: poses.count,
            parallaxViewCount: offsetPoses.count,
            pointCount: points.count,
            usedMetal: slicer.isUsingMetal,
            usedDepthDisplacement: depthMap != nil,
            minDepthMeters: depthMap?.minRadiusMeters,
            maxDepthMeters: depthMap?.maxRadiusMeters
        )
    }

    /// Exports the full COLMAP dataset and, when `settings.inpaintParallaxHoles` is enabled with parallax > 0,
    /// runs CoreML `LaMa` over the rendered offset views to fill black disoccluded voids behind foreground
    /// trees, rocks, and objects before Brush trains.
    public func writeDatasetAsync(
        from panorama: PanoramaAsset,
        depthMap: EquirectangularDepthMap? = nil,
        to datasetDirectory: URL,
        settings: GenerationSettings,
        holeInpainter: ParallaxHoleInpainter = ParallaxHoleInpainter(),
        stagePrefixPointCloud: String = "2/4 Building Depth-Displaced Point Cloud...",
        stagePrefixCameras: String = "3/4 Rendering Multi-View Parallax Cameras & Occlusion Masks...",
        onProgress: @Sendable @escaping (DatasetProgress) -> Void = { _ in }
    ) async throws -> ColmapDatasetResult {
        let shouldInpaint = (depthMap != nil && settings.parallaxBaselineMeters > 0.01 && settings.inpaintParallaxHoles)

        let baseResult = try writeDataset(
            from: panorama,
            depthMap: depthMap,
            to: datasetDirectory,
            settings: settings,
            stagePrefixPointCloud: stagePrefixPointCloud,
            stagePrefixCameras: stagePrefixCameras
        ) { prog in
            let scaled = shouldInpaint ? (prog.fraction * 0.58) : prog.fraction
            onProgress(DatasetProgress(fraction: scaled, stageTitle: prog.stageTitle, detail: prog.detail))
        }

        guard shouldInpaint,
              baseResult.parallaxViewCount > 0,
              let masksDir = baseResult.masksDirectory else {
            return baseResult
        }

        try Task.checkCancellation()
        let stageTitle = stagePrefixCameras
            .replacingOccurrences(of: "Occlusion Masks", with: "LaMa Background Void Fill")
        onProgress(DatasetProgress(
            fraction: 0.60,
            stageTitle: stageTitle,
            detail: "Loading CoreML LaMa background inpainter (~206 MB one-time)..."
        ))

        let loadedLaMa = try await holeInpainter.prepareModel { state in
            switch state {
            case .downloading(let frac, let dlMB, let totMB):
                onProgress(DatasetProgress(
                    fraction: 0.60 + 0.14 * frac,
                    stageTitle: stageTitle,
                    detail: String(format: "Downloading CoreML LaMa (%.1f / %.1f MB)...", dlMB, totMB)
                ))
            case .compiling:
                onProgress(DatasetProgress(
                    fraction: 0.75,
                    stageTitle: stageTitle,
                    detail: "Compiling CoreML LaMa for Apple Silicon (one-time step)..."
                ))
            case .ready, .notDownloaded, .failed:
                break
            }
        }

        let allImageURLs = try FileManager.default.contentsOfDirectory(
            at: baseResult.imagesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let centerCount = max(0, baseResult.imageCount - baseResult.parallaxViewCount)
        let offsetURLs = Array(allImageURLs.dropFirst(centerCount))
        let solidWhiteMask = try ParallaxHoleInpainter.makeSolidWhiteMask(
            width: settings.perspectiveResolution,
            height: settings.perspectiveResolution
        )

        var filledCount = 0
        for (idx, imageURL) in offsetURLs.enumerated() {
            try Task.checkCancellation()
            let name = imageURL.lastPathComponent
            let maskURL = masksDir.appendingPathComponent(name)

            let frac = 0.76 + 0.23 * (Double(idx) / Double(max(offsetURLs.count, 1)))
            onProgress(DatasetProgress(
                fraction: frac,
                stageTitle: stageTitle,
                detail: "Filling background voids (LaMa): \(name) (\(idx + 1)/\(offsetURLs.count))"
            ))

            guard FileManager.default.fileExists(atPath: maskURL.path),
                  let viewAsset = try? PanoramaLoader.load(from: imageURL),
                  let maskAsset = try? PanoramaLoader.load(from: maskURL) else {
                continue
            }

            let (filledImage, didFill) = try await holeInpainter.fillDisoccludedHoles(
                in: viewAsset.cgImage,
                validMask: maskAsset.cgImage,
                using: loadedLaMa
            )
            if didFill {
                try EquirectangularSlicer.writePNG(filledImage, to: imageURL)
                try EquirectangularSlicer.writePNG(solidWhiteMask, to: maskURL)
                filledCount += 1
            }
        }

        onProgress(DatasetProgress(
            fraction: 1.0,
            stageTitle: stageTitle,
            detail: "LaMa filled background voids across \(filledCount)/\(offsetURLs.count) parallax views"
        ))
        return baseResult
    }

    private func writeCamerasTxt(intrinsics: PinholeCameraIntrinsics, to url: URL) throws {
        let content = """
        # Camera list with one line of data per camera:
        #   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]
        # Number of cameras: 1
        \(intrinsics.colmapLine)
        """ + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeImagesTxt(poses: [VirtualCameraPose], to url: URL) throws {
        var lines: [String] = [
            "# Image list with two lines of data per image:",
            "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME",
            "#   POINTS2D[] as (X, Y, POINT3D_ID)",
            "# Number of images: \(poses.count), mean observations per image: 0"
        ]
        for pose in poses {
            lines.append(pose.colmapPoseLine)
            lines.append("") // Empty 2D points line required by COLMAP format
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePoints3DTxt(to url: URL) throws {
        let content = """
        # 3D point list with one line of data per point:
        #   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)
        # Number of points: 0, mean track length: 0
        """ + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
