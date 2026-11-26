import CoreML
import Foundation

/// Current availability state of the CoreML `LaMa` background-void inpainting model.
public enum LaMaModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double, downloadedMB: Double, totalMB: Double)
    case compiling
    case ready(modelURL: URL)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum LaMaModelError: LocalizedError, Sendable {
    case httpStatusError(Int, String)
    case invalidPackageStructure
    case modelCompilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatusError(let code, let file):
            return "LaMa inpainting model download failed for \(file) (HTTP \(code))."
        case .invalidPackageStructure:
            return "Downloaded LaMa.mlpackage is incomplete or corrupted."
        case .modelCompilationFailed(let reason):
            return "Failed to compile CoreML LaMa inpainting model: \(reason)"
        }
    }
}

/// Thread-safe Sendable handle wrapping the compiled CoreML `LaMa` model.
public final class LoadedLaMaModel: @unchecked Sendable {
    public let model: MLModel
    public let compiledURL: URL

    public init(model: MLModel, compiledURL: URL) {
        self.model = model
        self.compiledURL = compiledURL
    }
}

/// Manages auto-discovery, native `URLSession` download, and CoreML compilation/caching for
/// Samsung AI's Apache-2.0 `LaMa.mlpackage` (`mlboydaisuke/LaMa-CoreML`, ~206 MB, 800×800 input).
public actor LaMaModelManager {
    public static let packageName = "LaMa.mlpackage"
    public static let compiledName = "LaMa.mlmodelc"
    public static let baseDownloadURL = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/"

    public struct RemoteFile: Sendable, Equatable {
        public let relativePath: String
        public let expectedBytes: Int64
    }

    public static let remoteFiles: [RemoteFile] = [
        RemoteFile(relativePath: "LaMa.mlpackage/Manifest.json", expectedBytes: 617),
        RemoteFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedBytes: 1_101_809),
        RemoteFile(relativePath: "LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedBytes: 215_544_960)
    ]

    public static var totalExpectedBytes: Int64 {
        remoteFiles.reduce(0) { $0 + $1.expectedBytes }
    }

    private let modelsRootDirectory: URL
    private var cachedModel: LoadedLaMaModel?

    public init(modelsRootDirectory: URL? = nil) {
        if let modelsRootDirectory {
            self.modelsRootDirectory = modelsRootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.modelsRootDirectory = appSupport
                .appendingPathComponent("PanoSplat3D", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
    }

    public func localModelURL() -> URL? {
        let fm = FileManager.default

        let compiledCacheURL = modelsRootDirectory.appendingPathComponent(Self.compiledName, isDirectory: true)
        if fm.fileExists(atPath: compiledCacheURL.path) {
            return compiledCacheURL
        }

        if let resourceURL = Bundle.main.resourceURL {
            for candidate in [Self.compiledName, Self.packageName] {
                let url = resourceURL.appendingPathComponent(candidate, isDirectory: true)
                if Self.isValidModelAt(url) {
                    return url
                }
            }
        }

        let downloadedPackageURL = modelsRootDirectory.appendingPathComponent(Self.packageName, isDirectory: true)
        if Self.isValidModelAt(downloadedPackageURL) {
            return downloadedPackageURL
        }

        return nil
    }

    private static func isValidModelAt(_ url: URL) -> Bool {
        let fm = FileManager.default
        if url.pathExtension == "mlmodelc" {
            return fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                || fm.fileExists(atPath: url.appendingPathComponent("model.mil").path)
                || fm.fileExists(atPath: url.path)
        }
        if url.pathExtension == "mlpackage" {
            let manifest = url.appendingPathComponent("Manifest.json")
            let model = url.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
            let weights = url.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            guard fm.fileExists(atPath: manifest.path),
                  fm.fileExists(atPath: model.path),
                  fm.fileExists(atPath: weights.path) else {
                return false
            }
            let size = (try? fm.attributesOfItem(atPath: weights.path)[.size] as? Int64) ?? 0
            return size > 180_000_000
        }
        return false
    }

    public func loadOrDownloadModel(
        onStateChange: @Sendable (LaMaModelState) -> Void = { _ in }
    ) async throws -> LoadedLaMaModel {
        if let cachedModel {
            onStateChange(.ready(modelURL: cachedModel.compiledURL))
            return cachedModel
        }

        var sourceURL = localModelURL()
        if sourceURL == nil {
            sourceURL = try await downloadPackage(onStateChange: onStateChange)
        }

        guard let modelURL = sourceURL else {
            throw LaMaModelError.invalidPackageStructure
        }

        let compiledURL = try await ensureCompiledModel(from: modelURL, onStateChange: onStateChange)
        onStateChange(.compiling)

        let loaded = try await Self.loadCompiledModel(compiledURL: compiledURL)
        self.cachedModel = loaded
        onStateChange(.ready(modelURL: compiledURL))
        return loaded
    }

    private nonisolated static func loadCompiledModel(compiledURL: URL) async throws -> LoadedLaMaModel {
        let config = MLModelConfiguration()
        // `mlboydaisuke/LaMa-CoreML` is explicitly verified against `.all` (ANE + GPU) to avoid FP16 overflow
        config.computeUnits = .all
        let mlModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        return LoadedLaMaModel(model: mlModel, compiledURL: compiledURL)
    }

    public func downloadPackage(
        onStateChange: @Sendable (LaMaModelState) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRootDirectory, withIntermediateDirectories: true)

        let stagingRoot = modelsRootDirectory.appendingPathComponent("Staging-LaMa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let totalExpected = Self.totalExpectedBytes
        let totalMB = Double(totalExpected) / 1_048_576.0
        var completedBytesBeforeFile: Int64 = 0

        onStateChange(.downloading(progress: 0.0, downloadedMB: 0.0, totalMB: totalMB))

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 1200
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        for file in Self.remoteFiles {
            try Task.checkCancellation()

            guard let remoteURL = URL(string: Self.baseDownloadURL + file.relativePath) else {
                throw LaMaModelError.invalidPackageStructure
            }

            let destinationURL = stagingRoot.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let (asyncBytes, response) = try await session.bytes(from: remoteURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw LaMaModelError.httpStatusError(http.statusCode, destinationURL.lastPathComponent)
            }

            fm.createFile(atPath: destinationURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? fileHandle.close() }

            var buffer = Data()
            buffer.reserveCapacity(512 * 1024)
            var fileBytesReceived: Int64 = 0
            var lastReportedBytes: Int64 = 0

            for try await byte in asyncBytes {
                buffer.append(byte)
                fileBytesReceived += 1

                if buffer.count >= 512 * 1024 {
                    try Task.checkCancellation()
                    try fileHandle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)

                    let totalReceived = completedBytesBeforeFile + fileBytesReceived
                    if totalReceived - lastReportedBytes >= 512 * 1024 {
                        lastReportedBytes = totalReceived
                        let frac = min(Double(totalReceived) / Double(max(totalExpected, 1)), 0.99)
                        let downloadedMB = Double(totalReceived) / 1_048_576.0
                        onStateChange(.downloading(progress: frac, downloadedMB: downloadedMB, totalMB: totalMB))
                    }
                }
            }

            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
            }

            completedBytesBeforeFile += fileBytesReceived
            let frac = min(Double(completedBytesBeforeFile) / Double(max(totalExpected, 1)), 1.0)
            let downloadedMB = Double(completedBytesBeforeFile) / 1_048_576.0
            onStateChange(.downloading(progress: frac, downloadedMB: downloadedMB, totalMB: totalMB))
        }

        let stagedPackageURL = stagingRoot.appendingPathComponent(Self.packageName, isDirectory: true)
        guard Self.isValidModelAt(stagedPackageURL) else {
            throw LaMaModelError.invalidPackageStructure
        }

        let finalPackageURL = modelsRootDirectory.appendingPathComponent(Self.packageName, isDirectory: true)
        if fm.fileExists(atPath: finalPackageURL.path) {
            try fm.removeItem(at: finalPackageURL)
        }
        try fm.moveItem(at: stagedPackageURL, to: finalPackageURL)
        return finalPackageURL
    }

    private func ensureCompiledModel(
        from sourceURL: URL,
        onStateChange: @Sendable (LaMaModelState) -> Void
    ) async throws -> URL {
        if sourceURL.pathExtension == "mlmodelc" {
            return sourceURL
        }

        let fm = FileManager.default
        let compiledCacheURL = modelsRootDirectory.appendingPathComponent(Self.compiledName, isDirectory: true)
        if fm.fileExists(atPath: compiledCacheURL.path) {
            return compiledCacheURL
        }

        onStateChange(.compiling)
        do {
            let tempCompiledURL = try await MLModel.compileModel(at: sourceURL)
            try fm.createDirectory(at: modelsRootDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: compiledCacheURL.path) {
                try fm.removeItem(at: compiledCacheURL)
            }
            try fm.moveItem(at: tempCompiledURL, to: compiledCacheURL)
            return compiledCacheURL
        } catch {
            throw LaMaModelError.modelCompilationFailed(error.localizedDescription)
        }
    }
}
