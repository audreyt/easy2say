import Foundation
import XCTest

final class PreinstallScriptTests: XCTestCase {
    func testRemovesV2SAndEasy2sayAppsWithMatchingBundleID() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeApp(named: "v2s.app", bundleID: "com.franklioxygen.v2s", in: workspace)
        try writeApp(named: "Easy2say.app", bundleID: "com.franklioxygen.v2s", in: workspace)
        try writeApp(named: "Other.app", bundleID: "com.example.unrelated", in: workspace)

        try runPreinstall(applicationsDir: workspace)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("v2s.app").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Easy2say.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Other.app").path))
    }

    func testLeavesUnrelatedEasy2sayAppInPlace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeApp(named: "Easy2say.app", bundleID: "com.example.unrelated", in: workspace)

        try runPreinstall(applicationsDir: workspace)

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Easy2say.app").path))
    }

    func testSucceedsWhenLegacyAppsAreAbsent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try runPreinstall(applicationsDir: workspace)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Easy2SayPreinstall.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeApp(named name: String, bundleID: String, in directory: URL) throws {
        let contents = directory.appendingPathComponent(name).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    private func runPreinstall(applicationsDir: URL) throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging/macos/scripts/preinstall")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = [
            "EASY2SAY_APPLICATIONS_DIR": applicationsDir.path,
            "PATH": "/usr/bin:/bin",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
