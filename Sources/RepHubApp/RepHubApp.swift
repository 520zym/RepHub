import AppKit
import SwiftUI
import DesignSystem
import GitAdapter
import RepositoryApplication
import RepHubUI
import SVNAdapter
import AIApplication
import AIAdapters

/// 每次请求新窗口都带唯一值，避免 SwiftUI 将同一仓库请求聚焦到旧窗口。
private struct WorkspaceWindowID: Codable, Hashable {
    let id: UUID
    let directory: URL?
    let showsAcquisition: Bool

    init(directory: URL? = nil, showsAcquisition: Bool = false) {
        id = UUID()
        self.directory = directory
        self.showsAcquisition = showsAcquisition
    }
}

private struct WorkspaceModelFocusKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

private extension FocusedValues {
    var workspaceModel: WorkspaceModel? {
        get { self[WorkspaceModelFocusKey.self] }
        set { self[WorkspaceModelFocusKey.self] = newValue }
    }
}

/// 应用级配置和服务共享；每个窗口仍获得独立的工作区模型与监控器。
@MainActor
private final class AppDependencies {
    let aiSettings: AISettingsStore
    let aiUsage: AIUsageStore
    let aiService: AIService
    let appearance: AppearanceStore
    let authorDirectory: MigrationAuthorDirectoryStore
    let repositoryService: RepositoryService
    let migrationService: RepositoryMigrationService
    let workingCopyMigrationService: WorkingCopyMigrationService
    let recentRepositories: RecentRepositoryStore
    let remoteHistory: RemoteRepositoryHistoryStore
    let workspaceLinks: WorkspaceLinkStore

    init() {
        let secrets = KeychainAISecretStore()
        aiSettings = AISettingsStore(secrets: secrets)
        aiUsage = AIUsageStore()
        appearance = AppearanceStore()
        authorDirectory = MigrationAuthorDirectoryStore(defaults: .standard)
        aiService = AIService(
            providers: [OpenAICompatibleProvider(), OpenAIResponsesProvider(), AnthropicMessagesProvider(),
                        CLIProvider(kind: .codexCLI), CLIProvider(kind: .claudeCLI)],
            secrets: secrets, modelCatalogProvider: HTTPAIModelCatalogProvider(), usageStore: aiUsage
        )

        let svn = SVNProvider()
        let target = GitMigrationTargetProvider()
        let writeGate = RepositoryWriteGate()
        repositoryService = RepositoryService(providers: [GitProvider(), svn], writeGate: writeGate)
        migrationService = RepositoryMigrationService(sources: [svn], targets: [target], writeGate: writeGate)
        workingCopyMigrationService = WorkingCopyMigrationService(source: svn, target: target, writeGate: writeGate)
        recentRepositories = RecentRepositoryStore(defaults: .standard)
        remoteHistory = RemoteRepositoryHistoryStore(defaults: .standard, secrets: KeychainRepositoryCredentialStore())
        workspaceLinks = WorkspaceLinkStore(defaults: .standard)
    }

    @MainActor
    func makeWorkspace() -> WorkspaceModel {
        WorkspaceModel(service: repositoryService, aiSettings: aiSettings, aiService: aiService,
                       recentRepositories: recentRepositories, remoteHistory: remoteHistory,
                       workspaceLinks: workspaceLinks,
                       monitor: WorkspaceMonitor(service: repositoryService, defaults: .standard),
                       migrationService: migrationService,
                       workingCopyMigrationService: workingCopyMigrationService,
                       authorDirectory: authorDirectory)
    }
}

@main
struct RepHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup("RepHub", for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowRoot(initialDirectory: windowID?.directory,
                                showsAcquisition: windowID?.showsAcquisition ?? false,
                                dependencies: dependencies, delegate: delegate)
        }
        .defaultSize(width: 1440, height: 980)
        .commands { WorkspaceCommands() }

        Settings {
            TabView {
                ThemeSettingsView(appearance: dependencies.appearance)
                    .tabItem { Label("外观", systemImage: "paintpalette") }
                AISettingsView(store: dependencies.aiSettings, service: dependencies.aiService, usageStore: dependencies.aiUsage)
                    .tabItem { Label("AI 与场景", systemImage: "sparkles") }
                AuthorDirectorySettingsContent(store: dependencies.authorDirectory, appearance: dependencies.appearance)
                    .tabItem { Label("作者通讯录", systemImage: "person.crop.rectangle.stack") }
            }
            .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity,
                   minHeight: 500, idealHeight: 600, maxHeight: .infinity)
            .preferredColorScheme(dependencies.appearance.preferredColorScheme)
        }
    }
}

