import AppKit
import SwiftUI

enum BrowserColors {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.73, green: 0.66, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.33, green: 0.23, blue: 0.76, alpha: 1)
    })
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let control = Color.primary.opacity(0.055)
}

struct ToolButton: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? BrowserColors.accent : Color.primary)
                .frame(width: 29, height: 28)
                .background(active ? BrowserColors.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct FileInspector: View {
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
                            info("修改日期", modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        if item.size != nil {
                            info("大小", item.formattedSize)
                        }
                        info("位置", item.url.deletingLastPathComponent().path)
                        if item.isFolder {
                            info("标签", item.tags.isEmpty ? "未添加" : item.tags.joined(separator: " · "))
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
                        if item.isFolder {
                            Button("编辑标签…", systemImage: "tag") { editTags(item) }
                                .disabled(isWorking)
                        } else if item.isRegularFile {
                            Button(
                                item.isEncrypted ? "解密文件…" : "加密文件…",
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
                    glyph("doc.text.magnifyingglass", title: "未选择项目", detail: "选择文件或文件夹以查看属性。")
                } else {
                    glyph("square.stack", title: "已选择 \(items.count) 个项目", detail: "使用文件操作菜单批量处理。")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrowserColors.control.opacity(0.45))
    }

    private func glyph(_ symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 37, weight: .light))
                .foregroundStyle(BrowserColors.accent)
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
        .background(BrowserColors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
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

struct GoToFolderSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFocused: Bool
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("前往文件夹").font(.headline)
            TextField("输入路径，例如 ~/Downloads", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($pathFocused)
                .onChange(of: path) { error = nil }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("前往") {
                    if model.goToFolder(path) {
                        dismiss()
                    } else {
                        error = "找不到这个文件夹，请检查路径和访问权限。"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear { pathFocused = true }
    }
}

struct NamePrompt {
    enum Target {
        case folder(URL)
        case item(URL)
    }

    let title: String
    let initialName: String
    let target: Target

    func operation(_ name: String) -> FileOperation {
        switch target {
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
