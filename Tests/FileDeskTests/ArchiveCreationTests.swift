import Foundation
import XCTest
@testable import FileDesk

final class ArchiveCreationTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    func testFormatsRoundTripMultipleSelectionsAndSearchPaths() async throws {
        let root = try temporaryFolder()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("-项目", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for url in [folder, other] { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
        let first = folder.appendingPathComponent("@note\n1.txt")
        let second = other.appendingPathComponent(first.lastPathComponent)
        let hidden = folder.appendingPathComponent(".hidden")
        for (index, url) in [first, second, hidden].enumerated() { try Data([UInt8(index)]).write(to: url) }
        let unrelated = other.appendingPathComponent("unselected")
        try Data().write(to: unrelated)

        let formats: [(ArchiveFormat, [UInt8])] = [
            (.zip, [0x50, 0x4b]), (.sevenZip, [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]),
            (.tar, Array("ustar".utf8)), (.tarGzip, [0x1f, 0x8b]),
            (.tarBzip2, Array("BZh".utf8)), (.tarXZ, [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
        ]
        let fs = FileSystem()
        for (format, signature) in formats {
            let result = await fs.perform(.compress(sources: [folder, first, second], in: root, format: format))
            XCTAssertEqual(result.completed, 1, result.failures.joined())
            let archive = root.appendingPathComponent(try XCTUnwrap(result.outputName))
            let bytes = try Data(contentsOf: archive)
            XCTAssertTrue(bytes.dropFirst(format == .tar ? 257 : 0).starts(with: signature), format.rawValue)
            let extracted = root.appendingPathComponent("out-" + format.rawValue)
            try manager.createDirectory(at: extracted, withIntermediateDirectories: false)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", archive.path, "-C", extracted.path]
            try tar.run()
            tar.waitUntilExit()
            XCTAssertEqual(tar.terminationStatus, 0, format.rawValue)
            for path in ["-项目/@note\n1.txt", "other/@note\n1.txt", "-项目/.hidden"] {
                XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(path)),
                               try Data(contentsOf: root.appendingPathComponent(path)), format.rawValue)
            }
            XCTAssertFalse(manager.fileExists(atPath: extracted.appendingPathComponent("other/unselected").path))
        }
    }

    func testNameCollisionAndReadFailurePreserveExistingFiles() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let source = root.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: source)
        let existing = root.appendingPathComponent("file.txt.zip")
        let sentinel = Data("previous archive".utf8)
        try sentinel.write(to: existing)
        let fs = FileSystem()
        let result = await fs.perform(.compress(sources: [source], in: root, format: .zip))
        XCTAssertEqual(result.outputName, "file.txt 2.zip")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let entries = try manager.contentsOfDirectory(atPath: root.path).sorted()
        let failed = await fs.perform(.compress(sources: [source, root.appendingPathComponent("missing")], in: root, format: .zip))
        XCTAssertEqual(failed.completed, 0)
        XCTAssertFalse(failed.failures.isEmpty)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path).sorted(), entries)
    }
}
