import Foundation

enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2", tarXZ = "tar.xz"

    private var arguments: [String] {
        switch self {
        case .zip: ["--format", "zip"]
        case .sevenZip: ["--format", "7zip"]
        case .tar: []
        case .tarGzip: ["-z"]
        case .tarBzip2: ["-j"]
        case .tarXZ: ["-J"]
        }
    }

    func write(_ sources: [URL], relativeTo directory: URL, to output: URL) throws {
        let root = directory.standardizedFileURL.pathComponents
        let paths = try Set(sources.map { url in
            let parts = url.standardizedFileURL.pathComponents
            guard url.isFileURL, parts.starts(with: root), parts.count > root.count else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return Array(parts.dropFirst(root.count))
        })
        var names = Data()
        for parts in paths {
            // A selected folder already includes its descendants.
            if (1..<parts.count).contains(where: { paths.contains(Array(parts.prefix($0))) }) { continue }
            names.append(contentsOf: ("./" + parts.joined(separator: "/")).utf8)
            names.append(0)
        }
        // A NUL-delimited manifest preserves any filename and avoids the argument-size limit.
        let manifest = output.deletingLastPathComponent().appendingPathComponent("inputs")
        try names.write(to: manifest)
        let input = try FileHandle(forReadingFrom: manifest)
        defer { try? input.close() }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = directory
        tar.arguments = ["-cf", output.path] + arguments + ["--null", "-T", "-"]
        tar.standardInput = input
        tar.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        tar.standardError = errors
        try tar.run()
        var detail = Data()
        while let chunk = try errors.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            detail.append(chunk.prefix(4096 - detail.count))
        }
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let reason = String(decoding: detail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "FileDesk.Archive", code: Int(tar.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: reason.isEmpty ? String(localized: "无法创建压缩包。") : reason
            ])
        }
    }
}
