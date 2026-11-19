import Foundation
import XCTest
@testable import FileDesk

final class AppUpdaterTests: XCTestCase {
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
