import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct Favorite: Identifiable {
    let url: URL
    let title: String
    let symbol: String

    var id: URL { url }
}

struct FileNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var encryptedCopy: EncryptedCopy? = nil
}

@MainActor
@Observable
final class BrowserModel {
    private let fileSystem = FileSystem()
    private let encryptedFiles = EncryptedFileSessions()
    private let preferences: UserDefaults
    private let home: URL
    private var history: [URL] = []
    private var historyIndex = 0
    private var load: Task<Void, Never>?
    private var allItems: [FileItem] = []

    private(set) var directory: URL
    private(set) var items: [FileItem] = []
    private(set) var customFavorites: [Favorite] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var readError: String?
    private(set) var status: String?
    var selection: Set<URL> = []
    var preview: URL?
    var notice: FileNotice?
    private(set) var session: EncryptedFileSession?
    private(set) var sessionError: String?
    private(set) var isEditingExternally = false
    var sessionDraft: String?
    var query = "" {
        didSet { updateVisibleItems() }
    }
    var showHidden: Bool {
        didSet {
            preferences.set(showHidden, forKey: "showHidden")
            refresh()
        }
    }
    var sort: FileSort = .name {
        didSet {
            preferences.set(sort.rawValue, forKey: "sort")
            refresh()
        }
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.home = home
        directory = home
        showHidden = preferences.object(forKey: "showHidden") as? Bool ?? true
        history = [home]
        sort = preferences.string(forKey: "sort").flatMap(FileSort.init(rawValue:)) ?? .name
        customFavorites = (preferences.stringArray(forKey: "favorites") ?? []).map {
            let url = URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            return Favorite(url: url, title: url.lastPathComponent, symbol: "bookmark")
        }
    }

    var standardFavorites: [Favorite] {
        [
            Favorite(url: home, title: "个人目录", symbol: "house"),
            Favorite(url: home.appendingPathComponent("Desktop", isDirectory: true), title: "桌面", symbol: "desktopcomputer"),
            Favorite(url: home.appendingPathComponent("Documents", isDirectory: true), title: "文稿", symbol: "doc"),
            Favorite(url: home.appendingPathComponent("Downloads", isDirectory: true), title: "下载", symbol: "arrow.down.to.line"),
            Favorite(url: URL(fileURLWithPath: "/Applications", isDirectory: true), title: "应用程序", symbol: "square.grid.2x2")
        ]
    }

