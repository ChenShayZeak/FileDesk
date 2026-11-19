import AppKit
import XCTest
@testable import FileDesk

final class FileOperationsTests: XCTestCase {
    private let fs = FileSystem()
    private let sessions = EncryptedFileSessions()

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
    func testGoToFolderResolvesPathsAndRejectsFilesWithoutChangingHistory() throws {
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
        for input in ["", "不存在", "文件"] {
            XCTAssertFalse(model.goToFolder(input))
            XCTAssertEqual(model.directory, child.standardizedFileURL)
        }
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

    func testFolderTagsPersistAndCanBeRemoved() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let tags = ["资料", "进行中"]

        let tagged = await fs.perform(.setTags(folder: folder, tags: tags))
        XCTAssertEqual(tagged.completed, 1, "\(tagged.failures)")
        let items = try await FileSystem().read(directory, showHidden: false, sort: .name)
        XCTAssertEqual(Set(items.first?.tags ?? []), Set(tags))

        let cleared = await fs.perform(.setTags(folder: folder, tags: []))
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
