import SwiftUI
import RepositoryApplication
import DesignSystem

/// 菜单和工作区顶部使用同一份最近记录，不引入全局仓库侧栏。
public struct RecentRepositoriesMenu: View {
    @Bindable private var model: WorkspaceModel
    private let onOpenInNewWindow: ((URL) -> Void)?

    public init(model: WorkspaceModel, onOpenInNewWindow: ((URL) -> Void)? = nil) {
        self.model = model
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        Menu("最近打开") {
            if model.recentRepositories.entries.isEmpty {
                Text("暂无最近打开的仓库")
            } else {
                ForEach(model.recentRepositories.entries) { repository in
                    Button("\(repository.name) — \(repository.displayPath)") {
                        model.openRecentRepository(repository)
                    }
                    .help(repository.path)
                }
                if let onOpenInNewWindow {
                    Menu("在新窗口打开") {
                        ForEach(model.recentRepositories.entries) { repository in
                            Button("\(repository.name) — \(repository.displayPath)") {
                                onOpenInNewWindow(URL(fileURLWithPath: repository.path))
                            }
                            .help(repository.path)
                        }
                    }
                }
                Divider()
                Button("清空最近记录", action: model.recentRepositories.clear)
            }
        }
        .disabled(model.isInteractionLocked)
    }
}

struct RecentRepositoriesView: View {
    @Bindable var store: RecentRepositoryStore
    let palette: AppPalette
    let open: (RecentRepository) -> Void
    var maximumHeight: CGFloat = 264
    var openInNewWindow: ((URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近打开").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("清空记录", action: store.clear)
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .help("仅清空列表，不删除本地文件夹")
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.entries) { repository in
                        RecentRepositoryRow(repository: repository, palette: palette,
                                            open: { open(repository) }, remove: { store.remove(repository) },
                                            openInNewWindow: openInNewWindow.map { action in
                                                { action(URL(fileURLWithPath: repository.path)) }
                                            })
                    }
                }
            }
            .frame(height: min(maximumHeight, max(0, CGFloat(store.entries.count) * 60 - 4)))
        }
    }
}

private struct RecentRepositoryRow: View {
    let repository: RecentRepository
    let palette: AppPalette
    let open: () -> Void
    let remove: () -> Void
    let openInNewWindow: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 11) {
                    Image(systemName: "folder")
                        .font(.system(size: 16)).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(repository.name).font(.system(size: 13, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(repository.providerNames.joined(separator: " · "))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.accent)
                                .lineLimit(1).fixedSize()
                        }
                        Text(repository.displayPath).font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(repository.name)，\(repository.displayPath)")
            .help(repository.path)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                .foregroundStyle(palette.secondaryText)
                .padding(.trailing, 5)
                .accessibilityLabel("移除 \(repository.name) 的最近记录")
                .help("从最近记录中移除，不删除文件夹")
        }
        .background(isHovering ? palette.selection.opacity(0.65) : palette.sidebar.opacity(0.48),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开仓库", action: open)
            if let openInNewWindow { Button("在新窗口打开", action: openInNewWindow) }
            Divider()
            Button("从最近记录中移除", action: remove)
        }
    }
}
