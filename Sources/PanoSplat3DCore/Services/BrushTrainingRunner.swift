import Darwin
import Foundation

/// Live training progress parsed from Brush's real-time terminal output.
public struct BrushTrainingProgress: Sendable, Equatable {
    public let currentStep: Int
    public let totalSteps: Int
    public let splatCount: Int?
    public let rateAndETA: String?

    public var fraction: Double {
        guard totalSteps > 0 else { return 0 }
        return min(max(Double(currentStep) / Double(totalSteps), 0.0), 1.0)
    }

    public init(currentStep: Int, totalSteps: Int, splatCount: Int? = nil, rateAndETA: String? = nil) {
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.splatCount = splatCount
        self.rateAndETA = rateAndETA
    }
}

/// Result of a completed headless Brush training run.
public struct BrushTrainingResult: Sendable, Equatable {
    public let outputPLYURL: URL
    public let totalSteps: Int
    public let finalSplatCount: Int?
    public let fileSizeBytes: Int64
    public let durationSeconds: Double

    public init(
        outputPLYURL: URL,
        totalSteps: Int,
        finalSplatCount: Int?,
        fileSizeBytes: Int64,
        durationSeconds: Double
    ) {
        self.outputPLYURL = outputPLYURL
        self.totalSteps = totalSteps
        self.finalSplatCount = finalSplatCount
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
    }
}

public enum BrushTrainingError: LocalizedError, Sendable {
    case executableNotFound(URL)
    case processLaunchFailed(String)
    case trainingFailed(exitCode: Int32, details: String)
    case outputPLYMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "Brush executable not found at \(url.path)."
        case .processLaunchFailed(let reason):
            return "Failed to launch Brush engine: \(reason)"
        case .trainingFailed(let code, let details):
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Brush training exited with code \(code)."
            }
            return "Brush training failed (exit \(code)): \(trimmed)"
        case .outputPLYMissing(let url):
            return "Brush finished without writing the expected output file '\(url.lastPathComponent)'."
        }
    }
}

/// Runs the located `brush` / `brush_app` binary headlessly in the background with a POSIX PTY
/// to stream real-time step progress (`Step X / Y`, steps/sec, ETA, and live splat count).
public final class BrushTrainingRunner: Sendable {
    public init() {}

    /// Strips ANSI CSI/OSC escape codes and parses Brush's step progress & splat count from a text chunk.
    public static func parseProgressChunk(
        _ rawText: String,
        fallbackTotalSteps: Int,
        previousSplatCount: Int?
    ) -> BrushTrainingProgress? {
        let cleaned = stripANSI(rawText)

        var latestSplatCount = previousSplatCount
        if let splatRegex = try? NSRegularExpression(pattern: #"Current splat count\s+(\d+)"#, options: []) {
            let matches = splatRegex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            if let last = matches.last,
               let range = Range(last.range(at: 1), in: cleaned),
               let parsed = Int(cleaned[range]) {
                latestSplatCount = parsed
            }
        }

        // Matches e.g.: "245/250     Steps (110.5483/s, 0s remaining)"
        if let stepRegex = try? NSRegularExpression(
            pattern: #"(\d+)\s*/\s*(\d+)\s+Steps(?:\s*\(([^)]+)\))?"#,
            options: [.caseInsensitive]
        ) {
            let matches = stepRegex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            if let last = matches.last,
               let curRange = Range(last.range(at: 1), in: cleaned),
               let totRange = Range(last.range(at: 2), in: cleaned),
               let current = Int(cleaned[curRange]),
               let total = Int(cleaned[totRange]) {
                var rateETA: String?
                if last.range(at: 3).location != NSNotFound,
                   let etaRange = Range(last.range(at: 3), in: cleaned) {
                    rateETA = String(cleaned[etaRange]).trimmingCharacters(in: .whitespaces)
                }
                return BrushTrainingProgress(
                    currentStep: current,
                    totalSteps: total > 0 ? total : fallbackTotalSteps,
                    splatCount: latestSplatCount,
                    rateAndETA: rateETA
                )
            }
        }

        return nil
    }