private struct WorkspaceWindowRoot: View {
    let initialDirectory: URL?
    let showsAcquisition: Bool
    let dependencies: AppDependencies
    let delegate: AppDelegate
    @State private var workspace: WorkspaceModel
    @State private var didClose = false
    @State private var didOpenInitialContent = false
    @Environment(\.openWindow) private var openWindow

    init(initialDirectory: URL?, showsAcquisition: Bool, dependencies: AppDependencies, delegate: AppDelegate) {
        self.initialDirectory = initialDirectory
        self.showsAcquisition = showsAcquisition
        self.dependencies = dependencies
        self.delegate = delegate
        _workspace = State(initialValue: dependencies.makeWorkspace())
    }

    var body: some View {
        WorkspaceView(model: workspace, appearance: dependencies.appearance, onOpenInNewWindow: openInNewWindow)
            .frame(minWidth: 1080, minHeight: 700)
            .background(WindowSurface(title: workspace.workspace?.name ?? "RepHub", isOperating: workspace.isOperating,
                                      shouldClose: { !workspace.isOperating }, didClose: closeWindow))
            .focusedSceneValue(\.workspaceModel, workspace)
            .onAppear {
                delegate.register(workspace)
                guard !didOpenInitialContent else { return }
                didOpenInitialContent = true
                if let initialDirectory { workspace.open(initialDirectory) }
                else if showsAcquisition { workspace.showRepositoryAcquisition() }
            }
    }

    private func openInNewWindow(_ directory: URL?) {
        openWindow(value: WorkspaceWindowID(directory: directory, showsAcquisition: directory == nil))
    }

    private func closeWindow() {
        guard !didClose, !workspace.isOperating else { return }
        didClose = true
        workspace.closeWindow()
        delegate.unregister(workspace)
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceModel) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口", action: openNewWindow).keyboardShortcut("n")
            Button("打开仓库…") { workspace?.showRepositoryAcquisition() }
                .keyboardShortcut("o").disabled(workspace?.isInteractionLocked ?? true)
            Button("在新窗口打开仓库…", action: openRepositoryInNewWindow)
                .keyboardShortcut("o", modifiers: [.command, .shift])
            if let workspace { RecentRepositoriesMenu(model: workspace, onOpenInNewWindow: openInNewWindow) }
        }
        CommandMenu("项目") {
            Button("打开仓库…") { workspace?.showRepositoryAcquisition() }
                .disabled(workspace?.isInteractionLocked ?? true)
            Button("在新窗口打开仓库…", action: openRepositoryInNewWindow)
            if let workspace { RecentRepositoriesMenu(model: workspace, onOpenInNewWindow: openInNewWindow) }
            Divider()
            Button("刷新仓库") { workspace?.refresh() }.keyboardShortcut("r")
                .disabled(workspace?.workspace == nil || workspace?.isLoading == true || workspace?.isInteractionLocked == true)
            Button("仓库操作与版本比较…") { workspace?.prepareManagement() }
                .disabled(workspace?.selectedBinding == nil || workspace?.isWorkspaceMutationLocked == true)
            Button("关联工作副本…") { workspace?.chooseLinkedFolder() }
                .disabled(workspace?.workspace?.bindings.isEmpty != false || workspace?.isInteractionLocked == true)
            Button("全历史搜索…") { workspace?.showFullHistorySearch() }
                .disabled(workspace?.workspace == nil || workspace?.isInteractionLocked == true)
            Button("搁置与恢复改动…") { workspace?.showShelves() }
                .disabled(workspace?.workspace == nil || workspace?.isWorkspaceMutationLocked == true)
            Button("迁移仓库…") { workspace?.showRepositoryMigration() }
                .disabled(workspace?.isInteractionLocked ?? true)
            Divider()
            Button("关闭仓库") { workspace?.closeWorkspace() }
                .disabled(workspace?.workspace == nil || workspace?.isInteractionLocked == true)
        }
    }

    private func openNewWindow() { openWindow(value: WorkspaceWindowID()) }
    private func openRepositoryInNewWindow() { openWindow(value: WorkspaceWindowID(showsAcquisition: true)) }
    private func openInNewWindow(_ directory: URL) { openWindow(value: WorkspaceWindowID(directory: directory)) }
}

