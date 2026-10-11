import AppKit
import SwiftUI
import DesignSystem
import GitAdapter
import RepositoryApplication
import RepHubUI
import SVNAdapter

@main
struct RepHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appearance = AppearanceStore()
    @State private var workspace = WorkspaceModel(service: RepositoryService(providers: [
        GitProvider(), SVNProvider()
    ]))

    var body: some Scene {
        Window("RepHub", id: "workspace") {
            WorkspaceView(model: workspace, appearance: appearance)
                .frame(minWidth: 1080, minHeight: 700)
                .background(WindowSurface(isOperating: workspace.isOperating))
                .onAppear { delegate.workspace = workspace }
        }
        .defaultSize(width: 1440, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开本地文件夹…", action: workspace.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(workspace.isOperating)
            }
            CommandMenu("项目") {
                Button("打开仓库…", action: workspace.chooseFolder)
                    .disabled(workspace.isOperating)
                Divider()
                Button("刷新仓库", action: workspace.refresh)
                    .keyboardShortcut("r")
                    .disabled(workspace.workspace == nil || workspace.isLoading || workspace.isOperating)
            }
        }

        Settings {
            ThemeSettingsView(appearance: appearance)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
    }
}

/// 仅对本工作台隐藏系统标题栏分隔线，保留原生工具栏及窗口行为。
private struct WindowSurface: NSViewRepresentable {
    let isOperating: Bool
    func makeNSView(context: Context) -> SurfaceView { SurfaceView(frame: .zero) }
    func updateNSView(_ nsView: SurfaceView, context: Context) {
        nsView.isOperating = isOperating
        nsView.applyWindowState()
    }

    final class SurfaceView: NSView {
        var isOperating = false
        func applyWindowState() {
            window?.titlebarSeparatorStyle = .none
            window?.standardWindowButton(.closeButton)?.isEnabled = !isOperating
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowState()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, workspace.isOperating else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仓库操作尚未结束"
        alert.informativeText = "请等待操作和状态核对完成后退出。取消操作不会回滚已经更新的文件。"
        alert.addButton(withTitle: "等待完成")
        alert.addButton(withTitle: "取消操作")
        if alert.runModal() == .alertSecondButtonReturn { workspace.cancelOperation() }
        return .terminateCancel
    }
}
