import Foundation
import Testing
@testable import PanoSplat3DCore

@Suite("Brush Engine Auto-Discovery & Bundle Resolution")
struct BrushEngineLocatorTests {
    @Test("Automatically resolves Brush.app bundle to Contents/MacOS/brush executable")
    func resolveAppBundle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoSplat3D-BrushBundleTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appBundle = tempDir.appendingPathComponent("Brush.app", isDirectory: true)
        let macOSDir = appBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>brush</string>
            <key>CFBundleIdentifier</key>
            <string>com.example.brush</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: appBundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let binaryURL = macOSDir.appendingPathComponent("brush")
        try "#!/bin/sh\necho ok\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let resolved = try BrushEngineLocator.resolveExecutable(from: appBundle)
        #expect(resolved.displayURL.standardizedFileURL == appBundle.standardizedFileURL)
        #expect(resolved.executableURL.standardizedFileURL == binaryURL.standardizedFileURL)

        let suiteName = "PanoSplat3D.test.\(UUID().uuidString)"
        let locator = BrushEngineLocator(userDefaultsSuiteName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let saved = try locator.saveUserSelection(appBundle)
        #expect(saved.source == .userSelected)
        #expect(saved.executableURL.standardizedFileURL == binaryURL.standardizedFileURL)

        let discovered = locator.discover()
        #expect(discovered?.executableURL.standardizedFileURL == binaryURL.standardizedFileURL)
        #expect(discovered?.source == .userSelected)
    }

    @Test("Automatically discovers brush_app in project directory")
    func discoverProjectFolderBrushApp() {
        let suiteName = "PanoSplat3D.test.\(UUID().uuidString)"
        let locator = BrushEngineLocator(userDefaultsSuiteName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let projectBrushApp = projectDir.appendingPathComponent("brush_app")

        if FileManager.default.isExecutableFile(atPath: projectBrushApp.path) {
            let discovered = locator.discover(additionalSearchDirectories: [projectDir])
            #expect(discovered != nil)
            #expect(discovered?.executableURL.lastPathComponent == "brush_app")
        }
    }

    @Test("Selects Apple Silicon tar.xz asset from GitHub release JSON")
    func selectAppleSiliconReleaseAsset() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "assets": [
            {
              "name": "brush-app-aarch64-apple-darwin.tar.xz.sha256",
              "size": 99,
              "browser_download_url": "https://example.com/brush.tar.xz.sha256"
            },
            {
              "name": "brush-app-x86_64-unknown-linux-gnu.tar.xz",
              "size": 50000000,
              "browser_download_url": "https://example.com/brush-linux.tar.xz"
            },
            {
              "name": "brush-app-aarch64-apple-darwin.tar.xz",
              "size": 41447012,
              "browser_download_url": "https://example.com/brush-mac.tar.xz"
            }
          ]
        }
        """
        let selected = BrushInstaller.selectAppleSiliconAsset(from: Data(json.utf8))
        #expect(selected?.versionTag == "v0.3.0")
        #expect(selected?.assetName == "brush-app-aarch64-apple-darwin.tar.xz")
        #expect(selected?.expectedBytes == 41_447_012)
        #expect(selected?.downloadURL.absoluteString == "https://example.com/brush-mac.tar.xz")
    }

    @Test("Extracts tar.xz archive and installs brush_app into Tools directory")
    func extractAndInstallBrushTarXz() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("BrushInstallTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let payloadDir = tempRoot.appendingPathComponent("payload/brush-app-aarch64-apple-darwin", isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        let fakeBinary = payloadDir.appendingPathComponent("brush_app")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: fakeBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let archiveURL = tempRoot.appendingPathComponent("brush-app-aarch64-apple-darwin.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archiveURL.path, "-C", tempRoot.appendingPathComponent("payload").path, "brush-app-aarch64-apple-darwin"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let extractedDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try BrushInstaller.extractArchive(archiveURL, to: extractedDir)

        let toolsDir = tempRoot.appendingPathComponent("Tools", isDirectory: true)
        let installed = try BrushInstaller.installExtractedBinary(from: extractedDir, into: toolsDir)
        #expect(installed != nil)
        #expect(installed?.source == .installedInAppSupport)
        #expect(installed?.executableURL.path == toolsDir.appendingPathComponent("brush_app").path)
        #expect(fm.isExecutableFile(atPath: toolsDir.appendingPathComponent("brush_app").path))
    }
}
