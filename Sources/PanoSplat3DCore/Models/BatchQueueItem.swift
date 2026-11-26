import Foundation

/// Execution status of a single panorama in the overnight batch queue.
public enum BatchItemStatus: Equatable, Sendable {
    case queued
    case running(stage: String, progress: Double)
    case completed(outputURL: URL, durationSeconds: Double)
    case failed(message: String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }

    public var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    public var isRetryable: Bool {
        switch self {
        case .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// A single 360° panorama queued for sequential overnight splat generation.
public struct BatchQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var baseOutputName: String
    public var status: BatchItemStatus

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        baseOutputName: String,
        status: BatchItemStatus = .queued
    ) {
        self.id = id
        self.sourceURL = sourceURL.standardizedFileURL
        self.baseOutputName = baseOutputName
        self.status = status
    }

    public var fileName: String {
        sourceURL.lastPathComponent
    }

    /// Computes a collision-free output URL (`.ply` or `_colmap` folder) inside `directory`,
    /// avoiding both `reservedURLs` from earlier items in the same batch and existing files on disk.
    public static func deduplicatedOutputURL(
        in directory: URL,
        baseName: String,
        mode: ExportMode,
        reservedURLs: Set<URL> = [],
        checkFileSystem: Bool = true
    ) -> URL {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = trimmed.isEmpty ? "pano_splat" : trimmed
        let fm = FileManager.default

        func makeCandidate(suffix: Int?) -> URL {
            let stem = suffix.map { "\(safeBase)_\($0)" } ?? safeBase
            switch mode {
            case .plySplat:
                let fileName = stem.lowercased().hasSuffix(".ply") ? stem : "\(stem).ply"
                return directory.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
            case .colmapDataset:
                let folderName = stem.hasSuffix("_colmap") ? stem : "\(stem)_colmap"
                return directory.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
            }
        }

        let first = makeCandidate(suffix: nil)
        if !reservedURLs.contains(first) && (!checkFileSystem || !fm.fileExists(atPath: first.path)) {
            return first
        }

        for n in 2...9999 {
            let candidate = makeCandidate(suffix: n)
            if !reservedURLs.contains(candidate) && (!checkFileSystem || !fm.fileExists(atPath: candidate.path)) {
                return candidate
            }
        }
        return makeCandidate(suffix: Int(Date().timeIntervalSince1970))
    }
}
