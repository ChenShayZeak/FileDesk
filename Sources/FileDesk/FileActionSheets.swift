import SwiftUI

struct TagSheet: View {
    let item: FileItem
    let save: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var tagFocused: Bool
    @State private var tags: [String]
    @State private var draft = ""

    init(item: FileItem, save: @escaping ([String]) -> Void) {
        self.item = item
        self.save = save
        // Each sheet starts with the selected folder's current tags.
        _tags = State(initialValue: item.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑文件夹标签").font(.headline)
            Text(item.name).foregroundStyle(.secondary).lineLimit(1)

            if !tags.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 8) {
                                Label(tag, systemImage: "tag")
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除标签 \(tag)")
                            }
                        }
                    }
                    .padding(9)
                }
                .frame(maxHeight: 135)
                .background(BrowserColors.control, in: RoundedRectangle(cornerRadius: 7))
            }

            HStack {
                TextField("输入标签名称", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($tagFocused)
                    .onSubmit(addTag)
                Button("添加", action: addTag)
                    .disabled(!canAdd)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    addTag()
                    dismiss()
                    save(tags)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tags == item.tags && !canAdd)
            }
        }
        .padding(22)
        .frame(width: 390)
        .onAppear { tagFocused = true }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        !trimmedDraft.isEmpty && !tags.contains {
            $0.compare(trimmedDraft, options: .caseInsensitive) == .orderedSame
        }
    }

    private func addTag() {
        guard canAdd else { return }
        tags.append(trimmedDraft)
        draft = ""
    }
}

struct PasswordSheet: View {
    let item: FileItem
    let mode: CipherMode
    var isWorking = false
    var error: String?
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var passwordFocused: Bool
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title).font(.headline)
            Text(item.name).foregroundStyle(.secondary).lineLimit(1)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
            if mode == .encrypt {
                SecureField("确认密码", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                if !confirmation.isEmpty && password != confirmation {
                    Text("两次输入的密码不一致。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(mode == .encrypt
                 ? "将在同一文件夹生成 .filedesk 副本，成功后可选择是否保留明文原文件。请记住密码，解密时需要它。"
                 : "解密后立即打开临时副本。关闭会话时，修改会加密写回，临时副本会删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(mode == .decrypt ? "解密并打开" : mode.title) {
                    let value = password
                    password = ""
                    confirmation = ""
                    if mode == .encrypt { dismiss() }
                    save(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || password.isEmpty || (mode == .encrypt && password != confirmation))
            }
        }
        .padding(22)
        .frame(width: 390)
        .onAppear { passwordFocused = true }
    }
}

@MainActor
struct ChangePasswordSheet: View {
    let item: FileItem
    let isWorking: Bool
    let error: String?
    let save: @MainActor (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var oldPasswordFocused: Bool
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改密码").font(.headline)
            Text(item.name).foregroundStyle(.secondary).lineLimit(1)

            VStack(spacing: 9) {
                SecureField("旧密码", text: $oldPassword)
                    .focused($oldPasswordFocused)
                SecureField("新密码", text: $newPassword)
                SecureField("确认新密码", text: $confirmation)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isWorking)

            if let message = error ?? validationMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("修改密码") {
                    let old = oldPassword
                    let new = newPassword
                    oldPassword = ""
                    newPassword = ""
                    confirmation = ""
                    Task {
                        if await save(old, new) {
                            dismiss()
                        } else {
                            oldPasswordFocused = true
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || oldPassword.isEmpty || newPassword.isEmpty ||
                          newPassword == oldPassword || newPassword != confirmation)
            }
        }
        .padding(22)
        .frame(width: 390)
        .onAppear { oldPasswordFocused = true }
    }

    private var validationMessage: String? {
        if !newPassword.isEmpty && oldPassword == newPassword {
            return "新密码须与旧密码不同。"
        }
        if !confirmation.isEmpty && newPassword != confirmation {
            return "两次输入的新密码不一致。"
        }
        return nil
    }
}