    public static func stripANSI(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-9;?]*[A-Za-z]"#, options: []) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    /// Executes Brush headlessly on `datasetDirectory` and exports the final trained 3D Gaussian Splat `.ply` to `outputPLYURL`.
    public func train(
        brushExecutableURL: URL,
        datasetDirectory: URL,
        outputPLYURL: URL,
        totalSteps: Int,
        shDegree: Int,
        maxResolution: Int = 1024,
        onProgress: @Sendable @escaping (BrushTrainingProgress) -> Void = { _ in }
    ) async throws -> BrushTrainingResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: brushExecutableURL.path) else {
            throw BrushTrainingError.executableNotFound(brushExecutableURL)
        }

        let exportDirectory = outputPLYURL.deletingLastPathComponent()
        let exportFileName = outputPLYURL.lastPathComponent
        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        // Remove any stale output file with the exact target name so we reliably verify fresh export
        if fm.fileExists(atPath: outputPLYURL.path) {
            try? fm.removeItem(at: outputPLYURL)
        }

        let startTime = Date()

        let growthStopIter = max(10, Int((Double(totalSteps) * 0.70).rounded()))
        let refineEvery = totalSteps >= 500 ? 100 : max(20, totalSteps / 4)

        // Keep Burn/CubeCL's `target/0.7.0/autotune` Metal kernel cache in Caches rather than polluting the user's export folder.
        let cachesRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let brushCacheDir = cachesRoot
            .appendingPathComponent("PanoSplat3D", isDirectory: true)
            .appendingPathComponent("BrushCache", isDirectory: true)
        try? fm.createDirectory(at: brushCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = brushExecutableURL
        process.currentDirectoryURL = fm.fileExists(atPath: brushCacheDir.path) ? brushCacheDir : exportDirectory
        process.arguments = [
            "--total-steps", "\(totalSteps)",
            "--sh-degree", "\(shDegree)",
            "--max-resolution", "\(maxResolution)",
            "--refine-every", "\(refineEvery)",
            "--growth-stop-iter", "\(growthStopIter)",
            "--growth-grad-threshold", "0.00003",
            "--mean-noise-weight", "8",
            "--scale-loss-weight", "1e-6",
            "--opac-loss-weight", "1e-7",
            "--export-every", "\(totalSteps)",
            "--export-path", exportDirectory.path,
            "--export-name", exportFileName,
            datasetDirectory.path
        ]

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["CLICOLOR"] = "0"
        process.environment = env

        // Open a POSIX PTY so Brush's indicatif progress reporter emits live step counts & ETA
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        let usePTY = (openpty(&masterFD, &slaveFD, nil, nil, nil) == 0)

        let fallbackPipe: Pipe?
        let readHandle: FileHandle

        if usePTY {
            let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            fallbackPipe = nil
            readHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            fallbackPipe = pipe
            readHandle = pipe.fileHandleForReading
        }

        do {
            try process.run()
        } catch {
            if usePTY {
                try? readHandle.close()
                close(slaveFD)
            }
            throw BrushTrainingError.processLaunchFailed(error.localizedDescription)
        }

        // Close slave side in parent process once child has inherited it so EOF triggers cleanly on child exit
        if usePTY {
            (process.standardOutput as? FileHandle)?.closeFile()
        } else {
            fallbackPipe?.fileHandleForWriting.closeFile()
        }

        final class SharedParseState: @unchecked Sendable {
            let lock = NSLock()
            var lastSplatCount: Int?
            var recentLogTail = ""

            func appendTail(_ text: String) {
                lock.lock()
                defer { lock.unlock() }
                recentLogTail += text
                if recentLogTail.count > 4000 {
                    recentLogTail = String(recentLogTail.suffix(4000))
                }
            }

            func updateSplatCount(_ count: Int?) {
                guard let count else { return }
                lock.lock()
                lastSplatCount = count
                lock.unlock()
            }

            func currentSplatCount() -> Int? {
                lock.lock()
                defer { lock.unlock() }
                return lastSplatCount
            }

            func logTail() -> String {
                lock.lock()
                defer { lock.unlock() }
                return recentLogTail
            }
        }

        let parseState = SharedParseState()

        // Stream output asynchronously on a background reader thread
        let readerTask = Task.detached(priority: .utility) {
            let fd = readHandle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = Darwin.read(fd, &buffer, buffer.count)
                if bytesRead <= 0 {
                    break
                }
                let text = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
                let cleaned = BrushTrainingRunner.stripANSI(text)
                parseState.appendTail(cleaned)

                if let parsed = BrushTrainingRunner.parseProgressChunk(
                    cleaned,
                    fallbackTotalSteps: totalSteps,
                    previousSplatCount: parseState.currentSplatCount()
                ) {
                    parseState.updateSplatCount(parsed.splatCount)
                    onProgress(parsed)
                }
            }
            try? readHandle.close()
        }

        // Wait for process exit while supporting cooperative Swift Task cancellation
        let exitCode: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        await readerTask.value

        try Task.checkCancellation()

        guard exitCode == 0 else {
            throw BrushTrainingError.trainingFailed(
                exitCode: exitCode,
                details: Self.extractErrorSummary(from: parseState.logTail())
            )
        }

        guard fm.fileExists(atPath: outputPLYURL.path) else {
            throw BrushTrainingError.outputPLYMissing(outputPLYURL)
        }

        let fileSize = (try? fm.attributesOfItem(atPath: outputPLYURL.path)[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            throw BrushTrainingError.outputPLYMissing(outputPLYURL)
        }

        return BrushTrainingResult(
            outputPLYURL: outputPLYURL,
            totalSteps: totalSteps,
            finalSplatCount: parseState.currentSplatCount(),
            fileSizeBytes: fileSize,
            durationSeconds: Date().timeIntervalSince(startTime)
        )
    }

    private static func extractErrorSummary(from log: String) -> String {
        let lines = log
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.suffix(6).joined(separator: " | ")
    }
}
