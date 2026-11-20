import XCTest
@testable import FileDesk

final class RecursiveSearchTests: XCTestCase {
    @MainActor
    func testSearchFindsDistinctPathsAndRespectsVisibilityAndNavigation() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
        defer { try? manager.removeItem(at: directory) }
        let paths = ["Report.txt", "A/Report.txt", "B/Deep/Report.txt", ".hidden/Report.txt", "Test.app/Report.txt"]
        for path in paths {
            let url = directory.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try manager.createSymbolicLink(at: directory.appendingPathComponent("A/back"), withDestinationURL: directory)
        let taggedFolder = directory.appendingPathComponent("B/Deep", isDirectory: true)
        let tagged = await FileSystem().perform(.setTags(folder: taggedFolder, tags: ["归档"]))
        XCTAssertEqual(tagged.completed, 1)

        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "showHidden")
        let model = BrowserModel(preferences: preferences)
        func waitForResults() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while model.isLoading && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.readError)
        }

        model.navigate(to: directory)
        model.query = "missing"
        model.query = "report"
        try await waitForResults()
        XCTAssertEqual(model.items.map(\.url.path), paths.prefix(3).map { directory.appendingPathComponent($0).path }.sorted())
        XCTAssertEqual(Set(model.items.map(model.searchLocation)), [String(localized: "当前文件夹"), "A", "B/Deep"])

        let selected = directory.appendingPathComponent("A/Report.txt")
        model.selectItem(selected, modifiers: [])
        let visibleResults = model.items.map(\.url)
        model.showHidden = true
        XCTAssertEqual(model.items.map(\.url), visibleResults)
        try await waitForResults()
        XCTAssertEqual(model.selection, [selected])
        XCTAssertEqual(Set(model.items.map(\.url.path)), Set(paths.prefix(4).map { directory.appendingPathComponent($0).path }))
        model.showHidden = false
        try await waitForResults()
        XCTAssertEqual(model.items.map(\.url), visibleResults)
        XCTAssertEqual(model.selection, [selected])
        model.showHidden = true
        model.query = "归档"
        try await waitForResults()
        XCTAssertEqual(model.items.map(\.url), [taggedFolder])

        model.query = "Report"
        model.query = ""
        try await waitForResults()
        XCTAssertEqual(Set(model.items.map(\.name)), ["Report.txt", "A", "B", ".hidden", "Test.app"])
        model.query = "Report"
        model.navigate(to: taggedFolder)
        try await waitForResults()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.items.map(\.url.path), [taggedFolder.appendingPathComponent("Report.txt").path])
    }
}
