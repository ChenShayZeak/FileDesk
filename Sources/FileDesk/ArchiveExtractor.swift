import Foundation

enum ArchiveExtractor {
    static let extensions: Set<String> = ["7z", "zip", "rar", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2", "txz", "tzst"]
    private static let tarSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".txz", ".tzst"]

    static func folderName(for source: URL) -> String {
        let name = source.lastPathComponent
        let suffix = tarSuffixes.first { name.lowercased().hasSuffix($0) }
        let stem = suffix.map { String(name.dropLast($0.count)) } ?? source.deletingPathExtension().lastPathComponent
        return ["", ".", ".."].contains(stem) || stem == name ? name + " 解压" : stem
    }

    static func extract(_ source: URL, into destination: URL) throws {
        let manager = FileManager.default
        let candidates = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]
        guard let tool = candidates.first(where: manager.isExecutableFile(atPath:)) else {
            throw ArchiveError("找不到 7-Zip。请安装 macOS 版 7zz，或运行 brew install sevenzip 后重试。")
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)

        if tarSuffixes.contains(where: { source.lastPathComponent.lowercased().hasSuffix($0) }) {
            let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: temp, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: temp) }
            try run(tool, source: source, directory: temp)
            let entries = try manager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
            guard entries.count == 1, let tar = entries.first, FileSystem.item(at: tar).isRegularFile else {
                throw ArchiveError("压缩包内没有可解压的 TAR 文件。")
            }
            try run(tool, source: tar, directory: destination, type: ["-ttar"])
        } else {
            try run(tool, source: source, directory: destination)
        }
        if let quarantine = try source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties {
            var flags = URLResourceValues()
            flags.quarantineProperties = quarantine
            var root = destination
            try root.setResourceValues(flags)
            var readError: Error?
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                   errorHandler: { _, error in readError = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case var file as URL in entries {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
                    try file.setResourceValues(flags)
                }
            }
            if let readError { throw readError }
        }
    }

    private static func run(_ tool: String, source: URL, directory: URL, type: [String] = []) throws {
        // Confine the external decoder's writes to this unpublished staging directory.
        guard let output = realpath(directory.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(output) }
        let profile = """
        (version 1)(allow default)(deny network*)(deny file-write*)
        (allow file-write* (subpath (param "OUTPUT")))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.currentDirectoryURL = directory
        process.arguments = ["-D", "OUTPUT=" + String(cString: output), "-p", profile, tool, "x", "-y", "-aou", "-spd", "-bd"]
            + type + ["--", source.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        var detail = Data()
        while let data = try errors.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
            detail.append(data.prefix(4096 - detail.count))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: detail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError("解压失败，请检查压缩包是否完整或需要密码。" + (message.isEmpty ? "" : "\n" + message))
        }
    }

    private struct ArchiveError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
