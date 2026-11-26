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
}
