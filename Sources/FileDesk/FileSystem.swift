import CryptoKit
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
    private(set) var hasEncryptedHeader = false
    var isEncrypted: Bool { isRegularFile && (fileExtension == CipherMode.fileExtension || hasEncryptedHeader) }

    // Probe on single-file actions, so listing or searching a directory never reads file contents.
    func checkingEncryption() -> Self {
        guard isRegularFile, !isEncrypted else { return self }
        var item = self
        item.hasEncryptedHeader = FileCipher.hasHeader(at: url)
        return item
    }
    var isArchive: Bool { isRegularFile && !isEncrypted && ArchiveExtractor.extensions.contains(fileExtension) }

    func matches(_ term: String) -> Bool {
        name.localizedStandardContains(term) || tags.contains { $0.localizedStandardContains(term) }
    }

    var symbol: String {
        if isFolder { return "folder.fill" }
        if isEncrypted { return "lock.doc" }
        if isArchive { return "archivebox" }
        switch fileExtension {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "flac", "aiff": return "music.note"
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
    case setHidden(sources: [URL], hidden: Bool)
    case setTags(folder: URL, tags: [String])
    case encrypt(source: URL, password: String)
    case extract(URL, installIfMissing: Bool = false)
    case trashEncryptedOriginal(EncryptedCopy)

    var completion: String {
        switch self {
        case .createFolder: String(localized: "已新建文件夹")
        case .rename: String(localized: "已重命名")
        case .copy: String(localized: "已复制文件")
        case .move: String(localized: "已移动文件")
        case .trash, .trashEncryptedOriginal: String(localized: "已移到废纸篓")
        case .setHidden(_, let hidden): hidden ? String(localized: "已隐藏项目") : String(localized: "已取消隐藏")
        case .setTags: String(localized: "已更新文件夹标签")
        case .encrypt: String(localized: "已生成加密副本")
        case .extract: String(localized: "已解压到")
        }
    }
}

struct OperationResult: Sendable {
    var completed = 0
    var failures: [String] = []
    var trashedPaths: [String] = []
    var outputName: String?
    var encryptedCopy: EncryptedCopy?
    var archiveNeedingSevenZip: URL?
}

struct EncryptedCopy: Sendable {
    let original: URL
    let encrypted: URL
    let originalDigest: SHA256.Digest
    let encryptedDigest: SHA256.Digest
}

private enum FileOperationError: LocalizedError {
    case invalidName
    case hiddenByName
    case insideSource
    case sameFolder
    case destinationExists(String)
    case moveItemsChanged
    case encryptionFilesChanged
    case unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "请输入有效的名称。名称中不能包含斜杠或冒号。")
        case .hiddenByName: String(localized: "名称以点号开头，移除开头的点号后才能显示。")
        case .insideSource: String(localized: "目标位置位于源文件夹内。")
        case .sameFolder: String(localized: "文件已在该文件夹中。")
        case .destinationExists(let name): String(localized: "目标位置已有同名项目「\(name)」。")
        case .moveItemsChanged: String(localized: "源项目或目标项目已变化，请重新移动。")
        case .encryptionFilesChanged: String(localized: "原文件或加密副本已变化或无法读取，已取消移到废纸篓。")
        case .unsupportedArchive: String(localized: "请选择支持的压缩文件。")
        }
    }
}

