import SwiftUI
import Observation
import DesignSystem
import VersionControlCore

public struct WorkspaceView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var section: WorkspaceSection = .workingCopy
    @State private var historyExpanded = true
    @State private var commitMessage = ""
    @State private var commitTargets: Set<String> = []

    public init(model: WorkspaceModel, appearance: AppearanceStore) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.workspace == nil || model.workspace?.isUnmanaged == true {
                    welcome(palette: palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == .history {
                    HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: true)
                        .frame(width: geometry.size.width, height: max(0, geometry.size.height - 28))
                } else {
                    workingCopy(size: CGSize(width: geometry.size.width, height: max(0, geometry.size.height - 28)), palette: palette)
                }
                statusBar(palette: palette)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(palette.background)
        }
        .tint(palette.accent)
        .foregroundStyle(palette.text)
        .preferredColorScheme(appearance.preferredColorScheme)
        .toolbar { toolbar(palette: palette) }
        .toolbar(removing: .title)
        .onChange(of: section) { _, value in
            if value == .history {
                model.selectRevision(model.snapshot?.revisions.first(where: { $0.id == model.selectedRevisionID }) ?? model.snapshot?.revisions.first)
            } else if model.selectedRevisionID != nil {
                model.selectChange(model.snapshot?.changes.first)
            }
        }
        .onChange(of: model.workspace?.id) { _, _ in
            commitTargets = Set(model.workspace?.bindings.map(\.id) ?? [])
            commitMessage = ""
        }
    }

    private func workingCopy(size: CGSize, palette: AppPalette) -> some View {
        let inset: CGFloat = 8
        let historyHeight = historyExpanded ? min(290, max(210, size.height * 0.32)) : 0
        let editorHeight = max(0, size.height - inset * 2 - (historyExpanded ? historyHeight + inset : 0))
        let sidebarWidth = min(290, max(210, (size.width - inset * 2) * 0.22))
        return VStack(spacing: inset) {
            HStack(spacing: 0) {
                ChangeTreeView(model: model, palette: palette)
                    .frame(width: sidebarWidth, height: editorHeight, alignment: .topLeading)
                Rectangle().fill(palette.border.opacity(0.55)).frame(width: 1)
                VStack(spacing: 0) {
                    DiffView(model: model, appearance: appearance)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    commitBar(palette: palette)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: editorHeight)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.border.opacity(0.55), lineWidth: 0.5))
            if historyExpanded {
                HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: false)
                    .frame(height: historyHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.border.opacity(0.55), lineWidth: 0.5))
            }
        }
        .padding(inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ToolbarContentBuilder private func toolbar(palette: AppPalette) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Menu {
                    Button("打开本地文件夹…", action: model.chooseFolder)
                    if let workspace = model.workspace {
                        Divider()
                        Text(workspace.directory.path)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "externaldrive").font(.system(size: 14))
                        Text(model.workspace?.name ?? "RepHub").font(.system(size: 13, weight: .semibold))
                    }
                    .frame(height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .help("打开或切换仓库")
                if let binding = model.selectedBinding {
                    Rectangle().fill(palette.border).frame(width: 1, height: 16)
                    Label(binding.currentBranch.isEmpty ? binding.providerName : binding.currentBranch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(palette.secondaryText)
                        .help("当前工作副本分支")
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            WorkbenchSegmentedPicker(title: "视图", selection: $section,
                options: [.init(.workingCopy, "工作区"), .init(.history, "提交历史")], palette: palette)
                .frame(width: 200)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel("刷新")
                    .disabled(model.selectedBinding == nil || model.isLoading).help("刷新仓库 · ⌘R")
                if section == .workingCopy {
                    Button { historyExpanded.toggle() } label: {
                        Label(historyExpanded ? "收起历史" : "显示历史", systemImage: "rectangle.bottomthird.inset.filled").labelStyle(.iconOnly)
                    }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel(historyExpanded ? "收起历史" : "显示历史")
                    .help(historyExpanded ? "收起底部提交历史" : "显示底部提交历史")
                }
                Button {} label: { Label("AI 审查", systemImage: "sparkles").labelStyle(.titleAndIcon) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel("AI 审查")
                    .disabled(true).help("AI 审查尚未接入")
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func commitBar(palette: AppPalette) -> some View {
        HStack(spacing: 12) {
            TextField("提交说明…", text: $commitMessage)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 11).frame(height: 30)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.border.opacity(0.65)))
            ForEach(model.workspace?.bindings ?? []) { binding in
                Toggle(binding.providerName == "Subversion" ? "SVN" : binding.providerName, isOn: Binding(
                    get: { commitTargets.contains(binding.id) },
                    set: { if $0 { commitTargets.insert(binding.id) } else { commitTargets.remove(binding.id) } }
                )).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
            }
            Button {} label: { Label("AI 生成", systemImage: "sparkles") }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet)).disabled(true).help("AI 生成提交说明尚未接入")
            Button("提交") {}.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                .disabled(true).help("当前为读取版本，实际提交尚未接入")
        }
        .padding(.horizontal, 12).frame(height: 56)
        .background(palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(palette.border.opacity(0.55)).frame(height: 0.5) }
    }

    private func statusBar(palette: AppPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
            Text(model.errorMessage ?? (model.isLoading ? "正在读取仓库…" : "就绪"))
                .lineLimit(1).help(model.errorMessage ?? "")
            Spacer()
            if let snapshot = model.snapshot {
                Text("\(snapshot.changes.count) 个变更")
                Text("·")
                Text("\(snapshot.revisions.count) 条历史")
            }
            Text("只读预览").padding(.leading, 8)
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 14).frame(height: 28)
        .overlay(alignment: .top) { Rectangle().fill(palette.border.opacity(0.5)).frame(height: 0.5) }
    }

    private func welcome(palette: AppPalette) -> some View {
        ContentUnavailableView {
            Label(model.workspace?.isUnmanaged == true ? "此目录尚未受版本控制" : "打开一个工作区", systemImage: "folder")
        } description: {
            Text(model.errorMessage ?? (model.workspace?.isUnmanaged == true ? "未识别到 Git 或 Subversion 工作副本。初始化功能尚未接入。" : "从「项目」菜单打开本地 Git 或 Subversion 仓库。"))
        } actions: {
            Button("打开本地文件夹…", action: model.chooseFolder).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
        }
    }
}

