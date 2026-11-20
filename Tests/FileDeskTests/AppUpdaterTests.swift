import Foundation
import XCTest
@testable import FileDesk

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testInstallReportsCompletedTransitionsAndSkipsCurrentVersion() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        let app = root.appending(path: "Installed.app")
        try manager.createDirectory(at: repo.appending(path: "scripts"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": "local.filedesk.app", "CFBundleShortVersionString": "1.0.0",
                    "CFBundleExecutable": "FileDesk", "CFBundlePackageType": "APPL"]
        func writeInfo(_ url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
        }
        try writeInfo(app.appending(path: "Contents/Info.plist"))
        info["CFBundleShortVersionString"] = "1.1.0"
        try writeInfo(repo.appending(path: "Info.plist"))
        try """
        set -eu
        contents="dist/文件桌.app/Contents"
        mkdir -p "$contents/MacOS"
        cp Info.plist "$contents/"
        cp /usr/bin/true "$contents/MacOS/FileDesk"
        /usr/bin/codesign --force --sign - "dist/文件桌.app"
        """.write(to: repo.appending(path: "scripts/build-app.sh"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."],
                     ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false",
                      "commit", "-qm", "test fixture"], ["-c", "tag.gpgSign=false", "tag", "1.1.0"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.currentDirectoryURL = repo
            git.arguments = args
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let updater = AppUpdater(repository: repo.path)
        let latest = try await updater.latest()
        let release = try XCTUnwrap(latest)
        var stages: [UpdateStage] = []
        let wrongTag = AppRelease(tag: release.tag, objectID: String(repeating: "0", count: 40))
        do {
            _ = try await updater.install(wrongTag, at: app) { stages.append($0) }
            XCTFail("A mismatched tag must not be installed")
        } catch {
            XCTAssertEqual(stages, [.downloading])
            XCTAssertEqual(try AppUpdater.installedVersion(at: app), "1.0.0")
        }
        stages.removeAll()
        let installed = try await updater.install(release, at: app) { stages.append($0) }
        XCTAssertTrue(installed)
        XCTAssertEqual(stages, [.downloading, .building, .verifying, .installing])
        XCTAssertEqual(try AppUpdater.installedVersion(at: app), release.version)
        let repeated = try await updater.install(release, at: app) { _ in XCTFail("Already up to date") }
        XCTAssertFalse(repeated)
    }

    func testUpdateUsesRenamedInstallationWhenLaunchPathDisappears() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let old = root.appendingPathComponent("文件桌.app", isDirectory: true)
        let renamed = root.appendingPathComponent("FileDesktop.app", isDirectory: true)
        try manager.createDirectory(at: old.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var info = ["CFBundleIdentifier": "local.filedesk.app", "CFBundleShortVersionString": "1.0.0"]
        func writeInfo(to app: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: app.appending(path: "Contents/Info.plist"))
        }
        try writeInfo(to: old)
        XCTAssertEqual(try AppUpdater.installedApp(launchedFrom: old).url.path, old.path)
        try manager.moveItem(at: old, to: renamed)
        let resolved = try AppUpdater.installedApp(launchedFrom: old)
        XCTAssertEqual(resolved.url.path, renamed.path)
        XCTAssertEqual(resolved.version, "1.0.0")
        XCTAssertEqual(try AppUpdater.installedApp(launchedFrom: renamed).url.path, renamed.path)
        info["CFBundleIdentifier"] = "example.other"
        try writeInfo(to: renamed)
        XCTAssertThrowsError(try AppUpdater.installedApp(launchedFrom: old))
    }

    func testLatestStableTagUsesNumericOrderAndIgnoresUnrelatedRefs() {
        let hash = String(repeating: "a", count: 40)
        let refs = ["refs/tags/v1.9.9", "refs/tags/1.10.0", "refs/tags/v2.0.0-beta.1", "refs/tags/preview",
                    "refs/heads/v3.0.0", "refs/tags/v01.20.0", "refs/tags/1.10.0^{}"]
        let output = refs.reversed().map { hash + "\t" + $0 }.joined(separator: "\n")
        XCTAssertEqual(AppRelease.latest(in: output), AppRelease(tag: "1.10.0", objectID: hash))
        XCTAssertNil(AppRelease.latest(in: ""))
        XCTAssertNil(AppRelease.latest(in: "invalid\trefs/tags/v9.0.0"))
        XCTAssertEqual(AppRelease.latest(in: hash + "\trefs/tags/v0.3.1")?.version, "0.3.1")
    }
}
