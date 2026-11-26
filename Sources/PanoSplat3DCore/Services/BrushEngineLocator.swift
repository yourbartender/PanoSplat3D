import Foundation

/// How the Brush engine binary was discovered.
public enum BrushDiscoverySource: String, Sendable, Equatable {
    case userSelected = "Selected by User"
    case appBundleResource = "Bundled with App"
    case projectDirectory = "Project Folder"
    case applicationsFolder = "Applications"
    case userApplicationsFolder = "User Applications"
    case systemPath = "System Path"
}

/// Resolved Brush engine installation metadata.
public struct ResolvedBrushEngine: Sendable, Equatable {
    /// The actual executable binary URL (e.g. `/Applications/Brush.app/Contents/MacOS/brush` or `.../brush_app`).
    public let executableURL: URL
    /// The display URL (e.g. `/Applications/Brush.app` when chosen via an `.app` bundle, or the binary URL itself).
    public let displayURL: URL
    public let source: BrushDiscoverySource

    public init(executableURL: URL, displayURL: URL, source: BrushDiscoverySource) {
        self.executableURL = executableURL
        self.displayURL = displayURL
        self.source = source
    }

    public var displayName: String {
        displayURL.lastPathComponent
    }
}

/// Errors returned when validating a user-selected Brush `.app` bundle or standalone binary.
public enum BrushLocatorError: LocalizedError, Sendable {
    case notFound(URL)
    case bundleExecutableMissing(URL)
    case notExecutable(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return "No file or application found at \(url.path)."
        case .bundleExecutableMissing(let url):
            return "Could not find a Brush executable inside \(url.lastPathComponent)."
        case .notExecutable(let url):
            return "\(url.lastPathComponent) is not an executable binary."
        }
    }
}

/// Automatically discovers Brush on macOS and persists user selections via `UserDefaults` and bookmarks.
public final class BrushEngineLocator: Sendable {
    private static let bookmarkKey = "PanoSplat3D.brushEngineBookmark"
    private static let displayPathKey = "PanoSplat3D.brushEngineDisplayPath"
    private static let executablePathKey = "PanoSplat3D.brushEngineExecutablePath"

    private let userDefaultsSuiteName: String?

    public init(userDefaultsSuiteName: String? = nil) {
        self.userDefaultsSuiteName = userDefaultsSuiteName
    }

    private var defaults: UserDefaults {
        if let suite = userDefaultsSuiteName, let custom = UserDefaults(suiteName: suite) {
            return custom
        }
        return .standard
    }

    /// Resolves either a `.app` bundle (inspecting `Bundle(url:)?.executableURL` and `Contents/MacOS/{brush,brush_app}`)
    /// or a standalone `brush` / `brush_app` executable binary.
    public static func resolveExecutable(from selectedURL: URL) throws -> (executableURL: URL, displayURL: URL) {
        let standardized = selectedURL.standardizedFileURL
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw BrushLocatorError.notFound(standardized)
        }

        if standardized.pathExtension.lowercased() == "app" && isDirectory.boolValue {
            // 1. Inspect Bundle(url:)?.executableURL automatically (per SPEC Section 1.1)
            if let bundle = Bundle(url: standardized),
               let bundleExec = bundle.executableURL,
               fm.isExecutableFile(atPath: bundleExec.path) {
                return (bundleExec.standardizedFileURL, standardized)
            }

            // 2. Check standard macOS Brush binary names inside Contents/MacOS/
            let macOSDir = standardized.appendingPathComponent("Contents/MacOS", isDirectory: true)
            for candidateName in ["brush", "brush_app", "Brush"] {
                let candidate = macOSDir.appendingPathComponent(candidateName)
                if fm.isExecutableFile(atPath: candidate.path) {
                    return (candidate.standardizedFileURL, standardized)
                }
            }

            throw BrushLocatorError.bundleExecutableMissing(standardized)
        }

        // Standalone binary (e.g., `brush` or `brush_app`)
        guard !isDirectory.boolValue && fm.isExecutableFile(atPath: standardized.path) else {
            throw BrushLocatorError.notExecutable(standardized)
        }

