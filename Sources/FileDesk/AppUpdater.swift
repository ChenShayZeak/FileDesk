import Darwin
import Foundation

struct AppRelease: Equatable, Sendable {
    let tag: String
    let objectID: String

    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    static func latest(in references: String) -> Self? {
        references.split(separator: "\n").compactMap { line -> Self? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { return nil }
            let tag = String(fields[1].dropFirst("refs/tags/".count))
            guard tag.wholeMatch(of: #/v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/#) != nil,
                  fields[0].wholeMatch(of: #/[0-9a-f]{40}/#) != nil else { return nil }
            return Self(tag: tag, objectID: String(fields[0]))
        }.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
}

actor AppUpdater {
    private let repository: String

    init(repository: String = "https://github.com/ChenShayZeak/FileDesk.git") {
        self.repository = repository
    }

    func latest() throws -> AppRelease? {
        let refs = try run("/usr/bin/git", ["ls-remote", "--tags", "--refs", repository],
                           in: FileManager.default.temporaryDirectory)
        return AppRelease.latest(in: refs)
    }

    static func installedVersion(at app: URL) throws -> String {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "local.filedesk.app",
              let version = info?["CFBundleShortVersionString"] as? String else {
            throw UpdateError("请从「文件桌.app」启动后检查更新。")
        }
        return version
    }

    func install(_ release: AppRelease, at app: URL) throws {
        let manager = FileManager.default
        let oldVersion = try Self.installedVersion(at: app)
        guard release.version.compare(oldVersion, options: .numeric) == .orderedDescending else { return }
        let source = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: source) }

        try run("/usr/bin/git", ["init", "-q"], in: source)
        let ref = "refs/tags/" + release.tag
        try run("/usr/bin/git", ["fetch", "--depth=1", "--no-tags", repository, ref + ":" + ref], in: source)
        let fetched = try run("/usr/bin/git", ["rev-parse", ref], in: source)
        guard fetched == release.objectID else { throw UpdateError("版本标签已更改，请重新检查更新。") }
        try run("/usr/bin/git", ["checkout", "--quiet", "--detach", ref], in: source)
        try run("/bin/bash", ["scripts/build-app.sh"], in: source, version: release.version)

        // Stage beside the installed app so the final swap is atomic and on the same volume.
        let stage = app.deletingLastPathComponent().appending(path: ".FileDesk-update-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let replacement = stage.appending(path: "文件桌.app")
        try manager.copyItem(at: source.appending(path: "dist/文件桌.app"), to: replacement)
        try run("/usr/bin/codesign", ["--verify", "--strict", replacement.path], in: stage)
        guard try Self.installedVersion(at: replacement) == release.version,
              manager.isExecutableFile(atPath: replacement.appending(path: "Contents/MacOS/FileDesk").path) else {
            throw UpdateError("构建出的应用与选定版本不匹配。")
        }
        guard try Self.installedVersion(at: app) == oldVersion else {
            throw UpdateError("已安装的版本发生变化，请重新检查更新。")
        }
        guard renamex_np(replacement.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], in directory: URL, version: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"
        ]
        environment["FILEDESK_VERSION"] = version
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw UpdateError(output.isEmpty ? "执行 \(process.executableURL!.lastPathComponent) 失败。" : String(output.suffix(1200)))
        }
        return output
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
