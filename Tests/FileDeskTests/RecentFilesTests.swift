import XCTest
@testable import FileDesk

final class RecentFilesTests: XCTestCase {
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
        relaunched.removeRecentFile(second.path)
        XCTAssertEqual(BrowserModel(preferences: preferences).recentFilePaths, [encrypted.path, first.path])
    }
}