        return (standardized, standardized)
    }

    /// Persists a user-selected Brush `.app` or binary URL in `UserDefaults` (with security-scoped bookmark when supported).
    public func saveUserSelection(_ selectedURL: URL) throws -> ResolvedBrushEngine {
        let resolved = try Self.resolveExecutable(from: selectedURL)

        let defaults = self.defaults
        defaults.set(resolved.displayURL.path, forKey: Self.displayPathKey)
        defaults.set(resolved.executableURL.path, forKey: Self.executablePathKey)

        // Try security-scoped bookmark first (for sandboxed .app builds), fall back to standard bookmark
        if let scopedBookmark = try? resolved.displayURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(scopedBookmark, forKey: Self.bookmarkKey)
        } else if let standardBookmark = try? resolved.displayURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(standardBookmark, forKey: Self.bookmarkKey)
        }

        return ResolvedBrushEngine(
            executableURL: resolved.executableURL,
            displayURL: resolved.displayURL,
            source: .userSelected
        )
    }

    /// Clears any manually saved Brush path so automatic discovery runs fresh.
    public func clearSavedSelection() {
        let defaults = self.defaults
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.displayPathKey)
        defaults.removeObject(forKey: Self.executablePathKey)
    }

    /// Automatically locates Brush by checking persisted user selection, app bundle resources,
    /// current/workspace directory (including `brush_app`), and standard macOS locations.
    public func discover(additionalSearchDirectories: [URL] = []) -> ResolvedBrushEngine? {
        // 1. Persisted user selection (bookmark or path)
        if let persisted = loadPersistedSelection() {
            return persisted
        }

        // 2. App's own Bundle.main.resourceURL
        if let resourceURL = Bundle.main.resourceURL {
            if let found = searchDirectory(resourceURL, source: .appBundleResource) {
                return found
            }
        }

        // 3. Explicit extra directories (useful for tests & workspace discovery)
        for dir in additionalSearchDirectories {
            if let found = searchDirectory(dir, source: .projectDirectory) {
                return found
            }
        }

        // 4. Current working directory & ancestor directories of the executable (detects project-folder `brush_app`)
        for dir in runtimeWorkspaceDirectories() {
            if let found = searchDirectory(dir, source: .projectDirectory) {
                return found
            }
        }

        // 5. Standard macOS paths specified in AGENTS.md
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardCandidates: [(URL, BrushDiscoverySource)] = [
            (URL(fileURLWithPath: "/Applications/Brush.app"), .applicationsFolder),
            (URL(fileURLWithPath: "/Applications/Brush.app/Contents/MacOS/brush"), .applicationsFolder),
            (URL(fileURLWithPath: "/Applications/Brush.app/Contents/MacOS/brush_app"), .applicationsFolder),
            (home.appendingPathComponent("Applications/Brush.app"), .userApplicationsFolder),
            (home.appendingPathComponent("Applications/Brush.app/Contents/MacOS/brush"), .userApplicationsFolder),
            (home.appendingPathComponent("Applications/Brush.app/Contents/MacOS/brush_app"), .userApplicationsFolder),
            (URL(fileURLWithPath: "/usr/local/bin/brush"), .systemPath),
            (URL(fileURLWithPath: "/usr/local/bin/brush_app"), .systemPath),
            (URL(fileURLWithPath: "/opt/homebrew/bin/brush"), .systemPath),
            (URL(fileURLWithPath: "/opt/homebrew/bin/brush_app"), .systemPath),
            (home.appendingPathComponent(".cargo/bin/brush"), .systemPath),
            (home.appendingPathComponent(".cargo/bin/brush_app"), .systemPath)
        ]

        for (candidate, source) in standardCandidates {
            if let resolved = try? Self.resolveExecutable(from: candidate) {
                return ResolvedBrushEngine(
                    executableURL: resolved.executableURL,
                    displayURL: resolved.displayURL,
                    source: source
                )
            }
        }

        return nil
    }

    private func loadPersistedSelection() -> ResolvedBrushEngine? {
        let defaults = self.defaults

        if let bookmarkData = defaults.data(forKey: Self.bookmarkKey) {
            var isStale = false
            let resolvedBookmarkURL =
                (try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ))
                ?? (try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ))

            if let url = resolvedBookmarkURL {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                if let resolved = try? Self.resolveExecutable(from: url) {
                    if isStale {
                        _ = try? saveUserSelection(resolved.displayURL)
                    }
                    return ResolvedBrushEngine(
                        executableURL: resolved.executableURL,
                        displayURL: resolved.displayURL,
                        source: .userSelected
                    )
                }
            }
        }

        if let savedDisplayPath = defaults.string(forKey: Self.displayPathKey) {
            let url = URL(fileURLWithPath: savedDisplayPath)
            if let resolved = try? Self.resolveExecutable(from: url) {
                return ResolvedBrushEngine(
                    executableURL: resolved.executableURL,
                    displayURL: resolved.displayURL,
                    source: .userSelected
                )
            }
        }

        if let savedExecPath = defaults.string(forKey: Self.executablePathKey) {
            let url = URL(fileURLWithPath: savedExecPath)
            if let resolved = try? Self.resolveExecutable(from: url) {
                return ResolvedBrushEngine(
                    executableURL: resolved.executableURL,
                    displayURL: resolved.displayURL,
                    source: .userSelected
                )
            }
        }

        return nil
    }

    private func searchDirectory(_ directory: URL, source: BrushDiscoverySource) -> ResolvedBrushEngine? {
        let names = ["Brush.app", "brush", "brush_app"]
        for name in names {
            let candidate = directory.appendingPathComponent(name)
            if let resolved = try? Self.resolveExecutable(from: candidate) {
                return ResolvedBrushEngine(
                    executableURL: resolved.executableURL,
                    displayURL: resolved.displayURL,
                    source: source
                )
            }
        }
        return nil
    }

    private func runtimeWorkspaceDirectories() -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()

        func appendIfNew(_ url: URL) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                dirs.append(url.standardizedFileURL)
            }
        }

        appendIfNew(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

        // Walk up to 5 ancestor directories from the running executable (handles .build/arm64-apple-macosx/debug/PanoSplat3D)
        var cursor = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            appendIfNew(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        if let execURL = Bundle.main.executableURL {
            var execCursor = execURL.deletingLastPathComponent()
            for _ in 0..<6 {
                appendIfNew(execCursor)
                let parent = execCursor.deletingLastPathComponent()
                if parent.path == execCursor.path { break }
                execCursor = parent
            }
        }

        return dirs
    }
}