private struct AuthorDirectorySettingsContent: View {
    let store: MigrationAuthorDirectoryStore
    @Bindable var appearance: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        MigrationAuthorDirectorySettingsView(store: store,
            palette: appearance.palette(for: appearance.preferredColorScheme ?? colorScheme))
    }
}

/// 保留 SwiftUI 原有委托，并拒绝关闭仍在执行真实操作的窗口（包括 Cmd-W）。
private struct WindowSurface: NSViewRepresentable {
    let title: String
    let isOperating: Bool
    let shouldClose: () -> Bool
    let didClose: () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView(frame: .zero)
        view.shouldClose = shouldClose; view.didClose = didClose
        return view
    }
    func updateNSView(_ nsView: SurfaceView, context: Context) {
        nsView.title = title; nsView.isOperating = isOperating; nsView.shouldClose = shouldClose; nsView.didClose = didClose
        nsView.applyWindowState()
    }

    final class SurfaceView: NSView {
        var title = "RepHub"
        var isOperating = false
        var shouldClose: () -> Bool = { true }
        var didClose: () -> Void = {}
        private var proxy: CloseGuardDelegate?

        func applyWindowState() {
            window?.title = title
            window?.titlebarSeparatorStyle = .none
            window?.standardWindowButton(.closeButton)?.isEnabled = !isOperating
            installProxyIfNeeded()
        }
        private func installProxyIfNeeded() {
            guard let window else { return }
            if window.delegate === proxy { return }
            let proxy = CloseGuardDelegate(original: window.delegate, shouldClose: { [weak self] in
                guard let self else { return true }
                let accepted = self.shouldClose()
                if !accepted { NSSound.beep() }
                return accepted
            }, didClose: { [weak self] in self?.didClose() })
            self.proxy = proxy
            window.delegate = proxy
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyWindowState() }
    }
}

private final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let shouldCloseHandler: () -> Bool
    private let didCloseHandler: () -> Void
    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool, didClose: @escaping () -> Void) {
        self.original = original; shouldCloseHandler = shouldClose; didCloseHandler = didClose
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldCloseHandler() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
    func windowWillClose(_ notification: Notification) { didCloseHandler(); original?.windowWillClose?(notification) }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private final class WeakWorkspace {
        weak var value: WorkspaceModel?
        init(_ value: WorkspaceModel) { self.value = value }
    }
    private var workspaces: [ObjectIdentifier: WeakWorkspace] = [:]

    func register(_ workspace: WorkspaceModel) {
        purgeClosedWorkspaces(); workspaces[ObjectIdentifier(workspace)] = WeakWorkspace(workspace)
    }
    func unregister(_ workspace: WorkspaceModel) { workspaces.removeValue(forKey: ObjectIdentifier(workspace)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "RepHub", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL), icon.isValid { NSApplication.shared.applicationIconImage = icon }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = activeWorkspaces.filter(\.isOperating)
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仓库操作尚未结束"
        alert.informativeText = "请等待操作和状态核对完成后退出。取消操作不会回滚已经更新的文件。"
        alert.addButton(withTitle: "等待完成"); alert.addButton(withTitle: "取消操作")
        if alert.runModal() == .alertSecondButtonReturn { running.forEach { $0.cancelOperation() } }
        return .terminateCancel
    }
    private var activeWorkspaces: [WorkspaceModel] {
        purgeClosedWorkspaces(); return workspaces.values.compactMap(\.value)
    }
    private func purgeClosedWorkspaces() { workspaces = workspaces.filter { $0.value.value != nil } }
}
