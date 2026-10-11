import SwiftUI
import Observation
import DesignSystem
import VersionControlCore

public struct WorkspaceView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: WorkspaceSection = .workingCopy
    @State private var historyExpanded = false
    @State private var showsCommitDrawer = false

    public init(model: WorkspaceModel, appearance: AppearanceStore) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        let palette = appearance.palette(for: effectiveColorScheme)
        Group {
            if model.workspace == nil {
                EmptyWorkspaceView(open: model.chooseFolder, palette: palette, errorMessage: model.errorMessage)
            } else if model.workspace?.isUnmanaged == true {
                UnmanagedWorkspaceView(open: model.chooseFolder, palette: palette)
            } else {
                workspaceContent(palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .tint(palette.accent)
        .preferredColorScheme(appearance.preferredColorScheme)
        .toolbar { workspaceToolbar(palette: palette) }
        .onChange(of: section) { _, newSection in
            if newSection == .history {
                model.selectRevision(model.snapshot?.revisions.first(where: { $0.id == model.selectedRevisionID }) ?? model.snapshot?.revisions.first)
            } else if model.selectedRevisionID != nil {
                model.selectChange(model.snapshot?.changes.first)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: section)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: historyExpanded)
    }

    private var effectiveColorScheme: ColorScheme {
        appearance.preferredColorScheme ?? systemColorScheme
    }

    @ViewBuilder
    private func workspaceContent(palette: AppPalette) -> some View {
        if section == .history {
            HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: true)
        } else {
            VSplitView {
                HSplitView {
                    ChangeListView(model: model, palette: palette)
                        .frame(minWidth: 230, idealWidth: 285, maxWidth: 320)
                    DiffView(model: model, appearance: appearance)
                        .frame(minWidth: 460)
                }
                if historyExpanded {
                    HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: false)
                        .frame(minHeight: 230, idealHeight: 310)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showsCommitDrawer {
                    CommitDrawer(workspace: model.workspace, palette: palette, dismiss: { showsCommitDrawer = false })
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func workspaceToolbar(palette: AppPalette) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: model.chooseFolder) {
                Label("打开仓库", systemImage: "folder.badge.plus")
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("视图", selection: $section) {
                ForEach(WorkspaceSection.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 188)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button(action: model.refresh) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.selectedBinding == nil || model.isLoading)
            if section == .workingCopy {
                Button(action: { historyExpanded.toggle() }) {
                    Label(historyExpanded ? "收起历史" : "显示历史", systemImage: "clock.arrow.circlepath")
                }
                Button(action: { showsCommitDrawer.toggle() }) {
                    Label("提交", systemImage: "checkmark.circle")
                }
                .disabled(model.workspace?.bindings.isEmpty ?? true)
            }
        }
    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case workingCopy, history
    var id: Self { self }
    var title: String { self == .workingCopy ? "工作区" : "历史" }
    var symbol: String { self == .workingCopy ? "rectangle.split.3x1" : "point.3.connected.trianglepath.dotted" }
}

private struct EmptyWorkspaceView: View {
    let open: () -> Void
    let palette: AppPalette
    let errorMessage: String?

    var body: some View {
        ContentUnavailableView {
            Label("打开一个工作区", systemImage: "folder")
        } description: {
            Text(errorMessage ?? "选择已有 Git 或 Subversion 工作目录。")
        } actions: {
            Button("选择文件夹", action: open).buttonStyle(.borderedProminent)
        }
        .foregroundStyle(palette.text)
    }
}

private struct UnmanagedWorkspaceView: View {
    let open: () -> Void
    let palette: AppPalette
    var body: some View {
        ContentUnavailableView {
            Label("此目录尚未受版本控制", systemImage: "questionmark.folder")
        } description: {
            Text("未识别到 Git 或 Subversion 工作副本。创建 Git 或接入 Subversion 的功能当前不可用；选择初始化时只能选一种方式。")
        } actions: {
            Button("选择其他文件夹", action: open).buttonStyle(.bordered)
        }
        .foregroundStyle(palette.text)
    }
}

private struct ChangeListView: View {
    @Bindable var model: WorkspaceModel
    let palette: AppPalette

    var body: some View {
        VStack(spacing: 0) {
            bindingPicker
            Divider()
            if let snapshot = model.snapshot {
                List(selection: Binding(
                    get: { model.selectedPath },
                    set: { path in model.selectChange(snapshot.changes.first(where: { $0.path == path })) }
                )) {
                    Section("变更 · \(snapshot.changes.count)") {
                        ForEach(snapshot.changes) { change in
                            ChangeRow(change: change, palette: palette)
                                .tag(Optional(change.path))
                                .contentShape(Rectangle())
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else if model.isLoading {
                ProgressView("正在读取状态…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("暂无变更", systemImage: "checkmark.circle")
            }
            if let error = model.errorMessage {
                ErrorStrip(message: error, palette: palette)
            }
        }
        .background(palette.sidebar)
    }

    private var bindingPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let workspace = model.workspace {
                Text(workspace.directory.lastPathComponent).font(.headline).lineLimit(1)
                Picker("版本控制", selection: Binding(
                    get: { model.selectedBindingID },
                    set: { identifier in
                        guard let identifier,
                              let binding = workspace.bindings.first(where: { $0.id == identifier }) else { return }
                        model.selectBinding(binding)
                    }
                )) {
                    ForEach(workspace.bindings) { binding in
                        Text(bindingLabel(binding)).tag(Optional(binding.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        .padding(12)
    }

    private func bindingLabel(_ binding: RepositoryBinding) -> String {
        binding.currentBranch.isEmpty ? binding.providerName : "\(binding.providerName) · \(binding.currentBranch)"
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let palette: AppPalette
    var body: some View {
        HStack(spacing: 8) {
            Text(change.kind.symbol)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(changeColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.name).lineLimit(1)
                Text(change.path).font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if change.isStaged { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent).imageScale(.small) }
        }
        .accessibilityLabel("\(change.kind.symbol) \(change.path)")
    }
    private var changeColor: Color {
        switch change.kind { case .added, .copied: palette.added; case .deleted: palette.removed; default: palette.accent }
    }
}
