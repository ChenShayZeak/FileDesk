import XCTest
@testable import FileDesk

final class RecentFilesTests: XCTestCase {
    @MainActor
    func testTrashingFolderClearsOnlyItsRecentsEvenAfterPartialFailure() async throws {
        let manager = FileManager.default
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = manager.temporaryDirectory.appendingPathComponent(suite, isDirectory: true).standardizedFileURL
        let folder = root.appendingPathComponent("Folder-" + suite, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData()
        defer {
            var stale = false
            if let moved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
               moved.lastPathComponent == folder.lastPathComponent { try? manager.removeItem(at: moved) }
            try? manager.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let nested = folder.appendingPathComponent("notes.txt")
        let sibling = root.appendingPathComponent(folder.lastPathComponent + "-other.txt")
        for file in [nested, sibling] { try Data().write(to: file) }
        preferences.set([nested.path, sibling.path], forKey: "recentFilePaths")
        let model = BrowserModel(preferences: preferences)
        model.perform(.trash(sources: [folder, root.appendingPathComponent("missing")]))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isWorking && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.recentFilePaths, [sibling.path])
        let relaunched = BrowserModel(preferences: preferences)
        XCTAssertEqual(relaunched.recentFilePaths, [sibling.path])
        var trashed: NSURL?
        try manager.trashItem(at: sibling, resultingItemURL: &trashed)
        defer { if let trashed { try? manager.removeItem(at: trashed as URL) } }
        await relaunched.refreshRecentFiles()
        XCTAssertTrue(relaunched.recentFilePaths.isEmpty)
    }

    func testRefreshKeepsFilesOnDisconnectedVolume() async {
        let offline = RecentFile(URL(fileURLWithPath: "/Volumes/" + UUID().uuidString + "/notes.txt"))
        let refreshed = await RecentFile.refresh([offline])
        XCTAssertEqual(refreshed.map(\.path), [offline.path])
    }

    @MainActor
    func testRenamesUpdateLegacyHistoryWithoutChangingOrder() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(suite, isDirectory: true).standardizedFileURL
        let folder = root.appendingPathComponent("Docs", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let first = root.appendingPathComponent("other.txt")
        let old = folder.appendingPathComponent("notes.txt")
        try Data().write(to: first)
        try Data("original".utf8).write(to: old)
        preferences.set([first.path, old.path], forKey: "recentFilePaths")
        let model = BrowserModel(preferences: preferences)

        func rename(_ url: URL, to name: String) async throws {
            model.perform(.rename(source: url, name: name))
            let deadline = ContinuousClock.now + .seconds(5)
            while model.isWorking && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isWorking)
        }
        try await rename(old, to: "Notes.txt")
        XCTAssertEqual(model.recentFilePaths, [first.path, folder.appendingPathComponent("Notes.txt").path])
        try await rename(folder, to: "Archive")
        let renamed = root.appendingPathComponent("Archive/Notes.txt")
        XCTAssertEqual(model.recentFilePaths, [first.path, renamed.path])
        try await rename(renamed, to: "bad/name")
        XCTAssertEqual(model.recentFilePaths, [first.path, renamed.path])

        let external = root.appendingPathComponent("Archive/renamed.txt")
        try manager.moveItem(at: renamed, to: external)
        try Data("different file".utf8).write(to: renamed)
        let relaunched = BrowserModel(preferences: preferences)
        await relaunched.refreshRecentFiles()
        XCTAssertEqual(relaunched.recentFilePaths, [first.path, external.path])
        XCTAssertEqual(relaunched.recentFile(at: external.path)?.url.path, external.path)
        XCTAssertEqual(BrowserModel(preferences: preferences).recentFilePaths, [first.path, external.path])

        try manager.removeItem(at: renamed)
        try manager.moveItem(at: external, to: renamed)
        XCTAssertEqual(relaunched.recentFile(at: external.path)?.url.path, renamed.path)
    }

    @MainActor
    func testRecentsTrackSuccessfulOpensAndSurviveRelaunch() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(suite, isDirectory: true).standardizedFileURL
        let subfolder = root.appendingPathComponent("Folder", isDirectory: true)
        try manager.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let first = root.appendingPathComponent("notes.txt")
        let second = subfolder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: first)
        try Data().write(to: second)
        let model = BrowserModel(preferences: preferences)
        model.open(FileSystem.item(at: subfolder)) { _ in XCTFail("Folders should navigate"); return false }
        model.open(FileSystem.item(at: first)) { _ in false }
        XCTAssertTrue(model.recentFilePaths.isEmpty)
        for url in [first, second, first] {
            model.open(FileSystem.item(at: url)) { $0 == url }
        }
        XCTAssertEqual(model.recentFilePaths, [first.path, second.path])

        let result = await FileSystem().perform(.encrypt(source: first, password: "test password"))
        let encrypted = try XCTUnwrap(result.encryptedCopy?.encrypted)
        let item = FileSystem.item(at: encrypted)
        await model.unlock(item, password: "incorrect")
        XCTAssertEqual(model.recentFilePaths, [first.path, second.path])
        await model.unlock(item, password: "test password")
        XCTAssertEqual(model.recentFilePaths, [encrypted.path, first.path, second.path])
        let closed = await model.closeSession()
        XCTAssertTrue(closed)

        let relaunched = BrowserModel(preferences: preferences)
        XCTAssertEqual(relaunched.recentFilePaths, model.recentFilePaths)
        XCTAssertEqual(relaunched.recentFile(at: encrypted.path)?.isEncrypted, true)
        try manager.removeItem(at: second)
        XCTAssertNil(relaunched.recentFile(at: second.path))
        XCTAssertFalse(relaunched.recentFilePaths.contains(second.path))
        relaunched.removeRecentFile(second.path)
        XCTAssertEqual(BrowserModel(preferences: preferences).recentFilePaths, [encrypted.path, first.path])
    }
}
