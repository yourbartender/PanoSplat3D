import AppKit
import Foundation

/// Plays native macOS audio notifications (`coin.wav` on successful export, macOS system alert beep on failure).
@MainActor
public final class SoundAlertService {
    public static let shared = SoundAlertService()

    /// Retains the active `NSSound` instance so ARC does not deallocate it mid-playback.
    private var activeSound: NSSound?

    private init() {}

    /// Locates the bundled `coin.wav` completion sound across `.app` bundle resources, SwiftPM resources, and workspace directory.
    public static func locateSuccessSoundURL() -> URL? {
        // 1. Standard macOS .app bundle Contents/Resources/Sounds/coin.wav
        if let mainURL = Bundle.main.url(forResource: "coin", withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "coin", withExtension: "wav") {
            return mainURL
        }

        // 2. Resource bundle placed inside Contents/Resources/
        if let resourceBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("PanoSplat3D_PanoSplat3DCore.bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let bundledURL = resourceBundle.url(forResource: "coin", withExtension: "wav", subdirectory: "Sounds")
            ?? resourceBundle.url(forResource: "coin", withExtension: "wav") {
            return bundledURL
        }

        // 3. SwiftPM / Xcode test bundle (Bundle.module)
        if let moduleURL = Bundle.module.url(forResource: "coin", withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: "coin", withExtension: "wav") {
            return moduleURL
        }

        // 4. Fallback: project directory sibling `coin.wav`
        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("coin.wav")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        let appSibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("coin.wav")
        if FileManager.default.fileExists(atPath: appSibling.path) {
            return appSibling
        }

        return nil
    }

    /// Plays `coin.wav` for a completed export (falls back to macOS "Glass" system sound if unavailable).
    public func playSuccess() {
        activeSound?.stop()
        if let url = Self.locateSuccessSoundURL(),
           let sound = NSSound(contentsOf: url, byReference: false) {
            activeSound = sound
            sound.play()
        } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
            activeSound = fallback
            fallback.play()
        } else {
            NSSound.beep()
        }
    }

    /// Plays the native macOS alert sound when an export fails.
    public func playError() {
        activeSound?.stop()
        NSSound.beep()
    }
}
