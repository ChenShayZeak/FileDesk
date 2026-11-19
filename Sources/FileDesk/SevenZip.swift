import CryptoKit
import Foundation

struct SevenZip: Sendable {
    static let version = "26.06"
    #if arch(arm64)
    private static let package = "7z2606-mac.tar.xz"
    private static let checksum = "b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd"
    #else
    private static let package = "7z2606-mac-x64.tar.xz"
    private static let checksum = "3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586"
    #endif

    var systemPaths = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]
    var root = URL.applicationSupportDirectory.appending(path: "FileDesk/Tools")
    private var release: URL { root.appending(path: Self.package + ".installed") }

    var executable: String? {
        (systemPaths + [release.appending(path: "7zz").path]).first { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    func install() async throws -> String {
        if let executable { return executable }
        let url = URL(string: "https://github.com/ip7z/7zip/releases/download/\(Self.version)/\(Self.package)")!
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw InstallError.download
        }
        return try install(packageAt: archive)
    }

    func install(packageAt archive: URL) throws -> String {
        let hash = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
        guard hash.map({ String(format: "%02x", $0) }).joined() == Self.checksum else {
            throw InstallError.checksum
        }
        let manager = FileManager.default
        let staging = root.appending(path: UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", staging.path, "7zz", "License.txt"]
        tar.standardInput = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0,
              manager.isExecutableFile(atPath: staging.appending(path: "7zz").path) else {
            throw InstallError.unpack
        }
        do {
            try manager.moveItem(at: staging, to: release)
        } catch {
            // Another FileDesk instance may have installed the same release first.
            guard let executable else { throw error }
            return executable
        }
        return release.appending(path: "7zz").path
    }

    private enum InstallError: LocalizedError {
        case download, checksum, unpack
        var errorDescription: String? {
            switch self {
            case .download: "7-Zip 官方安装包下载失败，请检查网络并重试。"
            case .checksum: "7-Zip 安装包校验失败，请重新下载。"
            case .unpack: "无法从安装包中安装 7zz，请重试。"
            }
        }
    }
}
