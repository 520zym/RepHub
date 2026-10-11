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
    @State private var workspace = WorkspaceModel(service: RepositoryService(providers: [GitProvider(), SVNProvider()]))

    var body: some Scene {
        Window("RepHub", id: "workspace") {
            WorkspaceView(model: workspace, appearance: appearance)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1380, height: 860)
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
            ThemeSettingsView(appearance: appearance)
                .preferredColorScheme(appearance.preferredColorScheme)
                .frame(width: 540, height: 470)
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
