import AppKit
import SwiftUI

enum BrowserColors {
    static let violet = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.73, green: 0.66, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.33, green: 0.23, blue: 0.76, alpha: 1)
    })
    static let control = Color.primary.opacity(0.055)
}

private struct BrowserGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    #if compiler(>=6.2)
                    if #available(macOS 26, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        shape.fill(.regularMaterial)
                    }
                    #else
                    shape.fill(.regularMaterial)
                    #endif
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.separator.opacity(reduceTransparency ? 1 : 0.45), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func browserGlass(cornerRadius: CGFloat) -> some View {
        modifier(BrowserGlass(cornerRadius: cornerRadius))
    }
}

// Lay out the full panel and reveal it by animating the space it occupies.
struct SlidingPanel: Layout {
    let axis: Axis
    var progress: CGFloat
    var anchor: UnitPoint = .topLeading

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func panelProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        axis == .horizontal
            ? ProposedViewSize(width: nil, height: proposal.height)
            : ProposedViewSize(width: proposal.width, height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let panel = subviews.first else { return .zero }
        var size = panel.sizeThatFits(panelProposal(proposal))
        if axis == .horizontal { size.width *= progress } else { size.height *= progress }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let position = CGPoint(x: bounds.minX + bounds.width * anchor.x, y: bounds.minY + bounds.height * anchor.y)
        subviews.first?.place(at: position, anchor: anchor,
                              proposal: panelProposal(ProposedViewSize(bounds.size)))
    }
}

