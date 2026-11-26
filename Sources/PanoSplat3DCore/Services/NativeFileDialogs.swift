import AppKit
import Foundation
import UniformTypeIdentifiers

/// Delegate allowing selection of `.app` bundles, directories (for navigation), and executable binaries in `NSOpenPanel`.
@MainActor
private final class BrushOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }

        if url.pathExtension.lowercased() == "app" {
            return true
        }
        if isDir.boolValue {
            return true
        }
        return fm.isExecutableFile(atPath: url.path)
    }
}

/// 100% native macOS file dialogs (`NSOpenPanel`, `NSSavePanel`, and Reveal in Finder).
@MainActor
public enum NativeFileDialogs {
    private static let brushDelegate = BrushOpenPanelDelegate()

    /// Produces a clean, short filesystem-safe base name (max 36 chars) so long AI-prompt image filenames
    /// never generate unwieldy paths.
    public static func sanitizedShortBaseName(from rawName: String, maxLength: Int = 36) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let joined: String = rawName
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let cleaned = joined
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))

        let base = cleaned.isEmpty ? "pano_splat" : cleaned
        guard base.count > maxLength else { return base }

        // Trim cleanly on an underscore boundary when possible
        let prefix = String(base.prefix(maxLength))
        if let lastSep = prefix.lastIndex(of: "_"), prefix.distance(from: prefix.startIndex, to: lastSep) >= maxLength / 2 {
            return String(prefix[..<lastSep])
        }
        return prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    /// Opens a native `NSOpenPanel` allowing the user to pick `Brush.app` or a standalone `brush` / `brush_app` executable.
    public static func pickBrushEngine(initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Locate Brush App or Binary"
        panel.message = "Select Brush.app (in Applications) or a standalone brush / brush_app executable."
        panel.prompt = "Select Brush"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = brushDelegate
        panel.directoryURL = initialDirectory ?? URL(fileURLWithPath: "/Applications", isDirectory: true)

        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens a native `NSOpenPanel` for selecting a 2:1 equirectangular `.png`, `.jpg`, or `.exr` panorama.
    public static func pickInputPanorama(initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose 360° Equirectangular Panorama"
        panel.message = "Select a 2:1 equirectangular panorama (.png, .jpg, or .exr)."
        panel.prompt = "Choose Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        var types: [UTType] = [.png, .jpeg, .tiff, .heic]
        if let exrType = UTType(filenameExtension: "exr") {
            types.append(exrType)
        }
        panel.allowedContentTypes = types
        panel.directoryURL = initialDirectory

        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens a native `NSOpenPanel` allowing multiple 360° panoramas to be added to the overnight batch queue.
    public static func pickMultipleInputPanoramas(initialDirectory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add 360° Panoramas to Batch Queue"
        panel.message = "Select one or more 2:1 equirectangular panoramas (.png, .jpg, .exr, .tif, .heic)."
        panel.prompt = "Add to Batch"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        var types: [UTType] = [.png, .jpeg, .tiff, .heic]
        if let exrType = UTType(filenameExtension: "exr") {
            types.append(exrType)
        }
        panel.allowedContentTypes = types
        panel.directoryURL = initialDirectory

        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Opens a native `NSOpenPanel` for selecting an output folder for batch exports.
    public static func pickBatchOutputDirectory(initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Batch Output Folder"
        panel.message = "All batch-generated .ply splats (or COLMAP datasets) will be saved inside this folder."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory

        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    /// Opens a native `NSSavePanel` to export the currently upscaled (or healed) 360° panorama as PNG or JPEG.
    public static func pickSavePanoramaDestination(
        defaultDirectory: URL?,
        defaultBaseName: String
    ) -> URL? {
        let shortName = sanitizedShortBaseName(from: defaultBaseName)
        let panel = NSSavePanel()
        panel.title = "Save Upscaled 360° Panorama"
        panel.message = "Choose where to save the upscaled 2:1 equirectangular panorama (.png or .jpg)."
        panel.prompt = "Save Image"
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDirectory
        panel.nameFieldStringValue = "\(shortName)_upscaled.png"
        panel.allowedContentTypes = [.png, .jpeg]

        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext != "png" && ext != "jpg" && ext != "jpeg" {
            url = url.appendingPathExtension("png")
        }
        return url.standardizedFileURL
    }

    /// Opens a native `NSSavePanel` to export a 180°-shifted PNG ready for native Eraser inpainting in Draw Things.
    public static func pickSaveShifted180Destination(
        defaultDirectory: URL?,
        defaultBaseName: String
    ) -> URL? {
        let shortName = sanitizedShortBaseName(from: defaultBaseName)
        let panel = NSSavePanel()
        panel.title = "Save 180°-Shifted Panorama for Draw Things"
        panel.message = "Drop this PNG into Draw Things, erase the center seam strip, generate, then import it back into PanoSplat3D."
        panel.prompt = "Save Shifted PNG"
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDirectory
        panel.nameFieldStringValue = "\(shortName)_shifted180.png"
        panel.allowedContentTypes = [.png]

        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "png" {
            url = url.appendingPathExtension("png")
        }
        return url.standardizedFileURL
    }

    /// Opens a native `NSOpenPanel` to import a Draw Things-inpainted 180°-shifted image and roll it back 180°.
    public static func pickImportShifted180Panorama(initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Inpainted 180°-Shifted Panorama"
        panel.message = "Select the image you inpainted & saved from Draw Things. PanoSplat3D will roll it back 180° automatically."
        panel.prompt = "Import & Roll Back 180°"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.directoryURL = initialDirectory

        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    /// Opens a native `NSSavePanel` letting the user choose BOTH destination directory AND custom filename/folder name.
    public static func pickOutputDestination(
        mode: ExportMode,
        defaultDirectory: URL?,
        defaultBaseName: String
    ) -> URL? {
        let shortName = sanitizedShortBaseName(from: defaultBaseName)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDirectory

        switch mode {
        case .plySplat:
            panel.title = "Save 3D Gaussian Splat (.ply)"
            panel.message = "Choose where to save the trained 3D Gaussian Splat (.ply) and set its filename."
            panel.prompt = "Set Output"
            panel.nameFieldStringValue = "\(shortName).ply"
            if let plyType = UTType(filenameExtension: "ply") {
                panel.allowedContentTypes = [plyType]
            }
            guard panel.runModal() == .OK, var url = panel.url else { return nil }
            if url.pathExtension.lowercased() != "ply" {
                url = url.appendingPathExtension("ply")
            }
            return url.standardizedFileURL

        case .colmapDataset:
            panel.title = "Save COLMAP Dataset Folder"
            panel.message = "Choose a location and name for the exported COLMAP dataset folder (images, masks, sparse/0, init.ply)."
            panel.prompt = "Set Folder"
            panel.nameFieldStringValue = "\(shortName)_colmap"
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url.standardizedFileURL
        }
    }

    /// Reveals the generated file or folder directly in macOS Finder.
    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