private enum WorkspaceSection: Hashable { case workingCopy, history }

private struct ChangeTreeView: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette
    @State private var filter = ""
    @State private var collapsed: Set<String> = []

    private var changes: [FileChange] {
        (model.snapshot?.changes ?? []).filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("变更文件").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.snapshot?.changes.count ?? 0)").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }.padding(.horizontal, 14).frame(height: 39)
            WorkbenchSearchField("筛选文件…", text: $filter, palette: palette)
            .padding(.horizontal, 10).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        Image(systemName: "folder.fill").foregroundStyle(palette.accent)
                        Text(model.workspace?.name ?? "工作区").fontWeight(.medium)
                    }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
                    ForEach(treeRows) { row in
                        Button {
                            if let change = row.change { model.selectChange(change) }
                            else if collapsed.contains(row.id) { collapsed.remove(row.id) }
                            else { collapsed.insert(row.id) }
                        } label: {
                            HStack(spacing: 7) {
                                if row.change == nil {
                                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 9)
                                } else { Color.clear.frame(width: 9, height: 1) }
                                Image(systemName: row.change == nil ? "folder" : fileIcon(row.title)).foregroundStyle(row.change == nil ? palette.accent : palette.secondaryText).frame(width: 16)
                                Text(row.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 1)
                                if let change = row.change {
                                    Text(change.kind.symbol).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(change.kind == .deleted ? palette.removed : palette.accent)
                                }
                            }
                            .font(.system(size: 12))
                            .padding(.leading, 9 + CGFloat(row.depth) * 13).padding(.trailing, 9)
                            .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(row.change != nil && row.change?.path == model.selectedPath ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).help(row.id)
                        .accessibilityLabel(row.change?.path ?? row.id)
                    }
                    if changes.isEmpty && !model.isLoading {
                        Text(filter.isEmpty ? "工作区没有变更" : "没有匹配的文件")
                            .font(.system(size: 12)).foregroundStyle(palette.secondaryText).padding(16)
                    }
                }.padding(.horizontal, 6).padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let issues = model.snapshot?.issues, !issues.isEmpty {
                ErrorStrip(message: issues.joined(separator: "\n"), palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar.opacity(0.38))
    }

    private var treeRows: [ChangeTreeRow] {
        var result: [ChangeTreeRow] = []
        func collect(_ files: [FileChange], prefix: String, depth: Int) {
            let groups = Dictionary(grouping: files) { file in
                String(file.path.dropFirst(prefix.count).split(separator: "/").first ?? "")
            }
            for name in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                guard let members = groups[name] else { continue }
                let fullPath = prefix + name
                if members.count == 1, members[0].path == fullPath {
                    result.append(ChangeTreeRow(id: fullPath, title: name, depth: depth, change: members[0]))
                } else {
                    result.append(ChangeTreeRow(id: fullPath, title: name, depth: depth, change: nil))
                    if !collapsed.contains(fullPath) { collect(members, prefix: fullPath + "/", depth: depth + 1) }
                }
            }
        }
        collect(changes, prefix: "", depth: 1)
        return result
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "java", "kt", "js", "ts", "py", "go", "rs": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg": "photo"
        case "yml", "yaml", "json", "xml", "toml": "doc.badge.gearshape"
        default: "doc.text"
        }
    }
}

private struct ChangeTreeRow: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let change: FileChange?
}