actor FileSystem {
    private let sevenZip: SevenZip
    init(sevenZip: SevenZip = SevenZip()) { self.sevenZip = sevenZip }
    private let manager = FileManager()
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedTypeDescriptionKey,
        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isHiddenKey
    ]

    static func folderURL(_ path: String, relativeTo directory: URL) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true, relativeTo: directory).absoluteURL
    }

    static func folderCompletions(for path: String, relativeTo directory: URL, showHidden: Bool) async -> [String] {
        guard !path.isEmpty, !Task.isCancelled else { return [] }
        if path == "~" || path == ".." { return [path + "/"] }
        let start = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let parent = String(path[..<start])
        let prefix = String(path[start...])
        let folder = parent.isEmpty ? directory : folderURL(parent, relativeTo: directory)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: showHidden || prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [String] = []
        for url in entries {
            if Task.isCancelled { return [] }
            let name = url.lastPathComponent
            guard prefix.isEmpty || name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory: ObjCBool = false
            if values?.isDirectory == true || (values?.isSymbolicLink == true &&
                manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                matches.append(name)
            }
        }
        return matches.sorted {
            if $0 == prefix { return $1 != prefix }
            if $1 == prefix { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.map { parent + $0 + "/" }
    }

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

    static func search(_ directory: URL, term: String, showHidden: Bool, sort: FileSort,
                onBatch: @MainActor ([FileItem]) -> Void) async throws -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        var rootError: Error?
        let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
            options: options
        ) { url, error in
            if url.standardizedFileURL.path == directory.standardizedFileURL.path { rootError = error }
            return true
        }
        guard let entries else { throw CocoaError(.fileReadUnknown) }

        var matches: [FileItem] = []
        var published = 0
        var nextUpdate = ContinuousClock.now
        while let url = entries.nextObject() as? URL {
            try Task.checkCancellation()
            // Only folders carry searchable tags. Avoid loading full metadata for unrelated entries.
            if !url.lastPathComponent.localizedStandardContains(term) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true,
                      let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames,
                      tags.contains(where: { $0.localizedStandardContains(term) }) else { continue }
            }
            matches.append(Self.item(at: url))
            if ContinuousClock.now >= nextUpdate {
                await onBatch(Array(matches[published...]))
                published = matches.count
                nextUpdate = .now + .milliseconds(200)
            }
        }
        if let rootError { throw rootError }
        try Task.checkCancellation()
        return matches.sorted(by: sort.precedes)
    }

    static func item(at url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: keys)
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let tags = isFolder ? (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) : nil
        return FileItem(
            url: url.standardizedFileURL,
            name: url.lastPathComponent,
            kind: isFolder ? String(localized: "文件夹") : (values?.localizedTypeDescription ?? String(localized: "文件")),
            isFolder: isFolder,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
            isRegularFile: values?.isRegularFile == true && values?.isSymbolicLink != true && values?.isPackage != true,
            tags: tags ?? [],
            size: isFolder ? nil : values?.fileSize,
            modified: values?.contentModificationDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    func perform(_ operation: FileOperation,
                 confirmReplacement: (@MainActor @Sendable (URL, URL) -> Bool)? = nil) async -> OperationResult {
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
                let parent = source.deletingLastPathComponent()
                var target = try namedURL(parent: parent, name: name)
                if Self.item(at: source).checkingEncryption().isEncrypted {
                    let oldName = source.pathExtension.lowercased() == CipherMode.fileExtension
                        ? source.deletingPathExtension() : source
                    if target.pathExtension.lowercased() != CipherMode.fileExtension {
                        if target.pathExtension.isEmpty, !oldName.pathExtension.isEmpty {
                            target.appendPathExtension(oldName.pathExtension)
                        }
                        target.appendPathExtension(CipherMode.fileExtension)
                    }
                }
                guard source.path != target.path else { return }
                // On case-insensitive volumes the new spelling can refer to the source itself.
                if entryExists(target), !(try isAlternateSpelling(of: source, at: target)) {
                    throw FileOperationError.destinationExists(name)
                }
                try manager.moveItem(at: source, to: target)
                result.outputName = target.lastPathComponent
            }
        case .copy(let sources, let destination):
            for source in sources {
                attempt(source.lastPathComponent) {
                    let target = try transferTarget(for: source, in: destination)
                    try requireAvailable(target)
                    try copyItem(at: source, to: target)
                }
            }
        case .move(let sources, let destination):
            for source in sources {
                do {
                    let target = try transferTarget(for: source, in: destination)
                    if entryExists(target) {
                        guard let confirmReplacement else { throw FileOperationError.destinationExists(target.lastPathComponent) }
                        let incoming = try MoveEntry(source)
                        let existing = try MoveEntry(target)
                        guard !incoming.sameItem(as: existing) else { throw FileOperationError.sameFolder }
                        if existing.isDirectory {
                            var relationship = FileManager.URLRelationship.other
                            try manager.getRelationship(&relationship, ofDirectoryAt: target,
                                                        toItemAt: source.deletingLastPathComponent().resolvingSymlinksInPath())
                            guard relationship == .other else { throw FileOperationError.insideSource }
                        }
                        guard await confirmReplacement(source, target) else { continue }
                        try replaceForMove(source, incoming: incoming, target: target, existing: existing)
                    } else {
                        try manager.moveItem(at: source, to: target)
                    }
                    result.completed += 1
                } catch {
                    result.failures.append("\(source.lastPathComponent) · \(error.localizedDescription)")
                }
            }
        case .trash(let sources):
            for source in sources {
                attempt(source.lastPathComponent) {
                    try manager.trashItem(at: source, resultingItemURL: nil)
                    result.trashedPaths.append(source.standardizedFileURL.path)
                }
            }
        case .setHidden(let sources, let hidden):
            var values = URLResourceValues()
            values.isHidden = hidden
            for var source in sources {
                attempt(source.lastPathComponent) {
                    if !hidden && source.lastPathComponent.hasPrefix(".") { throw FileOperationError.hiddenByName }
                    try source.setResourceValues(values)
                }
            }
        case .setTags(let folder, let tags):
            attempt(folder.lastPathComponent) {
                let currentFolder = URL(fileURLWithPath: folder.path, isDirectory: true)
                let values = try currentFolder.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
                try (currentFolder as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            }
        case .extract(let source, let installIfMissing):
            guard Self.item(at: source).isArchive else {
                result.failures.append(FileOperationError.unsupportedArchive.localizedDescription)
                return result
            }
            let tool: String
            if let installed = sevenZip.executable {
                tool = installed
            } else if installIfMissing {
                do { tool = try await sevenZip.install() }
                catch {
                    result.failures.append(String(localized: "安装 7-Zip 失败：\(error.localizedDescription)"))
                    return result
                }
            } else {
                result.archiveNeedingSevenZip = source
                return result
            }
            attempt(source.lastPathComponent) {
                guard Self.item(at: source).isArchive else { throw FileOperationError.unsupportedArchive }
                let parent = source.deletingLastPathComponent()
                let name = ArchiveExtractor.folderName(for: source)
                var target = parent.appendingPathComponent(name, isDirectory: true)
                var suffix = 2
                while entryExists(target) {
                    target = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
                    suffix += 1
                }
                try withStagedOutput(target) { try ArchiveExtractor.extract(source, into: $0, using: tool) }
                result.outputName = target.lastPathComponent
            }
        case .encrypt(let source, let password):
            attempt(source.lastPathComponent) {
                let source = URL(fileURLWithPath: source.path, isDirectory: false)
                try FileCipher.requireRegularFile(source)
                let target = source.appendingPathExtension(CipherMode.fileExtension)
                try requireAvailable(target)
                result.encryptedCopy = try withStagedOutput(target) { output in
                    let digest = try FileCipher.transform(.encrypt, source: source, output: output, password: password)
                    return EncryptedCopy(original: source, encrypted: target, originalDigest: digest,
                                         encryptedDigest: try FileCipher.digest(output))
                }
                result.outputName = target.lastPathComponent
            }
        case .trashEncryptedOriginal(let copy):
            attempt(copy.original.lastPathComponent) {
                var error: NSError?
                var outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(readingItemAt: copy.encrypted, options: [],
                                               writingItemAt: copy.original, options: .forDeleting,
                                               error: &error) { encrypted, original in
                    outcome = Result {
                        guard (try? FileCipher.digest(encrypted)) == copy.encryptedDigest,
                              (try? FileCipher.digest(original)) == copy.originalDigest else {
                            throw FileOperationError.encryptionFilesChanged
                        }
                        try self.manager.trashItem(at: original, resultingItemURL: nil)
                    }
                }
                if let error { throw error }
                guard let outcome else { throw CocoaError(.fileWriteUnknown) }
                try outcome.get()
                result.trashedPaths.append(copy.original.standardizedFileURL.path)
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

    // lstat identifies the directory entry itself, including a dangling symlink.
    private struct MoveEntry: Equatable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int
        let isDirectory: Bool

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            device = info.st_dev
            inode = info.st_ino
            seconds = info.st_ctimespec.tv_sec
            nanoseconds = info.st_ctimespec.tv_nsec
            isDirectory = info.st_mode & S_IFMT == S_IFDIR
        }

        func sameItem(as other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    private func replaceForMove(_ source: URL, incoming: MoveEntry, target: URL, existing: MoveEntry) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving,
                                       writingItemAt: target, options: .forReplacing, error: &coordinationError) { from, to in
            outcome = Result {
                func checkEntries() throws {
                    guard try MoveEntry(from) == incoming, try MoveEntry(to) == existing else {
                        throw FileOperationError.moveItemsChanged
                    }
                }
                try checkEntries()
                if incoming.device == existing.device {
                    _ = try manager.replaceItemAt(to, withItemAt: from, options: .usingNewMetadataOnly)
                } else {
                    try withStagedOutput(to, replacing: true) { staged in
                        try manager.copyItem(at: from, to: staged)
                        try checkEntries()
                    }
                    guard try MoveEntry(from) == incoming else { throw FileOperationError.moveItemsChanged }
                    try manager.removeItem(at: from)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        try outcome.get()
    }

    private func withStagedOutput<T>(_ target: URL, replacing: Bool = false, write: (URL) throws -> T) throws -> T {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".filedesk-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }

        let stagedItem = staging.appendingPathComponent(target.lastPathComponent)
        let result = try write(stagedItem)
        if replacing {
            _ = try manager.replaceItemAt(target, withItemAt: stagedItem, options: .usingNewMetadataOnly)
        } else {
            try requireAvailable(target)
            try manager.moveItem(at: stagedItem, to: target)
        }
        return result
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
        return directory.appendingPathComponent(source.lastPathComponent)
    }
}
