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
    @State private var workspace: WorkspaceModel
    private let connections: RepositoryConnectionSettings

    init() {
        let connections = RepositoryConnectionSettings()
        self.connections = connections
        _workspace = State(initialValue: WorkspaceModel(service: RepositoryService(providers: [
            GitProvider(),
            SVNProvider(tlsMode: { await connections.mode(for: $0) })
        ])))
    }

    var body: some Scene {
        Window("RepHub", id: "workspace") {
            WorkspaceView(model: workspace, appearance: appearance)
                .frame(minWidth: 1080, minHeight: 700)
                .background(WindowSurface())
        }
        .defaultSize(width: 1440, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开本地文件夹…", action: workspace.chooseFolder)
                    .keyboardShortcut("o")
            }
            CommandMenu("项目") {
                Button("打开仓库…", action: workspace.chooseFolder)
                Divider()
                Button("刷新仓库", action: workspace.refresh)
                    .keyboardShortcut("r")
                    .disabled(workspace.workspace == nil || workspace.isLoading)
            }
        }

        Settings {
            TabView {
                ThemeSettingsView(appearance: appearance)
                    .tabItem { Label("外观", systemImage: "paintpalette") }
                RepositoryConnectionSettingsView(settings: connections, onChange: workspace.refresh)
                    .tabItem { Label("SVN 连接", systemImage: "network") }
            }
            .preferredColorScheme(appearance.preferredColorScheme)
            .frame(width: 610, height: 500)
        }
    }
}

/// 仅对本工作台隐藏系统标题栏分隔线，保留原生工具栏及窗口行为。
private struct WindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceView { SurfaceView(frame: .zero) }
    func updateNSView(_ nsView: SurfaceView, context: Context) {
        nsView.window?.titlebarSeparatorStyle = .none
    }

    final class SurfaceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
