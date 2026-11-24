import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import FileDesk

final class FileOperationsTests: XCTestCase {
    private let fs = FileSystem()
    private let sessions = EncryptedFileSessions()

    func testNewFileMenuFormatsCreateReadableDocumentsInChosenFolder() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in NewFileFormat.allCases {
            let prompt = NamePrompt(title: "", initialName: "", target: .file(directory, format))
            let result = await fs.perform(prompt.operation("草稿.v1"))
            let name = "草稿.v1." + format.rawValue
            XCTAssertEqual(result.outputName, name, result.failures.joined())
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            switch format {
            case .txt, .md, .csv:
                XCTAssertTrue(data.isEmpty)
            case .rtf:
                XCTAssertNotNil(NSAttributedString(rtf: data, documentAttributes: nil))
            case .json:
                XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], [:])
            case .html:
                let document = try XMLDocument(data: data, options: .documentTidyHTML)
                XCTAssertEqual(try document.nodes(forXPath: "/html/body").count, 1)
            }
        }
    }

    func testNewFileRejectsInvalidNamesAndNeverOverwrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = NamePrompt(title: "", initialName: "", target: .file(directory, .txt))
        let result = await fs.perform(prompt.operation("笔记.TXT"))
        XCTAssertEqual(result.outputName, "笔记.TXT")
        let file = directory.appendingPathComponent("笔记.TXT")
        let original = Data("existing text".utf8)
        try original.write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for name in ["笔记.TXT", "link", "  ", ".", "..", "../escape", "bad:name"] {
            let rejected = await fs.perform(prompt.operation(name))
            XCTAssertEqual(rejected.completed, 0, name)
            XCTAssertFalse(rejected.failures.isEmpty, name)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    @MainActor
    func testNativeDragExportsEachSelectedFileAsAFileURL() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["普通 文件.txt", "copy.filedesk"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let items = FileDragArea.DragView.draggingItems(for: urls, at: .zero)
        XCTAssertTrue(pasteboard.writeObjects(items.compactMap { $0.item as? NSPasteboardWriting }))
        let received = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(received, urls)
    }

    @MainActor
    func testDroppedFileURLsMoveTheDraggedBatchIndependentlyOfSelection() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Favorite", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sources = ["first file.txt", "second.txt"].map { root.appendingPathComponent($0) }
        for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }
        let model = BrowserModel()
        model.navigate(to: root)
        let providers = sources.map { FileSystem.item(at: $0).dragProvider }
        XCTAssertFalse(model.moveDroppedFiles([], to: destination))
        XCTAssertTrue(model.moveDroppedFiles([providers[0], NSItemProvider(object: "text" as NSString)], to: destination))
        let failureDeadline = ContinuousClock.now + .seconds(5)
        while model.notice == nil && ContinuousClock.now < failureDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        model.notice = nil
        XCTAssertTrue(model.moveDroppedFiles(providers, to: destination))
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: sources.last!.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for source in sources {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)),
                           Data(source.lastPathComponent.utf8))
        }
    }

    func testFileDragProvidesOriginalURLAndReadableFileContents() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("例 子.txt")
        let contents = Data("drag payload".utf8)
        try contents.write(to: file)
        let provider = FileSystem.item(at: file).dragProvider
        XCTAssertEqual(provider.suggestedName, file.lastPathComponent)
        func read(_ type: UTType) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        }
        let urlData = try await read(.fileURL)
        XCTAssertEqual(URL(dataRepresentation: urlData, relativeTo: nil)?.path, file.path)
        let text = try await read(.plainText)
        XCTAssertEqual(text, contents)
        XCTAssertTrue(FileSystem.item(at: folder).dragProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    }

    @MainActor
    func testGridShiftSelectionKeepsAnchorAndUsesVisibleOrder() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["A", "B", "C", "D", "E"].map { root.standardizedFileURL.appendingPathComponent($0) }
        for url in urls.reversed() { try Data().write(to: url) }
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BrowserModel(preferences: preferences)
        model.navigate(to: root)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.items.map(\.url), urls)
        model.selectItem(urls[2], modifiers: [])
        XCTAssertEqual(model.extendGridSelection(rows: 1, columns: 2), urls[4])
        XCTAssertEqual(model.selection, Set(urls[2...4]))
        XCTAssertNil(model.extendGridSelection(rows: 1, columns: 2))
        XCTAssertEqual(model.extendGridSelection(rows: -1, columns: 2), urls[2])
        XCTAssertEqual(model.selection, [urls[2]])
        XCTAssertEqual(model.extendGridSelection(rows: -1, columns: 2), urls[0])
        XCTAssertEqual(model.selection, Set(urls[0...2]))
        model.selectItem(urls[2], modifiers: [])
        model.selectItem(urls[4], modifiers: .shift)
        XCTAssertEqual(model.selectedItems.map(\.url), Array(urls[2...4]))
        XCTAssertEqual(model.fileURLsForDrag(startingAt: urls[3]), Array(urls[2...4]))
        XCTAssertEqual(model.fileURLsForDrag(startingAt: urls[0]), [urls[0]])
        model.selectItem(urls[0], modifiers: .shift)
        XCTAssertEqual(model.selectedItems.map(\.url), Array(urls[0...2]))
        model.selectItem(urls[4], modifiers: .command)
        model.selectItem(urls[3], modifiers: [.command, .shift])
        XCTAssertEqual(model.selectedItems.map(\.url), urls)
        model.selectItem(urls[1], modifiers: .command)
        XCTAssertFalse(model.selection.contains(urls[1]))
        model.selection = []
        model.selectItem(urls[0], modifiers: .shift)
        XCTAssertEqual(model.selection, [urls[0]])
    }

    func testMoveConflictsReplaceOrSkipEachItemAndKeepChangedTargets() async throws {
        let root = try makeDirectory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let sources = ["replace", "skip", "changed", "unique"].map { root.appendingPathComponent($0) }
        for url in sources {
            try Data("new".utf8).write(to: url)
            if url.lastPathComponent != "unique" {
                try Data("old".utf8).write(to: destination.appendingPathComponent(url.lastPathComponent))
            }
        }
        let result = await fs.perform(.move(sources: sources, destination: destination)) { source, target in
            if source.lastPathComponent == "changed" {
                do { try Data("edited".utf8).write(to: target, options: .atomic) }
                catch { XCTFail(error.localizedDescription) }
            }
            XCTAssertNotEqual(source.lastPathComponent, "unique")
            return source.lastPathComponent != "skip"
        }
        XCTAssertEqual(result.completed, 2, result.failures.joined())
        XCTAssertEqual(result.failures.count, 1)
        for (index, expected) in ["new", "old", "edited", "new"].enumerated() {
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(sources[index].lastPathComponent)), expected)
            XCTAssertEqual(fm.fileExists(atPath: sources[index].path), index == 1 || index == 2)
        }
    }

    func testMoveReplacesFolderAndNeverReplacesAnAncestor() async throws {
        let fm = FileManager.default
        let root = try makeDirectory()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let target = destination.appendingPathComponent("folder", isDirectory: true)
        for folder in [source, target] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data().write(to: source.appendingPathComponent("new"))
        try Data().write(to: target.appendingPathComponent("old"))
        let result = await fs.perform(.move(sources: [source], destination: destination)) { _, _ in true }
        XCTAssertEqual(result.completed, 1, result.failures.joined())
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["new"])
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        let nested = target.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let refused = await fs.perform(.move(sources: [nested], destination: destination)) { _, _ in
            XCTFail("An ancestor must never be offered for replacement")
            return false
        }
        XCTAssertEqual(refused.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: nested.path))
    }

    func testMissingSevenZipRequestsConsentBeforeInstallingOrExtracting() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = SevenZip(systemPaths: [], root: directory.appending(path: "Tools"))
        let fileSystem = FileSystem(sevenZip: tools)
        let source = directory.appending(path: "资料.zip")
        try Data().write(to: source)
        let result = await fileSystem.perform(.extract(source))
        XCTAssertEqual(result.archiveNeedingSevenZip, source)
        XCTAssertEqual(result.completed, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["资料.zip"])

        XCTAssertThrowsError(try tools.install(packageAt: source))
        XCTAssertNil(tools.executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.root.path))
    }

    func testQuickExtractUnpacksZipAndTarGzWithoutOverwriting() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = [
            ("zip", "UEsDBBQAAAAAAK9oc111JIE9DgAAAA4AAAAOAAAAZG9jcy9oZWxsby50eHRGaWxlRGVzayB0ZXN0ClBLAQIUAxQAAAAAAK9oc111JIE9DgAAAA4AAAAOAAAAAAAAAAAAAACAAQAAAABkb2NzL2hlbGxvLnR4dFBLBQYAAAAAAQABADwAAAA6AAAAAAA="),
            ("tar.gz", "H4sIAJuD/moC/+3NQQrCMAAEwJx9RV+gKda+QPyH2IBioGAi+HyjF8G7gjhz2WUvO82HsjqmnOdlvdXwEbEZh+GZzXvG2I+v/tj7uFmPoYvhC66l7i/tPvyn3SmnbSrnrqZSFwEAAAAAAAAAAIAfcQea5YF3ACgAAA==")
        ]
        for (index, fixture) in fixtures.enumerated() {
            var archive = directory.appendingPathComponent("测试 包." + fixture.0)
            let payload = try XCTUnwrap(Data(base64Encoded: fixture.1))
            try payload.write(to: archive)
            var flags = URLResourceValues()
            flags.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeWebDownload"]
            try archive.setResourceValues(flags)
            let result = await fs.perform(.extract(archive))
            let name = index == 0 ? "测试 包" : "测试 包 2"
            XCTAssertEqual(result.outputName, name, result.failures.joined())
            let extracted = directory.appendingPathComponent(name + "/docs/hello.txt")
            XCTAssertEqual(try String(contentsOf: extracted), "FileDesk test\n")
            XCTAssertNotNil(try extracted.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            XCTAssertEqual(try Data(contentsOf: archive), payload)
        }
        let broken = directory.appendingPathComponent("损坏.zip")
        try Data("invalid".utf8).write(to: broken)
        let failed = await fs.perform(.extract(broken))
        XCTAssertFalse(failed.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("损坏").path))
    }

    @MainActor
    func testHiddenItemsAreShownByDefaultAndRememberUserChoice() throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BrowserModel(preferences: preferences)
        XCTAssertTrue(model.showHidden)
        model.showHidden = false
        XCTAssertFalse(BrowserModel(preferences: preferences).showHidden)
        model.showHidden = true
        XCTAssertTrue(BrowserModel(preferences: preferences).showHidden)
    }

    func testSetHiddenRoundTripOnFilesFoldersAndLinks() async throws {
        let root = try makeDirectory()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let link = root.appendingPathComponent("link")
        let target = root.appendingPathComponent("target")
        let dotfile = root.appendingPathComponent(".env")
        for url in [file, target, dotfile] { try Data("contents".utf8).write(to: url) }
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        let sources = [file, folder, link]
        let hide = await fs.perform(.setHidden(sources: sources, hidden: true))
        XCTAssertEqual(hide.completed, 3, hide.failures.joined())
        let shown = try await fs.read(root, showHidden: false, sort: .name)
        XCTAssertEqual(shown.map(\.name), ["target"])
        let all = try await fs.read(root, showHidden: true, sort: .name)
        XCTAssertEqual(Set(all.filter(\.isHidden).map(\.name)), ["file.txt", "folder", "link", ".env"])

        let unhide = await fs.perform(.setHidden(sources: [dotfile] + sources, hidden: false))
        XCTAssertEqual(unhide.completed, 3)
        XCTAssertEqual(unhide.failures.count, 1)
        let restored = try await fs.read(root, showHidden: false, sort: .name)
        XCTAssertEqual(Set(restored.map(\.name)), ["file.txt", "folder", "link", "target"])
        XCTAssertEqual(try String(contentsOf: file), "contents")
        XCTAssertEqual(try String(contentsOf: dotfile), "contents")
    }

    func testHiddenItemsAreMarkedAndRespectVisibilitySetting() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("普通.txt"))
        try Data().write(to: directory.appendingPathComponent(".env"))
        var folder = directory.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var flags = URLResourceValues()
        flags.isHidden = true
        try folder.setResourceValues(flags)

        let all = try await fs.read(directory, showHidden: true, sort: .name)
        XCTAssertEqual(Set(all.filter(\.isHidden).map(\.name)), [".env", "资料"])
        XCTAssertEqual(all.filter { !$0.isHidden }.map(\.name), ["普通.txt"])
        let visible = try await fs.read(directory, showHidden: false, sort: .name)
        XCTAssertEqual(visible.map(\.name), ["普通.txt"])
    }

    func testGoToFolderPreviewsHistoryUntilTypingAndAcceptsACompletion() {
        var input = FolderPathInput()
        let recent = ["/One", "/Two", "/Three", "/Four", "/", "/Six"]
        let history = input.candidates(recent: recent, completions: [], completedQuery: "")
        XCTAssertEqual(history, Array(recent.prefix(5)))
        input.move(down: true, in: history)
        XCTAssertEqual(input.text, "/One/")
        input.edit(input.text) // The native field editor echoes the preview.
        XCTAssertEqual(input.query, "")
        input.move(down: true, in: history)
        XCTAssertEqual(input.text, "/Two/")
        input.move(down: false, in: history)
        XCTAssertEqual(input.text, "/One/")
        XCTAssertEqual(input.candidates(recent: recent, completions: [], completedQuery: ""), history)

        input.edit(input.text + "Do")
        XCTAssertNil(input.selected)
        let matches = ["/One/Docs/", "/One/Downloads/"]
        XCTAssertTrue(input.candidates(recent: recent, completions: matches, completedQuery: "/One/D").isEmpty)
        let choices = input.candidates(recent: recent, completions: matches, completedQuery: "/One/Do")
        XCTAssertEqual(choices, matches)
        input.move(down: true, in: choices)
        input.move(down: true, in: choices)
        XCTAssertEqual(input.text, "/One/Downloads/")
        XCTAssertEqual(input.query, "/One/Do")
        input.accept(choices[1])
        XCTAssertEqual(input.query, "/One/Downloads/")
        input.edit("")
        input.move(down: false, in: input.candidates(recent: recent, completions: matches, completedQuery: "/One/Do"))
        XCTAssertEqual(input.text, "/")
    }

    func testFolderCompletionsPreserveTypedPathsAndOnlyOfferDirectories() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        for name in ["Daora", "Daora Test/子 目录", ".Hidden"] {
            try manager.createDirectory(at: base.appending(path: name), withIntermediateDirectories: true)
        }
        try Data().write(to: base.appending(path: "Daora.txt"))
        try manager.createSymbolicLink(at: base.appending(path: "Daora Link"), withDestinationURL: base.appending(path: "Daora"))
        for (input, expected) in [
            ("dao", ["Daora/", "Daora Link/", "Daora Test/"]),
            (base.path + "/Daora Test/子", [base.path + "/Daora Test/子 目录/"]),
            ("./Daora Test/", ["./Daora Test/子 目录/"]),
            (".hi", [".Hidden/"]), ("~", ["~/"]), ("..", ["../"]),
            ("", []), ("missing/", [])
        ] {
            let matches = await FileSystem.folderCompletions(for: input, relativeTo: base, showHidden: false)
            XCTAssertEqual(matches, expected, input)
        }
        let visible = await FileSystem.folderCompletions(for: "./", relativeTo: base, showHidden: false)
        XCTAssertFalse(visible.contains("./.Hidden/"))
    }

    @MainActor
    func testGoToFolderResolvesFilesAndDirectoriesAndRejectsMissingPaths() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("子 目录", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data().write(to: child.appendingPathComponent("文件"))
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BrowserModel(preferences: preferences)
        XCTAssertTrue(model.goToFolder(parent.path))
        XCTAssertTrue(model.goToFolder("子 目录"))
        XCTAssertEqual(model.directory, child.standardizedFileURL)
        for input in ["", "不存在", "不存在/文件"] {
            XCTAssertFalse(model.goToFolder(input))
            XCTAssertEqual(model.directory, child.standardizedFileURL)
        }
        model.query = "no match"
        XCTAssertTrue(model.goToFolder("文件"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedItems.map(\.name), ["文件"])
        XCTAssertEqual(model.directory, child.standardizedFileURL)
        let hidden = child.appendingPathComponent(".隐藏 文件")
        try Data().write(to: hidden)
        model.showHidden = false
        model.navigate(to: parent)
        XCTAssertTrue(model.goToFolder(hidden.absoluteString))
        let hiddenDeadline = ContinuousClock.now + .seconds(5)
        while model.isLoading && ContinuousClock.now < hiddenDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedItems.map(\.name), [hidden.lastPathComponent])
        XCTAssertFalse(model.showHidden)
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        XCTAssertEqual(model.recentPaths, [childPath, parentPath])
        model.goBack()
        XCTAssertEqual(model.directory, parent.standardizedFileURL)
        XCTAssertTrue(model.goToFolder("."))
        XCTAssertEqual(model.recentPaths, [parentPath, childPath])
        XCTAssertEqual(BrowserModel(preferences: preferences).recentPaths, [parentPath, childPath])
        model.removeRecentPath(parentPath)
        XCTAssertEqual(BrowserModel(preferences: preferences).recentPaths, [childPath])
        XCTAssertEqual(model.directory.path, parentPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parentPath))
        XCTAssertTrue(model.canGoForward)
        XCTAssertTrue(model.goToFolder("~"))
        XCTAssertEqual(model.directory, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    @MainActor
    func testFinderServiceAcceptsOnlyOneFolder() throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("测试 目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = base.appendingPathComponent("文档.txt")
        try Data().write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for (urls, expected) in [([folder], folder as URL?), ([file], nil), ([base, folder], nil)] {
            board.clearContents()
            XCTAssertTrue(board.writeObjects(urls.map { $0 as NSURL }))
            XCTAssertEqual(FileDeskAppDelegate.selectedFolder(on: board)?.path, expected?.path)
        }
        board.clearContents()
        XCTAssertTrue(board.setPropertyList([folder.path], forType: .init("NSFilenamesPboardType")))
        XCTAssertEqual(FileDeskAppDelegate.selectedFolder(on: board)?.path, folder.path)
    }

    @MainActor
    func testExternalOpenRoutesFoldersAndEncryptedFiles() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel()
        model.openExternalURL(folder) { _ in XCTFail("文件夹不应触发解密") }
        XCTAssertEqual(model.directory.path, folder.standardizedFileURL.path)
        XCTAssertNil(model.notice)

        let encrypted = folder.appendingPathComponent("示例.FILEDESK")
        try Data().write(to: encrypted)
        var requested: FileItem?
        model.openExternalURL(encrypted) { requested = $0 }
        XCTAssertEqual(requested?.url, encrypted.standardizedFileURL)
        XCTAssertEqual(requested?.isEncrypted, true)

        let file = folder.appendingPathComponent("示例.txt")
        try Data().write(to: file)
        let package = folder.appendingPathComponent("示例.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for url in [file, package, folder.appendingPathComponent("不存在"), URL(string: "https://example.com")!] {
            model.notice = nil
            model.openExternalURL(url) { _ in XCTFail("不支持的项目不应触发解密") }
            XCTAssertNotNil(model.notice)
            XCTAssertEqual(model.directory.path, folder.standardizedFileURL.path)
        }
    }

    func testReadOnlySessionRemovesCopyWithoutReplacingCiphertext() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [Data(), Data(repeating: 0x7b, count: 1_048_576) + Data(UInt8(0)..<UInt8(128))]

        for (index, contents) in samples.enumerated() {
            let source = directory.appendingPathComponent("原件-\(index).bin")
            try contents.write(to: source)
            let password = "测试密码"
            let encrypted = try await encrypt(source, password: password)
            let ciphertext = try Data(contentsOf: encrypted)
            let session = try await sessions.open(encrypted, password: password)
            XCTAssertEqual(try Data(contentsOf: session.file), contents)
            XCTAssertNotEqual(session.file, source)

            let updated = try await sessions.close(draft: nil)
            XCTAssertFalse(updated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.file.deletingLastPathComponent().path))
            XCTAssertEqual(try Data(contentsOf: encrypted), ciphertext)
            XCTAssertEqual(try Data(contentsOf: source), contents)

            let duplicate = await fs.perform(.encrypt(source: source, password: "其他密码"))
            XCTAssertEqual(duplicate.completed, 0)
            XCTAssertNil(duplicate.encryptedCopy)
        }
    }

    @MainActor
    func testRenamedEncryptedFilesAreRecognizedAndStillAuthenticate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("原文.txt")
        let bytes = Data("原始内容".utf8)
        try bytes.write(to: plain)
        let password = "test-password"
        let encrypted = try await encrypt(plain, password: password)
        let ciphertext = try Data(contentsOf: encrypted)
        let result = await fs.perform(.rename(source: encrypted, name: "新名称"))
        XCTAssertEqual(result.outputName, "新名称.txt.filedesk")
        let renamed = directory.appendingPathComponent("新名称.txt.filedesk")
        XCTAssertEqual(try Data(contentsOf: renamed), ciphertext)
        let initial = try await sessions.open(renamed, password: password)
        XCTAssertEqual(initial.text, "原始内容")
        _ = try await sessions.close(draft: nil)

        let model = BrowserModel()
        for name in ["已改名.txt", "没有后缀"] {
            let external = directory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: renamed, to: external)
            let listed = try await fs.read(directory, showHidden: true, sort: .name)
            let item = try XCTUnwrap(listed.first { $0.name == name })
            XCTAssertTrue(item.checkingEncryption().isEncrypted)
            var routed = false
            model.openExternalURL(external) { routed = $0.isEncrypted }
            XCTAssertTrue(routed)
            do {
                _ = try await sessions.open(external, password: "wrong")
                XCTFail("Incorrect password accepted")
            } catch FileCipherError.authenticationFailed {}
            let session = try await sessions.open(external, password: password)
            XCTAssertEqual(session.title, name)
            XCTAssertEqual(session.text, "原始内容")
            _ = try await sessions.close(draft: nil)
            XCTAssertEqual(try Data(contentsOf: external), ciphertext)
            try FileManager.default.moveItem(at: external, to: renamed)
        }
        XCTAssertFalse(FileSystem.item(at: plain).checkingEncryption().isEncrypted)
    }

    func testPostEncryptionCleanupPreservesFilesChangedAfterEncryption() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原文件.txt")
        let initial = Data("before".utf8)
        try initial.write(to: source)
        let result = await fs.perform(.encrypt(source: source, password: "测试密码"))
        let copy = try XCTUnwrap(result.encryptedCopy)
        XCTAssertEqual(copy.original, source)
        XCTAssertEqual(try Data(contentsOf: source), initial)
        let encrypted = try Data(contentsOf: copy.encrypted)

        let changed = Data("edited".utf8)
        try changed.write(to: source)
        let changedSource = await fs.perform(.trashEncryptedOriginal(copy))
        XCTAssertEqual(changedSource.completed, 0)
        XCTAssertFalse(changedSource.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertEqual(try Data(contentsOf: copy.encrypted), encrypted)

        try initial.write(to: source)
        try Data(encrypted.dropLast()).write(to: copy.encrypted)
        let changedCopy = await fs.perform(.trashEncryptedOriginal(copy))
        XCTAssertEqual(changedCopy.completed, 0)
        XCTAssertFalse(changedCopy.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), initial)
    }

    func testInternalDraftAndExternalEditsAreReencryptedAtTheSamePath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原件.txt")
        let initialContents = Data([0xef, 0xbb, 0xbf]) + Data("原内容".utf8)
        try initialContents.write(to: source)
        let password = "测试密码"
        let encrypted = try await encrypt(source, password: password)

        let session = try await sessions.open(encrypted, password: password)
        XCTAssertEqual(session.text, "原内容")
        let internalUpdated = try await sessions.close(draft: "在文件桌编辑")
        XCTAssertTrue(internalUpdated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.file.path))

        let externalSession = try await sessions.open(encrypted, password: password)
        XCTAssertEqual(externalSession.text, "在文件桌编辑")
        XCTAssertEqual(try Data(contentsOf: externalSession.file), Data([0xef, 0xbb, 0xbf]) + Data("在文件桌编辑".utf8))
        try Data("从默认应用保存".utf8).write(to: externalSession.file, options: .atomic)
        let externalUpdated = try await sessions.close(draft: nil)
        XCTAssertTrue(externalUpdated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalSession.file.path))

        let reopened = try await sessions.open(encrypted, password: password)
        XCTAssertEqual(reopened.text, "从默认应用保存")
        _ = try await sessions.close(draft: nil)
        XCTAssertEqual(try Data(contentsOf: source), initialContents)
    }

    func testWritebackConflictRetainsBothNewCiphertextAndOpenDraft() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原件.txt")
        try Data("原内容".utf8).write(to: source)
        let password = "测试密码"
        let encrypted = try await encrypt(source, password: password)
        let session = try await sessions.open(encrypted, password: password)
        let updatedElsewhere = Data("由其他程序改写".utf8)
        try updatedElsewhere.write(to: encrypted, options: .atomic)

        do {
            _ = try await sessions.close(draft: "未写回的修改")
            XCTFail("Conflicting ciphertext must not be replaced")
        } catch EncryptedSessionError.originalChanged {
            XCTAssertEqual(try Data(contentsOf: encrypted), updatedElsewhere)
            XCTAssertEqual(try String(contentsOf: session.file, encoding: .utf8), "未写回的修改")
        }

        let discarded = try await sessions.close(draft: nil, discardingChanges: true)
        XCTAssertFalse(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.file.path))
        XCTAssertEqual(try Data(contentsOf: encrypted), updatedElsewhere)
    }

    func testExternalFixtureRejectsWrongPasswordDamageAndTruncation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Generated independently with PBKDF2-HMAC-SHA256 and AES-GCM.
        let base64 = "RkRFU0sBAAECAwQFBgcICQoLDA0ODwAAAAAAAAASWBSf2Nog1Qo+M74pVqqqsa3TtOZvAJn+xeUtx8PtalAeZg=="
        let fixture = try XCTUnwrap(Data(base64Encoded: base64))
        let password = "外部检查 e\u{301} 密码"
        var damaged = fixture
        damaged[damaged.count - 1] ^= 0x01
        let cases = [(fixture, "错误密码"), (Data(fixture.dropLast()), password), (damaged, password)]
        let input = directory.appendingPathComponent("fixture.txt.filedesk")

        for (contents, attempt) in cases {
            try contents.write(to: input)
            do {
                _ = try await sessions.open(input, password: attempt)
                _ = try await sessions.close(draft: nil)
                XCTFail("Invalid decryption unexpectedly succeeded")
            } catch is FileCipherError {
                XCTAssertFalse(FileManager.default.fileExists(atPath: input.deletingPathExtension().path))
            }
        }

        try fixture.write(to: input)
        let validSession = try await sessions.open(input, password: password)
        XCTAssertEqual(validSession.text, "文件桌\nAES-GCM\n")
        _ = try await sessions.close(draft: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: validSession.file.path))
    }

    func testChangingPasswordRequiresOldPasswordAndPreservesContent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原件.bin")
        let contents = Data(repeating: 0x9a, count: 1_048_601)
        try contents.write(to: source)
        let oldPassword = "旧密码"
        let newPassword = "新密码"
        let encrypted = try await encrypt(source, password: oldPassword)
        let original = try Data(contentsOf: encrypted)

        do {
            try await sessions.changePassword(encrypted, oldPassword: "错误密码", newPassword: newPassword)
            XCTFail("An incorrect password must not change ciphertext")
        } catch FileCipherError.authenticationFailed {
            XCTAssertEqual(try Data(contentsOf: encrypted), original)
        }

        try await sessions.changePassword(encrypted, oldPassword: oldPassword, newPassword: newPassword)
        XCTAssertNotEqual(try Data(contentsOf: encrypted), original)
        do {
            _ = try await sessions.open(encrypted, password: oldPassword)
            _ = try await sessions.close(draft: nil)
            XCTFail("The previous password should no longer open the file")
        } catch FileCipherError.authenticationFailed {}

        let reopened = try await sessions.open(encrypted, password: newPassword)
        XCTAssertEqual(try Data(contentsOf: reopened.file), contents)
        _ = try await sessions.close(draft: nil)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(children), Set([source.lastPathComponent, encrypted.lastPathComponent]))
    }

    func testRegularFileFinderTagsAppearInListingsAndRecursiveSearch() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("notes.txt")
        let data = Data("test contents".utf8)
        try data.write(to: file)
        let updated = await fs.perform(.setTags(item: file, tags: ["待办"]))
        XCTAssertEqual(updated.completed, 1, "\(updated.failures)")
        let fresh = URL(fileURLWithPath: file.path)
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["待办"])
        let listing = try await fs.read(nested, showHidden: false, sort: .name)
        XCTAssertEqual(listing.first?.tags, ["待办"])
        let hits = try await FileSystem.search(root, term: "待办", showHidden: false, sort: .name) { _ in }
        XCTAssertEqual(hits.map(\.url), [file.standardizedFileURL])
        let cleared = await fs.perform(.setTags(item: file, tags: []))
        XCTAssertEqual(cleared.completed, 1, "\(cleared.failures)")
        let refreshed = try await fs.read(nested, showHidden: false, sort: .name)
        XCTAssertEqual(refreshed.first?.tags, [])
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testFolderTagsPersistAndCanBeRemoved() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let tags = ["资料", "进行中"]

        let tagged = await fs.perform(.setTags(item: folder, tags: tags))
        XCTAssertEqual(tagged.completed, 1, "\(tagged.failures)")
        let items = try await FileSystem().read(directory, showHidden: false, sort: .name)
        XCTAssertEqual(Set(items.first?.tags ?? []), Set(tags))

        let cleared = await fs.perform(.setTags(item: folder, tags: []))
        XCTAssertEqual(cleared.completed, 1, "\(cleared.failures)")
        let refreshed = try await fs.read(directory, showHidden: false, sort: .name)
        XCTAssertEqual(refreshed.first?.tags, [])
    }

    private func encrypt(_ source: URL, password: String) async throws -> URL {
        let result = await fs.perform(.encrypt(source: source, password: password))
        XCTAssertEqual(result.completed, 1, "\(result.failures)")
        let file = source.appendingPathExtension("filedesk")
        XCTAssertEqual(result.outputName, file.lastPathComponent)
        return file
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
