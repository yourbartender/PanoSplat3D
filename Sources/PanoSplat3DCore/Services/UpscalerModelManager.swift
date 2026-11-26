import CoreML
import Foundation

/// Current availability state of the selected CoreML 360° upscaler model.
public enum UpscalerModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double, downloadedMB: Double, totalMB: Double)
    case compiling
    case ready(modelURL: URL)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .downloading, .compiling: return true
        default: return false
        }
    }
}

/// Thread-safe Sendable handle wrapping a compiled CoreML upscaler model.
public final class LoadedUpscalerModel: @unchecked Sendable {
    public let variant: UpscalerModelVariant
    public let model: MLModel
    public let compiledURL: URL

    public init(variant: UpscalerModelVariant, model: MLModel, compiledURL: URL) {
        self.variant = variant
        self.model = model
        self.compiledURL = compiledURL
    }
}

public enum UpscalerModelError: LocalizedError, Sendable {
    case httpStatusError(Int, String)
    case invalidPackageStructure(String)
    case modelCompilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatusError(let code, let file):
            return "Upscaler download failed for \(file) (HTTP \(code))."
        case .invalidPackageStructure(let name):
            return "Downloaded \(name) is incomplete or corrupted."
        case .modelCompilationFailed(let reason):
            return "Failed to compile CoreML upscaler model: \(reason)"
        }
    }
}