struct ToolButton: View {
    @Environment(\.browserAccent) private var accent
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? accent : Color.primary)
                .frame(width: 29, height: 28)
                .background(active ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct FileInspector: View {
    @Environment(\.browserAccent) private var accent
    let items: [FileItem]
    let isWorking: Bool
    let open: (FileItem) -> Void
    let preview: (FileItem) -> Void
    let editTags: (FileItem) -> Void
    let crypt: (FileItem) -> Void
    let changePassword: (FileItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("详细信息")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if items.count == 1, let item = items.first {
                    glyph(item.symbol, title: item.name, detail: item.kind)
                    VStack(alignment: .leading, spacing: 11) {
                        if let modified = item.modified {
                            info(String(localized: "修改日期"), modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        if item.size != nil {
                            info(String(localized: "大小"), item.formattedSize)
                        }
                        info(String(localized: "位置"), item.url.deletingLastPathComponent().path)
                        if item.canEditTags {
                            info(String(localized: "标签"), item.tags.isEmpty ? String(localized: "未添加") : item.tags.joined(separator: " · "))
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if !item.isEncrypted {
                            HStack(spacing: 8) {
                                Button("打开") { open(item) }
                                Button("快速预览") { preview(item) }
                            }
                        }
                        if item.canEditTags {
                            Button("编辑标签…", systemImage: "tag") { editTags(item) }
                                .disabled(isWorking)
                        }
                        if item.isRegularFile {
                            Button(
                                item.isEncrypted ? String(localized: "解密文件…") : String(localized: "加密文件…"),
                                systemImage: item.isEncrypted ? "lock.open" : "lock"
                            ) { crypt(item) }
                            .disabled(isWorking)
                            if item.isEncrypted {
                                Button("修改密码…", systemImage: "key") { changePassword(item) }
                                    .disabled(isWorking)
                            }
                        }
                    }
                    .controlSize(.small)
                } else if items.isEmpty {
                    glyph("doc.text.magnifyingglass", title: String(localized: "未选择项目"), detail: String(localized: "选择文件或文件夹以查看属性。"))
                } else {
                    glyph("square.stack", title: String(localized: "已选择 \(items.count) 个项目"), detail: String(localized: "使用文件操作菜单批量处理。"))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func glyph(_ symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 37, weight: .light))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 143)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}

extension FileItem {
    var formattedSize: String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }
}

struct BrowserPrompt: Identifiable {
    enum Content {
        case goToFolder
        case name(NamePrompt)
        case tags(FileItem)
        case crypt(FileItem, CipherMode)
        case changePassword(FileItem)
    }

    let id = UUID()
    let content: Content
}

struct FolderPathInput {
    private(set) var text = ""
    private(set) var query = ""
    private(set) var selected: Int?

    mutating func edit(_ value: String) {
        // SwiftUI also echoes programmatic previews through the text field binding.
        guard value != text else { return }
        text = value
        query = value
        selected = nil
    }

    func candidates(recent: [String], completions: [String], completedQuery: String) -> [String] {
        if query.isEmpty { return Array(recent.prefix(5)) }
        return query == completedQuery ? completions : []
    }

    mutating func move(down: Bool, in candidates: [String]) {
        guard !candidates.isEmpty else { return }
        let last = candidates.count - 1
        let index = down ? min((selected ?? -1) + 1, last) : max((selected ?? candidates.count) - 1, 0)
        selected = index
        // Preview a row without replacing the query that produced the list.
        text = Self.folderPath(candidates[index])
    }

    mutating func accept(_ candidate: String) {
        text = Self.folderPath(candidate)
        query = text
        selected = nil
    }

    private static func folderPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

struct GoToFolderSheet: View {
    @Environment(\.browserAccent) private var accent
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFocused: Bool
    @State private var input = FolderPathInput()
    @State private var error: String?
    @State private var suggestions: [String] = []
    @State private var suggestedFor = ""

    var body: some View {
        let visibleSuggestions = input.candidates(recent: model.recentPaths, completions: suggestions, completedQuery: suggestedFor)
        VStack(alignment: .leading, spacing: 14) {
            Text("前往文件夹").font(.headline)
            TextField("输入路径，例如 ~/Downloads", text: Binding(get: { input.text }, set: { input.edit($0) }))
                .textFieldStyle(.roundedBorder)
                .focused($pathFocused)
                .onSubmit(go)
                .onChange(of: input.text) { error = nil }
                .onKeyPress(keys: [.tab, .downArrow, .upArrow]) { key in
                    guard key.modifiers.isDisjoint(with: [.command, .control, .option, .shift]) else { return .ignored }
                    guard !visibleSuggestions.isEmpty else {
                        return key.key == .tab && !input.query.isEmpty && suggestedFor != input.query ? .handled : .ignored
                    }
                    if key.key == .tab {
                        let index = input.selected ?? 0
                        if visibleSuggestions.indices.contains(index) { input.accept(visibleSuggestions[index]) }
                    } else {
                        input.move(down: key.key == .downArrow, in: visibleSuggestions)
                    }
                    return .handled
                }
                .task(id: input.query) {
                    let query = input.query
                    guard !query.isEmpty else { return }
                    let matches = await FileSystem.folderCompletions(for: query, relativeTo: model.directory, showHidden: model.showHidden)
                    guard !Task.isCancelled, input.query == query else { return }
                    suggestions = matches
                    suggestedFor = query
                }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSuggestions.indices, id: \.self) { index in
                            Button {
                                input.accept(visibleSuggestions[index])
                                pathFocused = true
                            } label: {
                                Label(visibleSuggestions[index], systemImage: input.query.isEmpty ? "clock" : "folder")
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(index == input.selected ? accent.opacity(0.13) : .clear)
                            .accessibilityAddTraits(index == input.selected ? .isSelected : [])
                        }
                    }
                }
                // Keep the sheet and its text field stationary as completions change.
                .frame(height: 5 * 25)
                .onChange(of: input.selected) { _, index in
                    if let index { reader.scrollTo(index) }
                }
                .onChange(of: visibleSuggestions) { reader.scrollTo(0, anchor: .top) }
            }
            Text(error ?? (input.query.isEmpty && !visibleSuggestions.isEmpty
                            ? String(localized: "↑ ↓ 选择最近路径，回车前往，或继续输入子目录。")
                            : String(localized: "↑ ↓ 选择文件夹，Tab 补全，回车前往。")))
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : .red)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("前往", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.text.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear { pathFocused = true }
    }

    private func go() {
        guard !input.text.isEmpty else { return }
        if model.goToFolder(input.text) {
            dismiss()
        } else {
            error = String(localized: "找不到这个文件夹，请检查路径和访问权限。")
        }
    }
}

struct NamePrompt {
    enum Target {
        case folder(URL)
        case file(URL, NewFileFormat)
        case item(URL)
    }

    let title: String
    let initialName: String
    let target: Target

    func operation(_ name: String) -> FileOperation {
        switch target {
        case .file(let url, let format): .createFile(parent: url, name: name, format: format)
        case .folder(let url): .createFolder(parent: url, name: name)
        case .item(let url): .rename(source: url, name: name)
        }
    }
}

struct NameSheet: View {
    let prompt: NamePrompt
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String

    init(prompt: NamePrompt, save: @escaping (String) -> Void) {
        self.prompt = prompt
        self.save = save
        // A new prompt seeds an independent draft.
        _name = State(initialValue: prompt.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(prompt.title)
                .font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let value = name
                    dismiss()
                    save(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == prompt.initialName)
            }
        }
        .padding(22)
        .frame(width: 365)
        .onAppear { nameFocused = true }
    }
}
