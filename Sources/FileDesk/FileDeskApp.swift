import AppKit
import SwiftUI

@main
@MainActor
struct FileDeskApp: App {
    @NSApplicationDelegateAdaptor(FileDeskAppDelegate.self) private var appDelegate
    @State private var model = BrowserModel()

    var body: some Scene {
        Window("文件桌", id: "file-desk") {
            BrowserView(model: model)
                .frame(minWidth: 820, minHeight: 540)
                .handlesExternalEvents(preferring: ["file:"], allowing: ["file:"])
                .task {
                    appDelegate.model = model
                    model.refresh()
                }
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["file:"])
        .commands {
            CommandGroup(after: .help) {
                Button("检查更新…") { Task { await model.checkForUpdate() } }
                    .disabled(model.isWorking || model.session != nil)
            }
        }
    }
}

@MainActor
final class FileDeskAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isWorking { return .terminateCancel }
        guard model.session != nil else { return .terminateNow }
        if model.isEditingExternally {
            model.explainExternalQuit()
            return .terminateCancel
        }

        Task {
            let didClose = await model.closeSession()
            sender.reply(toApplicationShouldTerminate: didClose)
        }
        return .terminateLater
    }
}
