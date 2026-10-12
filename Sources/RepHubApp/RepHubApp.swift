import AppKit
import SwiftUI
import DesignSystem
import GitAdapter
import RepositoryApplication
import RepHubUI
import SVNAdapter
import AIApplication
import AIAdapters

@main
struct RepHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appearance = AppearanceStore()
    @State private var workspace: WorkspaceModel
    @State private var aiSettings: AISettingsStore
    private let aiService: AIService

    init() {
        let secrets = KeychainAISecretStore()
        let settings = AISettingsStore(secrets: secrets)
        let service = AIService(providers: [OpenAICompatibleProvider(), OpenAIResponsesProvider(), AnthropicMessagesProvider(),
                                            CLIProvider(kind: .codexCLI), CLIProvider(kind: .claudeCLI)], secrets: secrets)
        self.aiService = service
        let repositories = RepositoryService(providers: [GitProvider(), SVNProvider()])
        _aiSettings = State(initialValue: settings)
        _workspace = State(initialValue: WorkspaceModel(service: repositories,
                                                        aiSettings: settings, aiService: service,
                                                        recentRepositories: RecentRepositoryStore(defaults: .standard),
                                                        workspaceLinks: WorkspaceLinkStore(defaults: .standard),
                                                        monitor: WorkspaceMonitor(service: repositories, defaults: .standard)))
    }

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
                Button("打开仓库…", action: workspace.showRepositoryAcquisition)
                    .keyboardShortcut("o")
                    .disabled(workspace.isOperating)
                RecentRepositoriesMenu(model: workspace)
            }
            CommandMenu("项目") {
                Button("打开仓库…", action: workspace.showRepositoryAcquisition)
                    .disabled(workspace.isOperating)
                RecentRepositoriesMenu(model: workspace)
                Divider()
                Button("刷新仓库", action: workspace.refresh)
                    .keyboardShortcut("r")
                    .disabled(workspace.workspace == nil || workspace.isLoading || workspace.isOperating)
                Button("仓库操作与版本比较…", action: workspace.prepareManagement)
                    .disabled(workspace.selectedBinding == nil || workspace.isOperating)
                Button("关联工作副本…", action: workspace.chooseLinkedFolder)
                    .disabled(workspace.workspace?.bindings.isEmpty != false || workspace.isOperating)
                Divider()
                Button("关闭仓库", action: workspace.closeWorkspace)
                    .disabled(workspace.workspace == nil || workspace.isOperating)
            }
        }

        Settings {
            TabView {
                ThemeSettingsView(appearance: appearance)
                    .tabItem { Label("外观", systemImage: "paintpalette") }
                AISettingsView(store: aiSettings, service: aiService)
                    .tabItem { Label("AI 与场景", systemImage: "sparkles") }
            }
            .frame(width: 760, height: 600)
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
        // 本地应用包原地重建时，Dock 可能继续使用首次注册的占位图标。
        // 直接从当前包加载，确保运行中的图标与本次打包资源一致。
        if let iconURL = Bundle.main.url(forResource: "RepHub", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL), icon.isValid {
            NSApplication.shared.applicationIconImage = icon
        }
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
