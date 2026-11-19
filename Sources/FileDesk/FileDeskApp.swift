import AppKit
import SwiftUI

@main
@MainActor
struct FileDeskApp: App {
    @NSApplicationDelegateAdaptor(FileDeskAppDelegate.self) private var appDelegate
    @AppStorage("browserTheme") private var theme = BrowserTheme.violet
    @AppStorage("browserCustomColor") private var customColorData = Data()
    @AppStorage("browserAppearance") private var appearance = AppAppearance.system
    @State private var model = BrowserModel()

    var body: some Scene {
        Window("文件桌", id: "file-desk") {
            BrowserView(model: model)
                .environment(\.browserAccent, theme.color(customData: customColorData))
                .tint(theme.color(customData: customColorData))
                .frame(minWidth: 820, minHeight: 540)
                .handlesExternalEvents(preferring: ["file:"], allowing: ["file:"])
                .task {
                    appDelegate.model = model
                    model.refresh()
                    await model.refreshRecentFiles()
                }
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.hiddenTitleBar)
        .onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = appearance.nativeAppearance
        }
        .handlesExternalEvents(matching: ["file:"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("设为默认文件夹浏览器…") {
                    Task { await model.setDefaultApp(Bundle.main.bundleURL, for: .folder) }
                }
            }
            CommandGroup(after: .help) {
                Button("检查更新…") { Task { await model.checkForUpdate() } }
                    .disabled(model.isWorking || model.session != nil)
            }
        }

        Settings {
            AppSettings(theme: $theme, customColorData: $customColorData, appearance: $appearance)
                .tint(theme.color(customData: customColorData))
        }
    }
}

@MainActor
final class FileDeskAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model?.refreshRecentFiles() }
    }

    @objc(openFolderInFileDesk:userData:error:)
    func openFolderInFileDesk(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let folder = Self.selectedFolder(on: pasteboard) else {
            error.pointee = String(localized: "请在访达中选中一个普通文件夹。") as NSString
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: Bundle.main.bundleURL,
                                configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in NSAlert(error: error).runModal() }
            }
        }
    }

    static func selectedFolder(on pasteboard: NSPasteboard) -> URL? {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard urls.count == 1, let folder = urls.first, FileSystem.item(at: folder).isFolder else { return nil }
        return folder
    }

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
