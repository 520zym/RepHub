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
    @State private var showsOperationSheet = false
    @State private var showsCommitSheet = false
    @FocusState private var commitMessageFocused: Bool

    public init(model: WorkspaceModel, appearance: AppearanceStore) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.workspace == nil || model.workspace?.bindings.isEmpty == true {
                    welcome(palette: palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == .history {
                    HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: true)
                        .frame(width: geometry.size.width, height: max(0, geometry.size.height - 28))
                        .allowsHitTesting(!model.isInteractionLocked)
                } else {
                    workingCopy(size: CGSize(width: geometry.size.width, height: max(0, geometry.size.height - 28)), palette: palette)
                        .allowsHitTesting(!model.isInteractionLocked)
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
            model.setHistoryVisible(value == .history)
        }
        .onChange(of: model.workspace?.id) { _, _ in
            commitTargets = Set(model.workspace?.bindings.map(\.id) ?? [])
            commitMessage = ""
        }
        .onChange(of: model.historyPresentationRequest) { _, _ in
            section = .history
            model.setHistoryVisible(true)
        }
        .sheet(isPresented: $showsOperationSheet, onDismiss: model.dismissOperationResult) {
            RepositoryOperationView(model: model, palette: palette) {
                model.dismissOperationResult()
                showsOperationSheet = false
            }
            .interactiveDismissDisabled(model.isOperationInProgress)
        }
        .sheet(isPresented: $showsCommitSheet, onDismiss: {
            if !model.repositoryCommit.isBusy { model.repositoryCommit.dismiss() }
        }) {
            RepositoryCommitView(
                model: model.repositoryCommit,
                palette: palette,
                appearance: appearance,
                workspace: model.workspace,
                dismiss: {
                    guard !model.repositoryCommit.isBusy else { return }
                    model.repositoryCommit.dismiss()
                    showsCommitSheet = false
                },
                committed: model.applyCommitResponse,
                viewHistory: { bindingID, revisionID in
                    model.repositoryCommit.dismiss()
                    showsCommitSheet = false
                    model.showCommittedRevision(bindingID: bindingID, revisionID: revisionID)
                }
            )
        }
        .sheet(isPresented: $model.showsRepositoryAcquisition) {
            RepositoryAcquisitionView(
                model: model.repositoryAcquisition,
                palette: palette,
                dismiss: model.dismissRepositoryAcquisition,
                openLocalFolder: model.chooseFolder,
                openAcquiredFolder: model.open,
                recentRepositories: model.recentRepositories,
                openRecentRepository: model.openRecentRepository
            )
        }
        .sheet(isPresented: $model.showsAIReview) {
            if let ai = model.aiReview {
                AIRunView(model: ai, palette: palette, dismiss: { model.showsAIReview = false })
            }
        }
        .alert("无法打开仓库", isPresented: Binding(
            get: { model.recentRepositoryError != nil },
            set: { if !$0 { model.recentRepositoryError = nil } }
        )) {
            Button("好", role: .cancel) { model.recentRepositoryError = nil }
        } message: {
            Text(model.recentRepositoryError ?? "")
        }
    }

    private func workingCopy(size: CGSize, palette: AppPalette) -> some View {
        let inset: CGFloat = 8
        let historyHeight = historyExpanded ? min(290, max(210, size.height * 0.32)) : 0
        let editorHeight = max(0, size.height - inset * 2 - (historyExpanded ? historyHeight + inset : 0))
        let sidebarWidth = min(290, max(210, (size.width - inset * 2) * 0.22))
        return VStack(spacing: inset) {
            HStack(spacing: 0) {
                WorkspaceFileTreeView(model: model, palette: palette, showsBindingPicker: !historyExpanded)
                    .frame(width: sidebarWidth, height: editorHeight, alignment: .topLeading)
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
            if historyExpanded {
                HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: false)
                    .frame(height: historyHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ToolbarContentBuilder private func toolbar(palette: AppPalette) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Menu {
                    Button("打开仓库…", action: model.showRepositoryAcquisition)
                    RecentRepositoriesMenu(model: model)
                    if let workspace = model.workspace {
                        Divider()
                        Text(workspace.directory.path)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "externaldrive").font(.system(size: 14))
                        Text(model.workspace?.name ?? "RepHub").font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 190)
                    }
                    .frame(height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .help("打开或切换仓库")
                .disabled(model.isInteractionLocked)
                if let binding = model.selectedBinding {
                    Label(binding.currentBranch.isEmpty ? binding.providerName : binding.currentBranch,
                          systemImage: binding.capabilities.contains(.branches) ? "arrow.triangle.branch" : "externaldrive")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12)).lineLimit(1)
                        .truncationMode(.middle).frame(maxWidth: 170)
                        .foregroundStyle(palette.secondaryText)
                        .help(binding.currentBranch.isEmpty ? binding.providerName : binding.currentBranch)
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            WorkbenchSegmentedPicker(title: "视图", selection: $section,
                options: [.init(.workingCopy, "工作区"), .init(.history, "提交历史")], palette: palette)
                .frame(width: 200)
                .disabled(model.isInteractionLocked)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel("刷新")
                    .disabled(model.selectedBinding == nil || model.isLoading || model.isInteractionLocked).help("刷新仓库 · ⌘R")
                Button { showsOperationSheet = true } label: {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath").labelStyle(.titleAndIcon)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                .accessibilityLabel("更新工作区")
                .disabled(model.workspace?.bindings.contains(where: { model.supports(.fetch, for: $0) || model.supports(.update, for: $0) }) != true || model.isInteractionLocked)
                .help("获取远端或更新一个版本控制来源")
                if section == .workingCopy {
                    Button { historyExpanded.toggle() } label: {
                        Label(historyExpanded ? "收起历史" : "显示历史", systemImage: "rectangle.bottomthird.inset.filled").labelStyle(.iconOnly)
                    }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel(historyExpanded ? "收起历史" : "显示历史")
                    .help(historyExpanded ? "收起底部提交历史" : "显示底部提交历史")
                    .disabled(model.isInteractionLocked)
                }
                Button { model.showAIReview(revision: section == .history ? model.selectedRevisionID : nil) } label: { Label("AI 审查", systemImage: "sparkles").labelStyle(.titleAndIcon) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                    .accessibilityLabel("AI 审查")
                    .disabled(model.aiReview == nil || model.selectedBinding == nil || model.isInteractionLocked || (section == .history && model.selectedRevisionID == nil))
                    .help("选择场景与文件，审查当前工作区或历史提交")
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func commitBar(palette: AppPalette) -> some View {
        HStack(spacing: 12) {
            TextField("提交说明…", text: $commitMessage)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($commitMessageFocused)
                .padding(.horizontal, 11).frame(height: 30)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if commitMessageFocused { RoundedRectangle(cornerRadius: 7).stroke(palette.accent.opacity(0.85), lineWidth: 1) }
                }
            ForEach(model.workspace?.bindings ?? []) { binding in
                Toggle(binding.providerName == "Subversion" ? "SVN" : binding.providerName, isOn: Binding(
                    get: { commitTargets.contains(binding.id) },
                    set: { if $0 { commitTargets.insert(binding.id) } else { commitTargets.remove(binding.id) } }
                )).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
            }
            Button {
                model.prepareCommit(initialTargets: commitTargets, initialMessage: commitMessage)
                showsCommitSheet = true
            } label: { Label("AI 生成", systemImage: "sparkles") }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                .disabled(model.repositoryCommit.ai == nil || model.isInteractionLocked || !hasCommitTarget)
                .help("先选择实际提交文件，再为每个目标生成说明")
            Button("提交") {
                model.prepareCommit(initialTargets: commitTargets, initialMessage: commitMessage)
                showsCommitSheet = true
            }
            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            .disabled(model.isInteractionLocked || !hasCommitTarget)
            .help(hasCommitTarget ? "选择提交文件并确认每个目标的说明" : "当前工作区没有支持提交的版本控制来源")
        }
        .padding(.horizontal, 12).frame(height: 56)
        .background(palette.sidebar.opacity(0.45))
        .background(palette.surface)
    }

    private var hasCommitTarget: Bool {
        (model.workspace?.bindings ?? []).contains { $0.capabilities.contains(.commit) }
    }

    private func statusBar(palette: AppPalette) -> some View {
        let issues = (model.workspace?.issues ?? []) + (model.snapshot?.issues ?? [])
        let hasError = model.errorMessage != nil || !issues.isEmpty
        let hasConflicts = model.snapshot?.changes.contains { $0.kind == .conflicted } == true
        return HStack(spacing: 8) {
            Image(systemName: hasError || hasConflicts ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(hasConflicts ? palette.removed : palette.secondaryText)
            Text(statusText(hasError: hasError))
                .lineLimit(1).help(model.errorMessage ?? issues.joined(separator: "\n"))
            Spacer()
            if let snapshot = model.snapshot {
                Text("\(snapshot.changes.count) 个变更")
                Text("·")
                Text("\(snapshot.revisions.count) 条历史")
            }
            if model.isOperationInProgress { Text("操作进行中").padding(.leading, 8) }
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 14).frame(height: 28)
        .background(palette.sidebar.opacity(0.25))
    }

    private func statusText(hasError: Bool) -> String {
        if model.repositoryCommit.isBusy { return model.repositoryCommit.phase == .committing ? "正在提交代码…" : "正在准备提交…" }
        if model.isOperationInProgress { return model.operationProgressMessage.isEmpty ? "正在执行版本控制操作…" : model.operationProgressMessage }
        if let result = model.operationResult { return result.summary }
        if model.isLoading { return "正在读取仓库…" }
        if model.errorMessage == nil, !hasError {
            let conflicts = model.snapshot?.changes.filter { $0.kind == .conflicted }.count ?? 0
            if conflicts > 0 { return "\(conflicts) 个冲突待处理" }
        }
        return model.errorMessage ?? (hasError ? "部分读取失败" : "就绪")
    }

    private func welcome(palette: AppPalette) -> some View {
        let issues = model.workspace?.issues ?? []
        let description = model.errorMessage ?? (!issues.isEmpty ? issues.joined(separator: "\n") :
            (model.workspace?.isUnmanaged == true ? "未识别到 Git 或 Subversion 工作副本。初始化功能尚未接入。" : "从「项目」菜单打开仓库，或继续最近的工作。"))
        return VStack(spacing: 24) {
            ContentUnavailableView {
                Label(model.workspace?.isUnmanaged == true ? "此目录尚未受版本控制" : "打开一个工作区", systemImage: "folder")
            } description: {
                Text(description)
            } actions: {
                Button("打开仓库…", action: model.showRepositoryAcquisition).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
            }
            .fixedSize(horizontal: false, vertical: true)
            if !model.recentRepositories.entries.isEmpty {
                RecentRepositoriesView(store: model.recentRepositories, palette: palette,
                                       open: model.openRecentRepository, maximumHeight: 236)
                    .frame(width: 560)
            }
        }
        .disabled(model.isInteractionLocked)
    }
}

private enum WorkspaceSection: Hashable { case workingCopy, history }

/// 已由 `WorkspaceFileTreeView` 取代；保留旧实现仅供后续移除时对照，当前界面不会使用。
