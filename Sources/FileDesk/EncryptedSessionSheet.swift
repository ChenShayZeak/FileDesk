import AppKit
import Quartz
import SwiftUI

struct EncryptedSessionSheet: View {
    let session: EncryptedFileSession
    @Binding var draft: String?
    let isWorking: Bool
    let isEditingExternally: Bool
    let error: String?
    let openExternally: () -> Void
    let close: (Bool) -> Void

    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(session.title, systemImage: "lock.open")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let originalText = session.text, !isEditingExternally {
                TextEditor(text: Binding(get: { draft ?? originalText }, set: { draft = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("临时解密文件内容")
                    .disabled(isWorking)
            } else {
                DocumentPreview(file: session.file)
            }

            Divider()

            if isEditingExternally {
                Text("请在默认应用中保存并关闭文件，再回到这里点「保存并关闭」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("用默认应用打开", action: openExternally)
                    .disabled(isWorking)
                if error != nil {
                    Button("放弃修改…", role: .destructive) { confirmDiscard = true }
                        .disabled(isWorking)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("保存并关闭") { close(false) }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(isWorking)
            }
        }
        .padding(16)
        .frame(width: 710, height: 480)
        .confirmationDialog(
            "放弃对临时副本的修改？", isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button("放弃并删除临时副本", role: .destructive) { close(true) }
        }
    }
}

private struct DocumentPreview: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> NSView {
        let preview: QLPreviewView? = QLPreviewView(frame: .zero, style: .normal)
        guard let preview else {
            return NSTextField(labelWithString: String(localized: "无法预览此文件。可用默认应用打开。"))
        }
        preview.previewItem = file as NSURL
        return preview
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? QLPreviewView)?.previewItem = nil
    }
}