    var directoryTitle: String { title(for: directory) }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.id) } }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var canGoUp: Bool { directory.path != "/" }
    var isFavorite: Bool { customFavorites.contains { $0.url.path == directory.path } }
    var canFavorite: Bool { !standardFavorites.contains { $0.url.path == directory.path } }

    var breadcrumbs: [URL] {
        var result = [directory]
        var parent = directory
        while !parent.path.isEmpty, parent.path != "/", parent.path != home.path {
            let location = parent.deletingLastPathComponent()
            guard location.path != parent.path, !location.path.isEmpty else { break }
            result.append(location)
            parent = location
        }
        return result.reversed()
    }

    func title(for url: URL) -> String {
        if let favorite = standardFavorites.first(where: { $0.url.path == url.path }) { return favorite.title }
        return url.path == "/" ? "磁盘根目录" : url.lastPathComponent
    }

    func navigate(to url: URL) {
        let destination = URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
        guard destination.path != directory.path else { return }
        history = Array(history.prefix(historyIndex + 1)) + [destination]
        historyIndex = history.count - 1
        enter(destination)
    }

    func goToFolder(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: directory).absoluteURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        navigate(to: url)
        return true
    }

    func openExternalURL(_ url: URL, decrypt: (FileItem) -> Void) {
        if url.isFileURL {
            let item = FileSystem.item(at: url)
            if item.isFolder {
                navigate(to: item.url)
                return
            }
            if item.isEncrypted {
                navigate(to: item.url.deletingLastPathComponent())
                decrypt(item)
                return
            }
        }
        notice = FileNotice(title: "无法打开项目", message: "请选择普通文件夹或 .filedesk 加密文件。")
    }

    func setDefaultApp(_ app: URL?, for type: UTType) async {
        guard let app, app.pathExtension == "app" else {
            notice = FileNotice(title: "无法设置默认应用", message: "请从应用程序包启动文件桌，并确认目标应用存在。")
            return
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            let kind = type == .folder ? "文件夹" : ".filedesk 文件"
            status = "\(kind)默认使用「\(FileManager.default.displayName(atPath: app.path))」打开"
        } catch {
            notice = FileNotice(title: "未能更改默认打开方式", message: error.localizedDescription)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        enter(history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        enter(history[historyIndex])
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: directory.deletingLastPathComponent())
    }

    func chooseDirectory(for items: [FileItem]? = nil) {
        if items != nil, isWorking { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = items != nil
        panel.directoryURL = directory
        panel.prompt = items == nil ? "打开" : "移到这里"
        panel.message = items == nil ? "选择要浏览的文件夹" : "选择目标文件夹"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let items {
            perform(.move(sources: items.map(\.url), destination: destination))
        } else {
            navigate(to: destination)
        }
    }

    func refresh() {
        load?.cancel()
        isLoading = true
        readError = nil
        let directory = self.directory
        let showHidden = self.showHidden
        let sort = self.sort
        load = Task { [weak self, fileSystem] in
            do {
                let snapshot = try await fileSystem.read(directory, showHidden: showHidden, sort: sort)
                guard !Task.isCancelled, let self else { return }
                allItems = snapshot
                updateVisibleItems()
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                allItems = []
                updateVisibleItems()
                readError = error.localizedDescription
                isLoading = false
            }
        }
    }

    func toggleFavorite() {
        guard canFavorite else { return }
        if let index = customFavorites.firstIndex(where: { $0.url.path == directory.path }) {
            customFavorites.remove(at: index)
        } else {
            customFavorites.append(Favorite(url: directory, title: directoryTitle, symbol: "bookmark"))
        }
        preferences.set(customFavorites.map { $0.url.path }, forKey: "favorites")
    }

    func open(_ item: FileItem) {
        if item.isFolder {
            navigate(to: item.url)
        } else if !NSWorkspace.shared.open(item.url) {
            notice = FileNotice(title: "无法打开项目", message: item.name)
        }
    }

    func reveal(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    func copy(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects(items.map { $0.url as NSURL }) {
            status = "已复制 \(items.count) 个项目到剪贴板"
        } else {
            notice = FileNotice(title: "无法复制到剪贴板", message: "请再试一次。")
        }
    }

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(paths, forType: .string) {
            status = urls.count == 1 ? "已复制路径" : "已复制 \(urls.count) 条路径"
        } else {
            notice = FileNotice(title: "无法复制路径", message: "请再试一次。")
        }
    }

    func paste() {
        let contents = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = contents.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard !urls.isEmpty else {
            notice = FileNotice(title: "剪贴板中没有文件", message: "请先在这里或访达中复制文件。")
            return
        }
        perform(.copy(sources: urls, destination: directory))
    }

    func clearSessionError() {
        sessionError = nil
    }

    func changePassword(for item: FileItem, old: String, new: String) async -> Bool {
        guard !isWorking, session == nil else { return false }
        sessionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await encryptedFiles.changePassword(item.url, oldPassword: old, newPassword: new)
            status = "已修改「\(item.name)」的密码"
            refresh()
            return true
        } catch {
            sessionError = error.localizedDescription
            return false
        }
    }

    func unlock(_ item: FileItem, password: String) async {
        guard !isWorking, session == nil else { return }
        sessionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            session = try await encryptedFiles.open(item.url, password: password)
        } catch {
            sessionError = error.localizedDescription
        }
    }

    func editSessionExternally() async {
        guard !isWorking, let session else { return }
        sessionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            if let draft = modifiedSessionDraft {
                try await encryptedFiles.saveDraft(draft)
            }
            if NSWorkspace.shared.open(session.file) {
                sessionDraft = nil
                isEditingExternally = true
            } else {
                sessionError = "macOS 未能用默认应用打开此文件。"
            }
        } catch {
            sessionError = error.localizedDescription
        }
    }

    @discardableResult
    func closeSession(discardingChanges: Bool = false) async -> Bool {
        guard !isWorking else { return false }
        guard session != nil else { return true }
        isWorking = true
        sessionError = nil
        defer { isWorking = false }
        do {
            let changed = try await encryptedFiles.close(
                draft: modifiedSessionDraft,
                discardingChanges: discardingChanges
            )
            self.session = nil
            sessionDraft = nil
            isEditingExternally = false
            status = changed ? "已更新加密文件，临时副本已删除" : "临时副本已删除"
            if changed { refresh() }
            return true
        } catch {
            sessionError = error.localizedDescription
            return false
        }
    }

    func explainExternalQuit() {
        sessionError = "请在编辑应用中保存并关闭文件，再点「保存并关闭」。"
    }

    private var modifiedSessionDraft: String? {
        guard let draft = sessionDraft, let original = session?.text,
              !draft.utf8.elementsEqual(original.utf8) else { return nil }
        return draft
    }

    func perform(_ operation: FileOperation) {
        guard !isWorking else { return }
        status = nil
        isWorking = true
        Task { [weak self, fileSystem] in
            let result = await fileSystem.perform(operation)
            guard let self else { return }
            isWorking = false
            if let outputName = result.outputName {
                status = "\(operation.completion)「\(outputName)」"
            } else if result.completed > 0 {
                status = "\(operation.completion)（\(result.completed) 项）"
            }
            if !result.failures.isEmpty {
                let remaining = result.failures.count - 5
                let details = result.failures.prefix(5).joined(separator: "\n")
                let summary = remaining > 0 ? "\n另有 \(remaining) 个项目操作失败。" : ""
                notice = FileNotice(
                    title: result.completed > 0 ? "部分项目操作失败" : "文件操作失败",
                    message: details + summary
                )
            } else if let copy = result.encryptedCopy {
                notice = FileNotice(
                    title: "加密成功，要将明文原文件移到废纸篓吗？",
                    message: "已生成「\(copy.encrypted.lastPathComponent)」。请选择是否保留原文件「\(copy.original.lastPathComponent)」。",
                    encryptedCopy: copy
                )
            }
            refresh()
        }
    }

    private func enter(_ destination: URL) {
        directory = destination
        allItems = []
        selection = []
        query = ""
        status = nil
        refresh()
    }

    private func updateVisibleItems() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        items = term.isEmpty ? allItems : allItems.filter { item in
            item.name.localizedStandardContains(term) || item.tags.contains { $0.localizedStandardContains(term) }
        }
        if !selection.isEmpty {
            selection.formIntersection(items.lazy.map(\.id))
        }
    }
}