/// Manages auto-discovery, native `URLSession` downloading, and CoreML compilation/caching of
/// selectable CoreML upscaler models (`RealPLKSR 2× Natural`, `4xNomosWebPhoto`, `Real-ESRGAN x4+`).
public actor UpscalerModelManager {
    private let modelsRootDirectory: URL
    private var cachedModels: [UpscalerModelVariant: LoadedUpscalerModel] = [:]

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

    /// Checks whether a compiled or downloaded CoreML package for `variant` is already available locally.
    public func localModelURL(for variant: UpscalerModelVariant = .realPLKSR2xNatural) -> URL? {
        let compiledCacheURL = modelsRootDirectory.appendingPathComponent(variant.compiledName, isDirectory: true)
        if Self.isValidModelAt(compiledCacheURL, variant: variant) {
            return compiledCacheURL
        }

        if let resourceURL = Bundle.main.resourceURL {
            for candidate in [variant.compiledName, variant.packageName] {
                let url = resourceURL.appendingPathComponent(candidate, isDirectory: true)
                if Self.isValidModelAt(url, variant: variant) {
                    return url
                }
            }
        }

        let downloadedPackageURL = modelsRootDirectory.appendingPathComponent(variant.packageName, isDirectory: true)
        if Self.isValidModelAt(downloadedPackageURL, variant: variant) {
            return downloadedPackageURL
        }

        return nil
    }

    private static func isValidModelAt(_ url: URL, variant: UpscalerModelVariant) -> Bool {
        let fm = FileManager.default
        if url.pathExtension == "mlmodelc" {
            return fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                || fm.fileExists(atPath: url.appendingPathComponent("model.mil").path)
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
            return size >= variant.minimumValidWeightBytes
        }
        return false
    }

    /// Ensures the requested `UpscalerModelVariant` is downloaded, compiled, and loaded with its optimal compute units.
    public func loadOrDownloadModel(
        variant: UpscalerModelVariant = .realPLKSR2xNatural,
        onStateChange: @Sendable (UpscalerModelState) -> Void = { _ in }
    ) async throws -> LoadedUpscalerModel {
        if let cached = cachedModels[variant] {
            onStateChange(.ready(modelURL: cached.compiledURL))
            return cached
        }

        var sourceURL = localModelURL(for: variant)
        if sourceURL == nil {
            sourceURL = try await downloadPackage(variant: variant, onStateChange: onStateChange)
        }

        guard let modelURL = sourceURL else {
            throw UpscalerModelError.invalidPackageStructure(variant.packageName)
        }

        let compiledURL = try await ensureCompiledModel(
            from: modelURL,
            variant: variant,
            onStateChange: onStateChange
        )

        onStateChange(.compiling)
        let loaded = try await Self.loadCompiledModel(
            variant: variant,
            at: compiledURL,
            computeUnits: variant.preferredComputeUnits
        )
        self.cachedModels[variant] = loaded
        onStateChange(.ready(modelURL: compiledURL))
        return loaded
    }

    private nonisolated static func loadCompiledModel(
        variant: UpscalerModelVariant,
        at compiledURL: URL,
        computeUnits: MLComputeUnits
    ) async throws -> LoadedUpscalerModel {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = (computeUnits != .cpuAndGPU)
        let mlModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        return LoadedUpscalerModel(variant: variant, model: mlModel, compiledURL: compiledURL)
    }

    public func downloadPackage(
        variant: UpscalerModelVariant = .realPLKSR2xNatural,
        onStateChange: @Sendable (UpscalerModelState) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRootDirectory, withIntermediateDirectories: true)

        let stagingRoot = modelsRootDirectory.appendingPathComponent("UpscalerStaging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let totalExpectedBytes = max(variant.totalExpectedBytes, 1)
        let totalMB = Double(totalExpectedBytes) / 1_048_576.0
        var completedBytesBeforeCurrentFile: Int64 = 0

        onStateChange(.downloading(progress: 0.0, downloadedMB: 0.0, totalMB: totalMB))

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 600
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        for file in variant.remoteFiles {
            try Task.checkCancellation()

            guard let remoteURL = URL(string: variant.baseDownloadURL + file.relativePath) else {
                throw UpscalerModelError.invalidPackageStructure(variant.packageName)
            }

            let destinationURL = stagingRoot.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let (asyncBytes, response) = try await session.bytes(from: remoteURL)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw UpscalerModelError.httpStatusError(httpResponse.statusCode, destinationURL.lastPathComponent)
            }

            fm.createFile(atPath: destinationURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? fileHandle.close() }

            var buffer = Data()
            buffer.reserveCapacity(256 * 1024)
            var fileBytesReceived: Int64 = 0
            var lastReportedBytes: Int64 = 0

            for try await byte in asyncBytes {
                buffer.append(byte)
                fileBytesReceived += 1

                if buffer.count >= 256 * 1024 {
                    try Task.checkCancellation()
                    try fileHandle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)

                    let totalReceived = completedBytesBeforeCurrentFile + fileBytesReceived
                    if totalReceived - lastReportedBytes >= 256 * 1024 {
                        lastReportedBytes = totalReceived
                        let fraction = min(Double(totalReceived) / Double(totalExpectedBytes), 0.99)
                        let downloadedMB = Double(totalReceived) / 1_048_576.0
                        onStateChange(.downloading(progress: fraction, downloadedMB: downloadedMB, totalMB: totalMB))
                    }
                }
            }

            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
            }

            completedBytesBeforeCurrentFile += fileBytesReceived
            let fraction = min(Double(completedBytesBeforeCurrentFile) / Double(totalExpectedBytes), 1.0)
            let downloadedMB = Double(completedBytesBeforeCurrentFile) / 1_048_576.0
            onStateChange(.downloading(progress: fraction, downloadedMB: downloadedMB, totalMB: totalMB))
        }

        let stagedPackageURL = stagingRoot.appendingPathComponent(variant.packageName, isDirectory: true)
        guard Self.isValidModelAt(stagedPackageURL, variant: variant) else {
            throw UpscalerModelError.invalidPackageStructure(variant.packageName)
        }

        let finalPackageURL = modelsRootDirectory.appendingPathComponent(variant.packageName, isDirectory: true)
        if fm.fileExists(atPath: finalPackageURL.path) {
            try fm.removeItem(at: finalPackageURL)
        }
        try fm.moveItem(at: stagedPackageURL, to: finalPackageURL)
        return finalPackageURL
    }

    private func ensureCompiledModel(
        from sourceURL: URL,
        variant: UpscalerModelVariant,
        onStateChange: @Sendable (UpscalerModelState) -> Void
    ) async throws -> URL {
        if sourceURL.pathExtension == "mlmodelc" {
            return sourceURL
        }

        let fm = FileManager.default
        let compiledCacheURL = modelsRootDirectory.appendingPathComponent(variant.compiledName, isDirectory: true)
        if Self.isValidModelAt(compiledCacheURL, variant: variant) {
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
            throw UpscalerModelError.modelCompilationFailed(error.localizedDescription)
        }
    }
}
