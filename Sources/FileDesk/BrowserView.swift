import AppKit
import QuickLook
import SwiftUI

@MainActor
struct BrowserView: View {
    let model: BrowserModel
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("gridLayout") private var gridLayout = false
    @FocusState private var searchFocused: Bool
    @State private var prompt: BrowserPrompt?
    @State private var trashItems: [FileItem] = []

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    filePane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        FileInspector(
                            items: model.selectedItems, isWorking: model.isWorking,
                            open: open, preview: showPreview, editTags: editTags,
                            crypt: crypt, changePassword: changePassword
                        )
                        .frame(width: 226)
                    }
                }
                Divider()
                statusBar
            }
            .background(.background)
        }
        .tint(BrowserColors.accent)
        .onOpenURL { url in
            guard prompt == nil, trashItems.isEmpty, model.session == nil, !model.isWorking else {
                model.notice = FileNotice(title: "暂时无法打开项目", message: "请先完成当前操作，然后重新打开「\(url.lastPathComponent)」。")
                return
            }
            model.openExternalURL(url, decrypt: crypt)
        }
        .quickLookPreview($model.preview)
        .sheet(item: $prompt) { prompt in
            switch prompt.content {
            case .goToFolder:
                GoToFolderSheet(model: model)
            case .name(let namePrompt):
                NameSheet(prompt: namePrompt) { model.perform(namePrompt.operation($0)) }
            case .tags(let item):
                TagSheet(item: item) { model.perform(.setTags(folder: item.url, tags: $0)) }
            case .changePassword(let item):
                ChangePasswordSheet(item: item, isWorking: model.isWorking, error: model.sessionError) { old, new in
                    await model.changePassword(for: item, old: old, new: new)
                }
                .interactiveDismissDisabled(model.isWorking)
            case .crypt(let item, let mode):
                if mode == .encrypt {
                    PasswordSheet(item: item, mode: mode) {
                        model.perform(.encrypt(source: item.url, password: $0))
                    }
                } else if let session = model.session {
                    EncryptedSessionSheet(
                        session: session,
                        draft: $model.sessionDraft,
                        isWorking: model.isWorking,
                        isEditingExternally: model.isEditingExternally,
                        error: model.sessionError,
                        openExternally: { Task { await model.editSessionExternally() } },
                        close: { discard in Task { await model.closeSession(discardingChanges: discard) } }
                    )
                    .interactiveDismissDisabled()
                } else {
                    PasswordSheet(item: item, mode: mode, isWorking: model.isWorking, error: model.sessionError) { password in
                        Task { await model.unlock(item, password: password) }
                    }
                    .interactiveDismissDisabled(model.isWorking)
                }
            }
        }
        .onChange(of: model.session?.id) { previous, current in
            if previous != nil && current == nil { prompt = nil }
        }
        .alert(
            model.notice?.title ?? "提示",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            presenting: model.notice
        ) { notice in
            if let copy = notice.encryptedCopy {
                Button("保留原文件", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                Button("将原文件移到废纸篓", role: .destructive) {
                    model.perform(.trashEncryptedOriginal(copy))
                }
            } else if let source = notice.archiveNeedingSevenZip {
                Button("取消", role: .cancel) {}
                Button("安装并解压") { model.perform(.extract(source, installIfMissing: true)) }
            } else {
                Button("好", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog(
            "将选中的项目移到废纸篓？",
            isPresented: Binding(
                get: { !trashItems.isEmpty },
                set: { if !$0 { trashItems = [] } }
            ),
            titleVisibility: .visible,
            presenting: trashItems
        ) { items in
            Button("移到废纸篓", role: .destructive) {
                model.perform(.trash(sources: items.map(\.url)))
            }
        } message: { items in
            Text(items.count == 1 ? items[0].name : "已选择 \(items.count) 个项目。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
                    .background(BrowserColors.accent, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text("文件桌")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 17)
            .padding(.top, 43)
            .padding(.bottom, 25)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarLabel("常用位置")
                    ForEach(model.standardFavorites) { favorite in
                        favoriteButton(favorite)
                    }

                    if !model.customFavorites.isEmpty {
                        sidebarLabel("我的收藏")
                            .padding(.top, 19)
                        ForEach(model.customFavorites) { favorite in
                            favoriteButton(favorite)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().padding(.horizontal, 15)
            Button {
                model.chooseDirectory()
            } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .padding(11)
        }
        .background(BrowserColors.sidebar)
    }

    private func sidebarLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.bottom, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func favoriteButton(_ favorite: Favorite) -> some View {
        let active = favorite.url.path == model.directory.path
        return Button {
            model.navigate(to: favorite.url)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: favorite.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(favorite.title)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 33)
            .foregroundStyle(active ? BrowserColors.accent : Color.primary)
            .background(active ? BrowserColors.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(favorite.url.path)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var toolbar: some View {
        @Bindable var model = model

        return HStack(spacing: 9) {
            HStack(spacing: 1) {
                ToolButton(title: "后退", symbol: "chevron.left", action: model.goBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                ToolButton(title: "前进", symbol: "chevron.right", action: model.goForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                ToolButton(title: "上一级", symbol: "arrow.up", action: model.goUp)
                    .disabled(!model.canGoUp)
                ToolButton(title: "前往文件夹…", symbol: "arrow.turn.down.right") {
                    prompt = BrowserPrompt(content: .goToFolder)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browserDialogPresented || model.preview != nil)
            }
            .padding(2)
            .background(BrowserColors.control, in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("聚焦搜索")
                TextField("搜索文件名或标签", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("按文件名或标签搜索当前文件夹")
                    .onExitCommand {
                        model.query = ""
                        searchFocused = false
                    }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 125, idealWidth: 190, maxWidth: 214)
            .frame(height: 32)
            .background(BrowserColors.control, in: RoundedRectangle(cornerRadius: 8))

            ToolButton(title: "复制路径", symbol: "link") {
                model.copyPaths(model.selectedItems.map(\.url))
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.selection.isEmpty)

            ToolButton(title: "新建文件夹", symbol: "folder.badge.plus", action: createFolder)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.isWorking || model.readError != nil)

            Menu {
                Picker("排序方式", selection: $model.sort) {
                    ForEach(FileSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Toggle("显示隐藏文件", isOn: $model.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("刷新", action: model.refresh)
                    .keyboardShortcut("r", modifiers: .command)
                Menu("默认打开方式") {
                    Button("文件夹用文件桌打开…") {
                        Task { await model.setDefaultApp(Bundle.main.bundleURL, for: .folder) }
                    }
                    Button("文件夹用访达打开…") {
                        Task {
                            let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
                            await model.setDefaultApp(finder, for: .folder)
                        }
                    }
                    Divider()
                    Button(".filedesk 文件用文件桌打开…") {
                        Task { await model.setDefaultApp(Bundle.main.bundleURL, for: CipherMode.contentType) }
                    }
                }
                Divider()
                Button("粘贴文件", action: model.paste)
                    .disabled(model.isWorking || model.readError != nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("排序与更多操作")
            .accessibilityLabel("排序与更多操作")

            ToolButton(title: showInspector ? "隐藏详细信息" : "显示详细信息", symbol: "sidebar.right", active: showInspector) {
                showInspector.toggle()
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 62)
    }

    private var filePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                breadcrumbBar
                HStack(spacing: 9) {
                    Text(model.directoryTitle)
                        .font(.system(size: 29, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                        .help(model.directory.path)
                    ToolButton(
                        title: model.isFavorite ? "移除收藏" : "收藏当前文件夹",
                        symbol: model.isFavorite ? "star.fill" : "star",
                        active: model.isFavorite,
                        action: model.toggleFavorite
                    )
                    .disabled(!model.canFavorite || model.readError != nil)
                    Spacer(minLength: 8)
                    HStack(spacing: 1) {
                        ToolButton(title: "列表视图", symbol: "list.bullet", active: !gridLayout) {
                            gridLayout = false
                        }
                        ToolButton(title: "网格视图", symbol: "square.grid.2x2", active: gridLayout) {
                            gridLayout = true
                        }
                    }
                    .padding(2)
                    .background(BrowserColors.control, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 17)

            if let error = model.readError {
                emptyState(symbol: "exclamationmark.folder", title: "无法读取文件夹", detail: error) {
                    Button("重新加载", action: model.refresh)
                }
            } else if model.isLoading && model.items.isEmpty {
                ProgressView("正在读取…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyState(symbol: "folder", title: "文件夹为空", detail: "这里还没有可见的文件。") {
                        Button("新建文件夹", action: createFolder)
                            .disabled(model.isWorking)
                    }
                } else {
                    emptyState(symbol: "magnifyingglass", title: "没有匹配的文件", detail: "试试其他文件名或标签。") {
                        Button("清除搜索") { model.query = "" }
                    }
                }
            } else if gridLayout {
                fileGrid
            } else {
                fileTable
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                let breadcrumbs = model.breadcrumbs
                ForEach(breadcrumbs, id: \.self) { location in
                    if location != breadcrumbs.first {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    if location == model.directory {
                        Text(model.title(for: location))
                            .fontWeight(.medium)
                    } else {
                        Button(model.title(for: location)) { model.navigate(to: location) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
        }
        .scrollIndicators(.hidden)
        .contextMenu {
            Button("复制当前文件夹路径") { model.copyPaths([model.directory]) }
        }
    }

    private var fileTable: some View {
        @Bindable var model = model

        return Table(model.items, selection: $model.selection) {
            TableColumn("名称") { (item: FileItem) in
                Label {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if item.isHidden { hiddenBadge }
                        if !item.tags.isEmpty {
                            Text(item.tags.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.isFolder ? BrowserColors.accent : Color.secondary)
                        .frame(width: 19)
                }
                .help(([item.name] + item.tags).joined(separator: " · "))
            }
            .width(min: 125, ideal: 260)
            TableColumn("修改日期") { (item: FileItem) in
                if let modified = item.modified {
                    Text(modified.formatted(date: .numeric, time: .shortened))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 97, ideal: 136)
            TableColumn("大小") { (item: FileItem) in
                Text(item.formattedSize).foregroundStyle(.secondary)
            }
            .width(min: 52, ideal: 72)
        }
        .contextMenu(forSelectionType: URL.self) { selection in
            if selection.isEmpty {
                Button("新建文件夹", action: createFolder)
                    .disabled(model.isWorking)
                Button("粘贴文件", action: model.paste)
                    .disabled(model.isWorking)
                Button("刷新", action: model.refresh)
            } else {
                itemActions(model.items.filter { selection.contains($0.id) })
            }
        } primaryAction: { selection in
            if selection.count == 1, let item = model.items.first(where: { selection.contains($0.id) }) {
                open(item)
            }
        }
        .padding(.horizontal, 12)
    }

    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                ForEach(model.items) { item in
                    let selected = model.selection.contains(item.id)
                    Button {
                        if NSEvent.modifierFlags.contains(.command) {
                            if selected { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
                        } else {
                            model.selection = [item.id]
                        }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(item.isFolder ? BrowserColors.accent : Color.secondary)
                                .accessibilityHidden(true)
                            Text(item.name)
                                .font(.system(size: 11))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.middle)
                            if !item.tags.isEmpty {
                                Text(item.tags.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .background(
                            selected ? BrowserColors.accent.opacity(0.16) : BrowserColors.control.opacity(0.62),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(alignment: .topTrailing) {
                            if item.isHidden { hiddenBadge.padding(4) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        model.selection = [item.id]
                        open(item)
                    })
                    .contextMenu { itemActions(selected ? model.selectedItems : [item]) }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(([item.name] + item.tags).joined(separator: " · "))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var hiddenBadge: some View {
        Text("隐藏")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private func itemActions(_ items: [FileItem]) -> some View {
        if items.count == 1, let item = items.first {
            if !item.isEncrypted {
                Button("打开") { open(item) }
                Button("快速预览") { showPreview(item) }
            }
            Button("重命名…") { rename(item) }
                .disabled(model.isWorking)
            itemTools(item)
            Divider()
        }
        Button("复制文件") { model.copy(items) }
        Button("复制路径") { model.copyPaths(items.map(\.url)) }
        Button("移到…") { model.chooseDirectory(for: items) }
            .disabled(model.isWorking)
        Button("在访达中显示") { model.reveal(items) }
        Divider()
        Button("移到废纸篓…", role: .destructive) { trashItems = items }
            .disabled(model.isWorking)
    }

    private var browserDialogPresented: Bool {
        prompt != nil || !trashItems.isEmpty || model.notice != nil
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            let count = model.selection.count
            Text(count == 0 ? "\(model.items.count) 个项目" : "已选中 \(count) 个项目")
            if model.isWorking {
                ProgressView().controlSize(.mini)
                Text(model.workingMessage)
            } else if let status = model.status {
                Text(status).lineLimit(1)
            }
            Spacer(minLength: 8)
            let archive = count == 1 ? model.selectedItems.first : nil
            Button("解压", systemImage: "archivebox") {
                if let archive { model.perform(.extract(archive.url)) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .foregroundStyle(.white)
            .controlSize(.small)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("解压到同一目录（⌘⇧E）")
            .disabled(archive?.isArchive != true || model.isWorking || browserDialogPresented || model.preview != nil)
            ToolButton(title: "移到废纸篓…", symbol: "trash") { trashItems = model.selectedItems }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty || model.isWorking || searchFocused ||
                          browserDialogPresented || model.preview != nil)
            Menu {
                if let item = model.selectedItems.first, model.selection.count == 1 {
                    if !item.isEncrypted {
                        Button("打开") { open(item) }
                        Button("快速预览") { showPreview(item) }
                    }
                    itemTools(item)
                }
                Button("复制文件") { model.copy(model.selectedItems) }
                    .disabled(model.selection.isEmpty)
                Button("复制路径") { model.copyPaths(model.selectedItems.map(\.url)) }
                    .disabled(model.selection.isEmpty)
                Button("粘贴文件", action: model.paste)
                    .disabled(model.isWorking || model.readError != nil)
                Button("移到…") { model.chooseDirectory(for: model.selectedItems) }
                    .disabled(model.selection.isEmpty || model.isWorking)
                Button("移到废纸篓…", role: .destructive) { trashItems = model.selectedItems }
                    .disabled(model.selection.isEmpty || model.isWorking)
            } label: {
                Label("文件操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .frame(height: 33)
        .background(BrowserColors.control.opacity(0.45))
    }

    private func emptyState<Action: View>(
        symbol: String, title: String, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(BrowserColors.accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action().padding(.top, 5)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showPreview(_ item: FileItem) { model.preview = item.url }

    @ViewBuilder
    private func itemTools(_ item: FileItem) -> some View {
        if item.isFolder {
            Button("编辑标签…") { editTags(item) }
                .disabled(model.isWorking)
        } else if item.isRegularFile {
            Button(item.isEncrypted ? "解密文件…" : "加密文件…") { crypt(item) }
                .disabled(model.isWorking)
            if item.isEncrypted {
                Button("修改密码…") { changePassword(item) }
                    .disabled(model.isWorking)
            }
        }
    }

    private func open(_ item: FileItem) {
        if item.isEncrypted {
            crypt(item)
        } else {
            model.open(item)
        }
    }

    private func editTags(_ item: FileItem) {
        guard !model.isWorking else { return }
        prompt = BrowserPrompt(content: .tags(item))
    }

    private func crypt(_ item: FileItem) {
        guard !model.isWorking else { return }
        model.clearSessionError()
        prompt = BrowserPrompt(content: .crypt(item, item.isEncrypted ? .decrypt : .encrypt))
    }

    private func changePassword(_ item: FileItem) {
        guard !model.isWorking else { return }
        model.clearSessionError()
        prompt = BrowserPrompt(content: .changePassword(item))
    }

    private func createFolder() {
        let name = NamePrompt(title: "新建文件夹", initialName: "", target: .folder(model.directory))
        prompt = BrowserPrompt(content: .name(name))
    }

    private func rename(_ item: FileItem) {
        let name = NamePrompt(title: "重命名", initialName: item.name, target: .item(item.url))
        prompt = BrowserPrompt(content: .name(name))
    }
}
