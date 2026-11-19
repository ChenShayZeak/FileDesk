import Foundation

struct FileItem: Identifiable, Sendable {
    let url: URL
    let name: String
    let kind: String
    let isFolder: Bool
    let isHidden: Bool
    let isRegularFile: Bool
    let tags: [String]
    let size: Int?
    let modified: Date?
    let fileExtension: String

    var id: URL { url }
    var isEncrypted: Bool { isRegularFile && fileExtension == CipherMode.fileExtension }

    var symbol: String {
        if isFolder { return "folder.fill" }
        if isEncrypted { return "lock.doc" }
        switch fileExtension {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "flac", "aiff": return "music.note"
        case "zip", "rar", "7z", "gz", "tar": return "archivebox"
        case "swift", "json", "js", "ts", "html", "css", "py", "sh": return "chevron.left.forwardslash.chevron.right"
        case "pdf", "doc", "docx", "txt", "md", "rtf": return "doc.text"
        default: return "doc"
        }
    }
}

enum FileSort: String, CaseIterable, Identifiable, Sendable {
    case name = "名称"
    case newest = "最近修改"
    case largest = "文件大小"
    case kind = "种类"

    var id: Self { self }

    func precedes(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
        switch self {
        case .newest:
            let first = lhs.modified ?? .distantPast
            let second = rhs.modified ?? .distantPast
            if first != second { return first > second }
        case .largest:
            let first = lhs.size ?? -1
            let second = rhs.size ?? -1
            if first != second { return first > second }
        case .kind:
            let order = lhs.kind.localizedStandardCompare(rhs.kind)
            if order != .orderedSame { return order == .orderedAscending }
        case .name:
            break
        }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
    }
}

enum FileOperation: Sendable {
    case createFolder(parent: URL, name: String)
    case rename(source: URL, name: String)
    case copy(sources: [URL], destination: URL)
    case move(sources: [URL], destination: URL)
    case trash(sources: [URL])
    case setTags(folder: URL, tags: [String])
    case encrypt(source: URL, password: String)

    var completion: String {
        switch self {
        case .createFolder: "已新建文件夹"
        case .rename: "已重命名"
        case .copy: "已复制文件"
        case .move: "已移动文件"
        case .trash: "已移到废纸篓"
        case .setTags: "已更新文件夹标签"
        case .encrypt: "已生成加密副本"
        }
    }
}

struct OperationResult: Sendable {
    var completed = 0
    var failures: [String] = []
    var outputName: String?
}

private enum FileOperationError: LocalizedError {
    case invalidName
    case insideSource
    case sameFolder
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: "请输入有效的名称。名称中不能包含斜杠或冒号。"
        case .insideSource: "目标位置位于源文件夹内。"
        case .sameFolder: "文件已在该文件夹中。"
        case .destinationExists(let name): "目标位置已有同名项目「\(name)」。"
        }
    }
}

actor FileSystem {
    private let manager = FileManager()
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedTypeDescriptionKey,
        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isHiddenKey
    ]

    func read(_ directory: URL, showHidden: Bool, sort: FileSort) throws -> [FileItem] {
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(Self.keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            items.append(Self.item(at: url))
        }
        return items.sorted(by: sort.precedes)
    }

    static func item(at url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: keys)
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let tags = isFolder ? (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) : nil
        return FileItem(
            url: url.standardizedFileURL,
            name: url.lastPathComponent,
            kind: isFolder ? "文件夹" : (values?.localizedTypeDescription ?? "文件"),
            isFolder: isFolder,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
            isRegularFile: values?.isRegularFile == true && values?.isSymbolicLink != true && values?.isPackage != true,
            tags: tags ?? [],
            size: isFolder ? nil : values?.fileSize,
            modified: values?.contentModificationDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    func perform(_ operation: FileOperation) -> OperationResult {
        var result = OperationResult()

        func attempt(_ label: String, _ action: () throws -> Void) {
            do {
                try action()
                result.completed += 1
            } catch {
                result.failures.append("\(label) · \(error.localizedDescription)")
            }
        }

        switch operation {
        case .createFolder(let parent, let name):
            attempt(name) {
                let target = try namedURL(parent: parent, name: name)
                try requireAvailable(target)
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
            }
        case .rename(let source, let name):
            attempt(name) {
                let target = try namedURL(parent: source.deletingLastPathComponent(), name: name)
                guard source.path != target.path else { return }
                // On case-insensitive volumes the new spelling can refer to the source itself.
                if entryExists(target), !(try isAlternateSpelling(of: source, at: target)) {
                    throw FileOperationError.destinationExists(name)
                }
                try manager.moveItem(at: source, to: target)
            }
        case .copy(let sources, let destination):
            for source in sources {
                attempt(source.lastPathComponent) {
                    let target = try transferTarget(for: source, in: destination)
                    try copyItem(at: source, to: target)
                }
            }
        case .move(let sources, let destination):
            for source in sources {
                attempt(source.lastPathComponent) {
                    let target = try transferTarget(for: source, in: destination)
                    try manager.moveItem(at: source, to: target)
                }
            }
        case .trash(let sources):
            for source in sources {
                attempt(source.lastPathComponent) {
                    try manager.trashItem(at: source, resultingItemURL: nil)
                }
            }
        case .setTags(let folder, let tags):
            attempt(folder.lastPathComponent) {
                let currentFolder = URL(fileURLWithPath: folder.path, isDirectory: true)
                let values = try currentFolder.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
                try (currentFolder as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            }
        case .encrypt(let source, let password):
            attempt(source.lastPathComponent) {
                let source = URL(fileURLWithPath: source.path, isDirectory: false)
                try FileCipher.requireRegularFile(source)
                let target = source.appendingPathExtension(CipherMode.fileExtension)
                try requireAvailable(target)
                try withStagedOutput(target) { output in
                    try FileCipher.transform(.encrypt, source: source, output: output, password: password)
                }
                result.outputName = target.lastPathComponent
            }
        }
        return result
    }

    private func namedURL(parent: URL, name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw FileOperationError.invalidName
        }
        return parent.appendingPathComponent(name)
    }

    private func entryExists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path) ||
            (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func requireAvailable(_ url: URL) throws {
        guard !entryExists(url) else { throw FileOperationError.destinationExists(url.lastPathComponent) }
    }

    private func isAlternateSpelling(of source: URL, at target: URL) throws -> Bool {
        guard source.lastPathComponent.caseInsensitiveCompare(target.lastPathComponent) == .orderedSame else {
            return false
        }
        let entries = try manager.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        return !entries.contains { $0.utf8.elementsEqual(target.lastPathComponent.utf8) }
    }

    private func copyItem(at source: URL, to target: URL) throws {
        try withStagedOutput(target) { stagedItem in
            try manager.copyItem(at: source, to: stagedItem)
        }
    }

    private func withStagedOutput(_ target: URL, write: (URL) throws -> Void) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".filedesk-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }

        let stagedItem = staging.appendingPathComponent(target.lastPathComponent)
        try write(stagedItem)
        try requireAvailable(target)
        try manager.moveItem(at: stagedItem, to: target)
    }

    private func transferTarget(for source: URL, in destination: URL) throws -> URL {
        let directory = destination.resolvingSymlinksInPath().standardizedFileURL
        let sourceParent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        if directory.path == sourceParent.path { throw FileOperationError.sameFolder }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
            var relationship = FileManager.URLRelationship.other
            try manager.getRelationship(&relationship, ofDirectoryAt: resolvedSource, toItemAt: directory)
            if relationship == .same || relationship == .contains {
                throw FileOperationError.insideSource
            }
        }
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try requireAvailable(target)
        return target
    }
}
