import Foundation

/// Live state of the one-click native Brush engine downloader & installer.
public enum BrushInstallState: Equatable, Sendable {
    case idle
    case checkingRelease
    case downloading(progress: Double, downloadedMB: Double, totalMB: Double, versionTag: String)
    case extracting
    case installed(ResolvedBrushEngine)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .checkingRelease, .downloading, .extracting:
            return true
        default:
            return false
        }
    }
}

public enum BrushInstallError: LocalizedError, Sendable {
    case httpStatusError(Int)
    case missingMacOSAsset
    case extractionFailed(String)
    case executableNotFoundInArchive

    public var errorDescription: String? {
        switch self {
        case .httpStatusError(let code):
            return "Brush download failed (HTTP \(code))."
        case .missingMacOSAsset:
            return "Could not find an Apple Silicon macOS release asset for Brush."
        case .extractionFailed(let detail):
            return "Failed to extract Brush archive: \(detail)"
        case .executableNotFoundInArchive:
            return "Downloaded Brush archive did not contain a brush_app / brush executable."
        }
    }
}

/// Downloads and installs the official Apple Silicon **Brush** engine binary (`ArthurBrussee/brush`)
/// into `~/Library/Application Support/PanoSplat3D/Tools/brush_app` with zero Terminal commands.
public actor BrushInstaller {
    public struct ReleaseAssetInfo: Equatable, Sendable {
        public let versionTag: String
        public let assetName: String
        public let downloadURL: URL
        public let expectedBytes: Int64

        public init(versionTag: String, assetName: String, downloadURL: URL, expectedBytes: Int64) {
            self.versionTag = versionTag
            self.assetName = assetName
            self.downloadURL = downloadURL
            self.expectedBytes = expectedBytes
        }
    }

    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/ArthurBrussee/brush/releases/latest")!
    public static let fallbackAsset = ReleaseAssetInfo(
        versionTag: "v0.3.0",
        assetName: "brush-app-aarch64-apple-darwin.tar.xz",
        downloadURL: URL(string: "https://github.com/ArthurBrussee/brush/releases/download/v0.3.0/brush-app-aarch64-apple-darwin.tar.xz")!,
        expectedBytes: 41_447_012
    )

    /// Default per-user install folder (`~/Library/Application Support/PanoSplat3D/Tools/`).
    public nonisolated static var defaultToolsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("PanoSplat3D", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    private let toolsDirectory: URL

    public init(toolsDirectory: URL? = nil) {
        self.toolsDirectory = toolsDirectory ?? Self.defaultToolsDirectory
    }

    /// Parses GitHub's `/releases/latest` JSON payload and selects the Apple Silicon macOS `.tar.xz` or `.zip` asset.
    public nonisolated static func selectAppleSiliconAsset(from releaseJSONData: Data) -> ReleaseAssetInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: releaseJSONData)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            return nil
        }

        let candidates: [(score: Int, info: ReleaseAssetInfo)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String,
                  let urlStr = asset["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else {
                return nil
            }
            let lower = name.lowercased()
            guard !lower.hasSuffix(".sha256"), !lower.hasSuffix(".sig") else { return nil }
            let isMacArm = lower.contains("aarch64-apple-darwin") || lower.contains("arm64-apple-darwin") || (lower.contains("macos") && lower.contains("arm64"))
            guard isMacArm else { return nil }

            let score: Int
            if lower.hasSuffix(".tar.xz") {
                score = 3
            } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                score = 2
            } else if lower.hasSuffix(".zip") {
                score = 1
            } else {
                return nil
            }

            let size = (asset["size"] as? Int64)
                ?? (asset["size"] as? NSNumber)?.int64Value
                ?? fallbackAsset.expectedBytes
            return (score, ReleaseAssetInfo(versionTag: tag, assetName: name, downloadURL: url, expectedBytes: max(size, 1)))
        }

        return candidates.max(by: { $0.score < $1.score })?.info
    }

    /// Queries GitHub's latest release API (falling back cleanly to `v0.3.0`), downloads the Apple Silicon
    /// archive via `URLSession`, extracts `brush_app` into `Tools/`, and returns a ready `ResolvedBrushEngine`.
    public func installLatestBrush(
        onStateChange: @Sendable (BrushInstallState) -> Void = { _ in }
    ) async throws -> ResolvedBrushEngine {
        onStateChange(.checkingRelease)
        let asset = await resolveReleaseAsset()

        let fm = FileManager.default
        try fm.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        let stagingDir = toolsDirectory.appendingPathComponent("BrushInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let archiveURL = stagingDir.appendingPathComponent(asset.assetName)
        let totalBytes = max(asset.expectedBytes, 1)
        let totalMB = Double(totalBytes) / 1_048_576.0

        onStateChange(.downloading(progress: 0.0, downloadedMB: 0.0, totalMB: totalMB, versionTag: asset.versionTag))

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 600
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let (asyncBytes, response) = try await session.bytes(from: asset.downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrushInstallError.httpStatusError(http.statusCode)
        }

        let serverTotal = (response.expectedContentLength > 0) ? response.expectedContentLength : totalBytes
        let serverTotalMB = Double(serverTotal) / 1_048_576.0

        fm.createFile(atPath: archiveURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archiveURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var received: Int64 = 0
        var lastReported: Int64 = 0

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 256 * 1024 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if received - lastReported >= 256 * 1024 {
                    lastReported = received
                    let frac = min(Double(received) / Double(serverTotal), 0.99)
                    onStateChange(.downloading(
                        progress: frac,
                        downloadedMB: Double(received) / 1_048_576.0,
                        totalMB: serverTotalMB,
                        versionTag: asset.versionTag
                    ))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try? handle.close()

        try Task.checkCancellation()
        onStateChange(.extracting)

        let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try Self.extractArchive(archiveURL, to: extractedDir)

        guard let installed = try Self.installExtractedBinary(from: extractedDir, into: toolsDirectory) else {
            throw BrushInstallError.executableNotFoundInArchive
        }

        onStateChange(.installed(installed))
        return installed
    }

    private func resolveReleaseAsset() async -> ReleaseAssetInfo {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 8.0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: Self.latestReleaseAPIURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PanoSplat3D", forHTTPHeaderField: "User-Agent")

        if let (data, resp) = try? await session.data(for: req),
           let http = resp as? HTTPURLResponse,
           (200...299).contains(http.statusCode),
           let parsed = Self.selectAppleSiliconAsset(from: data) {
            return parsed
        }
        return Self.fallbackAsset
    }

    public nonisolated static func extractArchive(_ archiveURL: URL, to destinationDir: URL) throws {
        let lower = archiveURL.lastPathComponent.lowercased()
        let process = Process()
        if lower.hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", archiveURL.path, destinationDir.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archiveURL.path, "-C", destinationDir.path]
        }

        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrushInstallError.extractionFailed(errMsg.isEmpty ? "exit code \(process.terminationStatus)" : errMsg)
        }
    }

    public nonisolated static func installExtractedBinary(from extractedDir: URL, into toolsDirectory: URL) throws -> ResolvedBrushEngine? {
        let fm = FileManager.default
        try fm.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: extractedDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var foundBinaryURL: URL?
        for case let itemURL as URL in enumerator {
            let name = itemURL.lastPathComponent
            if name == "brush_app" || name == "brush" {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir {
                    foundBinaryURL = itemURL
                    break
                }
            }
        }

        guard let sourceBinary = foundBinaryURL else {
            return nil
        }

        let destURL = toolsDirectory.appendingPathComponent("brush_app", isDirectory: false)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: sourceBinary, to: destURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)

        // Best-effort clear quarantine flag so macOS never blocks execution
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "com.apple.quarantine", destURL.path]
        xattr.standardOutput = Pipe()
        xattr.standardError = Pipe()
        try? xattr.run()
        xattr.waitUntilExit()

        let resolved = try BrushEngineLocator.resolveExecutable(from: destURL)
        return ResolvedBrushEngine(
            executableURL: resolved.executableURL,
            displayURL: resolved.displayURL,
            source: .installedInAppSupport
        )
    }
}
