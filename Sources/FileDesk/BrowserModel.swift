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
    var archiveNeedingSevenZip: URL? = nil
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
    private(set) var recentPaths: [String] {
        didSet { preferences.set(recentPaths, forKey: "recentPaths") }
    }
    private var recentFiles: [RecentFile] {
        didSet { RecentFile.save(recentFiles, to: preferences) }
    }
    var recentFilePaths: [String] { recentFiles.map(\.path) }
    private(set) var items: [FileItem] = []
    private(set) var customFavorites: [Favorite] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var updateStage: UpdateStage?
    private(set) var workingMessage = String(localized: "正在处理文件…")
    private(set) var readError: String?
    private(set) var status: String?
    var copiedPathsID: UUID?
    private var selectionAnchor: URL?
    var selection: Set<URL> = [] {
        didSet {
            let selected = items.filter { selection.contains($0.id) }
            selectedItems = selected.count == 1 ? [selected[0].checkingEncryption()] : selected
            if selectionAnchor.map(selection.contains) != true { selectionAnchor = selected.first?.id }
        }
    }

    func fileURLsForDrag(startingAt url: URL) -> [URL] {
        selection.contains(url) ? selectedItems.map(\.url) : [url]
    }

    func selectItem(_ id: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let start = items.firstIndex(where: { $0.id == selectionAnchor }),
           let end = items.firstIndex(where: { $0.id == id }) {
            let range = items[min(start, end)...max(start, end)].map(\.id)
            selection = modifiers.contains(.command) ? selection.union(range) : Set(range)
        } else if modifiers.contains(.command) && selection.contains(id) {
            selection.remove(id)
        } else {
            selection = modifiers.contains(.command) ? selection.union([id]) : [id]
            selectionAnchor = id
        }
    }
    var preview: URL?
    var notice: FileNotice?
    private(set) var session: EncryptedFileSession?
    private(set) var sessionError: String?
    private(set) var isEditingExternally = false
    var sessionDraft: String?
    var query = "" {
        didSet {
            guard searchTerm != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            replaceItems(searchTerm.isEmpty ? allItems : items.filter { $0.matches(searchTerm) })
            refresh()
        }
    }
    var showHidden: Bool {
        didSet {
            preferences.set(showHidden, forKey: "showHidden")
            allItems = []
            replaceItems([])
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
        recentPaths = preferences.stringArray(forKey: "recentPaths") ?? []
        recentFiles = RecentFile.load(from: preferences)
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
            Favorite(url: home, title: String(localized: "个人目录"), symbol: "house"),
            Favorite(url: home.appendingPathComponent("Desktop", isDirectory: true), title: String(localized: "桌面"), symbol: "desktopcomputer"),
            Favorite(url: home.appendingPathComponent("Documents", isDirectory: true), title: String(localized: "文稿"), symbol: "doc"),
            Favorite(url: home.appendingPathComponent("Downloads", isDirectory: true), title: String(localized: "下载"), symbol: "arrow.down.to.line"),
            Favorite(url: URL(fileURLWithPath: "/Applications", isDirectory: true), title: String(localized: "应用程序"), symbol: "square.grid.2x2")
        ]
    }

    var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func searchLocation(of item: FileItem) -> String {
        let parent = item.url.deletingLastPathComponent().pathComponents.dropFirst(directory.pathComponents.count)
        return parent.isEmpty ? String(localized: "当前文件夹") : parent.joined(separator: "/")
    }

    var directoryTitle: String { title(for: directory) }
    private(set) var selectedItems: [FileItem] = []
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
        return url.path == "/" ? String(localized: "磁盘根目录") : url.lastPathComponent
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
        let url = FileSystem.folderURL(path, relativeTo: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        navigate(to: url)
        let visited = directory.path
        if recentPaths.first != visited {
            recentPaths = [visited] + recentPaths.filter { $0 != visited }
        }
        return true
    }

    func removeRecentPath(_ path: String) {
        recentPaths.removeAll { $0 == path }
    }

    func openExternalURL(_ url: URL, decrypt: (FileItem) -> Void) {
        if url.isFileURL {
            let item = FileSystem.item(at: url).checkingEncryption()
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
        notice = FileNotice(title: String(localized: "无法打开项目"), message: String(localized: "请选择普通文件夹或 .filedesk 加密文件。"))
    }

    func checkForUpdate() async {
        guard !isWorking, session == nil else { return }
        isWorking = true
        updateStage = .checking
        defer {
            isWorking = false
            updateStage = nil
        }
        let updater = AppUpdater()
        let alert = NSAlert()
        do {
            let (app, current) = try AppUpdater.installedApp(launchedFrom: Bundle.main.bundleURL)
            if let release = try await updater.latest() {
                if release.version.compare(current, options: .numeric) == .orderedDescending {
                    let confirm = NSAlert()
                    confirm.messageText = String(localized: "发现新版本 \(release.version)")
                    confirm.informativeText = String(localized: "当前版本为 \(current)。下载并编译新版本？安装完成后文件桌会自动重启。")
                    confirm.addButton(withTitle: String(localized: "安装更新"))
                    confirm.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                    guard try await updater.install(release, at: app, report: { self.updateStage = $0 }) else { return }
                    updateStage = .restarting
                    do {
                        try AppUpdater.relaunchAfterExit(app)
                        // The quit delegate refuses termination while a file operation is active.
                        isWorking = false
                        NSApp.terminate(nil)
                        return
                    } catch {
                        alert.messageText = String(localized: "已安装 \(release.version)")
                        alert.informativeText = String(localized: "未能自动重启。请退出并重新打开文件桌。\n\(error.localizedDescription)")
                    }
                } else {
                    alert.messageText = String(localized: "已是最新版本")
                    alert.informativeText = String(localized: "已安装版本为 \(current)。")
                }
            } else {
                alert.messageText = String(localized: "暂无可更新的版本")
                alert.informativeText = String(localized: "GitHub 仓库尚未发布正式版本标签。当前版本为 \(current)。")
            }
        } catch {
            alert.messageText = String(localized: "更新失败")
            alert.informativeText = error.localizedDescription
        }
        updateStage = nil
        isWorking = false
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }

    func setDefaultApp(_ app: URL?, for type: UTType) async {
        guard let app, app.pathExtension == "app" else {
            notice = FileNotice(title: String(localized: "无法设置默认应用"), message: String(localized: "请从应用程序包启动文件桌，并确认目标应用存在。"))
            return
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            let kind = type == .folder ? String(localized: "文件夹") : String(localized: ".filedesk 文件")
            status = String(localized: "\(kind)默认使用「\(FileManager.default.displayName(atPath: app.path))」打开")
        } catch {
            guard type == .folder else {
                notice = FileNotice(title: String(localized: "未能更改默认打开方式"), message: error.localizedDescription)
                return
            }
            let current = NSWorkspace.shared.urlForApplication(toOpen: .folder)
            let currentName = current.map { FileManager.default.displayName(atPath: $0.path) }
            let detail = currentName.map { String(localized: "当前默认应用为「\($0)」。") } ?? ""
            notice = FileNotice(
                title: String(localized: "未能更改文件夹的默认应用"),
                message: String(localized: "\(detail)macOS 未接受此次更改。你仍可在文件桌中按 ⌘⇧G 输入路径打开文件夹。")
            )
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
        panel.prompt = items == nil ? String(localized: "打开") : String(localized: "移到这里")
        panel.message = items == nil ? String(localized: "选择要浏览的文件夹") : String(localized: "选择目标文件夹")
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
        let term = searchTerm
        load = Task { [weak self, fileSystem] in
            do {
                let snapshot: [FileItem]
                if term.isEmpty {
                    snapshot = try await fileSystem.read(directory, showHidden: showHidden, sort: sort)
                    guard !Task.isCancelled else { return }
                    self?.allItems = snapshot
                } else {
                    try await Task.sleep(for: .milliseconds(180))
                    var visible = Set(self?.items.map(\.id) ?? [])
                    snapshot = try await FileSystem.search(directory, term: term, showHidden: showHidden, sort: sort) { batch in
                        guard !Task.isCancelled else { return }
                        self?.items.append(contentsOf: batch.filter { visible.insert($0.id).inserted })
                    }
                }
                guard !Task.isCancelled, let self else { return }
                replaceItems(snapshot)
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                if term.isEmpty { allItems = [] }
                replaceItems([])
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

    func open(_ item: FileItem, with openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        if item.isFolder {
            navigate(to: item.url)
        } else if openFile(item.url) {
            recordOpenedFile(item.url)
        } else {
            notice = FileNotice(title: String(localized: "无法打开项目"), message: item.name)
        }
    }

    private func recordOpenedFile(_ url: URL) {
        let entry = RecentFile(url)
        recentFiles = [entry] + recentFiles.filter { $0.path != entry.path }
    }

    func removeRecentFile(_ path: String) {
        recentFiles.removeAll { $0.path == path }
    }

    func refreshRecentFiles() async {
        let snapshot = recentFiles
        let updated = await RecentFile.refresh(snapshot)
        if recentFiles == snapshot, updated != snapshot { recentFiles = updated }
    }

    func refreshBrowser() {
        refresh()
        Task { await refreshRecentFiles() }
    }

    private func renamedRecentFiles(from source: URL, to target: URL) {
        let oldPath = source.standardizedFileURL.path
        let mapped = recentFiles.map { entry in
            guard entry.path == oldPath || entry.path.hasPrefix(oldPath + "/") else { return entry }
            let path = target.path + String(entry.path.dropFirst(oldPath.count))
            return RecentFile(URL(fileURLWithPath: path, isDirectory: false))
        }
        let updated = RecentFile.uniquePaths(mapped)
        if updated != recentFiles { recentFiles = updated }
    }

    func recentFile(at path: String) -> FileItem? {
        guard let index = recentFiles.firstIndex(where: { $0.path == path }) else { return nil }
        guard let resolved = recentFiles[index].resolved() else {
            removeRecentFile(path)
            notice = FileNotice(title: String(localized: "无法打开项目"), message: path)
            return nil
        }
        if recentFiles[index] != resolved {
            var updated = recentFiles
            updated[index] = resolved
            recentFiles = RecentFile.uniquePaths(updated)
        }
        let path = resolved.path
        let item = FileSystem.item(at: URL(fileURLWithPath: path, isDirectory: false))
        guard !item.isFolder, FileManager.default.fileExists(atPath: path) else {
            notice = FileNotice(title: String(localized: "无法打开项目"), message: path)
            return nil
        }
        return item
    }

    func openInTerminal() async {
        let workspace = NSWorkspace.shared
        let title = String(localized: "无法打开终端")
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            notice = FileNotice(title: title, message: String(localized: "未找到系统终端应用。"))
            return
        }
        do {
            _ = try await workspace.open([directory], withApplicationAt: terminal, configuration: .init())
        } catch {
            notice = FileNotice(title: title, message: error.localizedDescription)
        }
    }

    func reveal(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    func copy(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects(items.map { $0.url as NSURL }) {
            status = String(localized: "已复制 \(items.count) 个项目到剪贴板")
        } else {
            notice = FileNotice(title: String(localized: "无法复制到剪贴板"), message: String(localized: "请再试一次。"))
        }
    }

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(paths, forType: .string) {
            copiedPathsID = UUID()
            status = urls.count == 1 ? String(localized: "路径已复制") : String(localized: "已复制 \(urls.count) 条路径")
        } else {
            notice = FileNotice(title: String(localized: "无法复制路径"), message: String(localized: "请再试一次。"))
        }
    }

    func paste() {
        let contents = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = contents.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard !urls.isEmpty else {
            notice = FileNotice(title: String(localized: "剪贴板中没有文件"), message: String(localized: "请先在这里或访达中复制文件。"))
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
            status = String(localized: "已修改「\(item.name)」的密码")
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
            recordOpenedFile(item.url)
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
                sessionError = String(localized: "macOS 未能用默认应用打开此文件。")
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
            status = changed ? String(localized: "已更新加密文件，临时副本已删除") : String(localized: "临时副本已删除")
            if changed { refresh() }
            return true
        } catch {
            sessionError = error.localizedDescription
            return false
        }
    }

    func explainExternalQuit() {
        sessionError = String(localized: "请在编辑应用中保存并关闭文件，再点「保存并关闭」。")
    }

    private var modifiedSessionDraft: String? {
        guard let draft = sessionDraft, let original = session?.text,
              !draft.utf8.elementsEqual(original.utf8) else { return nil }
        return draft
    }

    func perform(_ operation: FileOperation) {
        guard !isWorking else { return }
        status = nil
        if case .extract(_, installIfMissing: true) = operation {
            workingMessage = String(localized: "正在准备 7-Zip 并解压…")
        }
        isWorking = true
        Task { [weak self, fileSystem] in
            let result = await fileSystem.perform(operation) { source, target in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "是否替换「\(target.lastPathComponent)」？")
                alert.informativeText = String(localized: "目标：\(target.path)\n来源：\(source.path)\n替换会覆盖目标项目及其内容。")
                alert.addButton(withTitle: String(localized: "跳过")).keyEquivalent = "\r"
                alert.addButton(withTitle: String(localized: "替换")).hasDestructiveAction = true
                return alert.runModal() == .alertSecondButtonReturn
            }
            guard let self else { return }
            isWorking = false
            workingMessage = String(localized: "正在处理文件…")
            if !result.trashedPaths.isEmpty {
                recentFiles.removeAll { entry in
                    result.trashedPaths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
                }
            }
            if case let .rename(source, _) = operation, let name = result.outputName {
                renamedRecentFiles(from: source, to: source.deletingLastPathComponent().appendingPathComponent(name))
            }
            if let outputName = result.outputName {
                status = String(localized: "\(operation.completion)「\(outputName)」")
            } else if result.completed > 0 {
                status = String(localized: "\(operation.completion)（\(result.completed) 项）")
            }
            if !result.failures.isEmpty {
                let remaining = result.failures.count - 5
                let details = result.failures.prefix(5).joined(separator: "\n")
                let summary = remaining > 0 ? String(localized: "\n另有 \(remaining) 个项目操作失败。") : ""
                notice = FileNotice(
                    title: result.completed > 0 ? String(localized: "部分项目操作失败") : String(localized: "文件操作失败"),
                    message: details + summary
                )
            } else if let source = result.archiveNeedingSevenZip {
                notice = FileNotice(
                    title: String(localized: "安装 7-Zip 并解压？"),
                    message: String(localized: "未找到 7-Zip。文件桌可以从 7-Zip 官方 GitHub 下载并校验安装包，安装到当前用户的应用支持目录，然后继续解压「\(source.lastPathComponent)」。"),
                    archiveNeedingSevenZip: source
                )
            } else if let copy = result.encryptedCopy {
                notice = FileNotice(
                    title: String(localized: "加密成功，要将明文原文件移到废纸篓吗？"),
                    message: String(localized: "已生成「\(copy.encrypted.lastPathComponent)」。请选择是否保留原文件「\(copy.original.lastPathComponent)」。"),
                    encryptedCopy: copy
                )
            }
            refresh()
        }
    }

    private func enter(_ destination: URL) {
        directory = destination
        allItems = []
        replaceItems([])
        status = nil
        let wasSearching = !searchTerm.isEmpty
        query = ""
        if !wasSearching { refresh() }
    }

    private func replaceItems(_ results: [FileItem]) {
        items = results
        if !selection.isEmpty {
            selection.formIntersection(items.lazy.map(\.id))
        }
    }
}
