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
    @State private var migrationResultToOpen: URL?
    @FocusState private var commitMessageFocused: Bool

    public init(model: WorkspaceModel, appearance: AppearanceStore) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        let palette = appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
        let codePalette = appearance.codePalette(for: appearance.preferredColorScheme ?? systemColorScheme)
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
        .sheet(isPresented: $model.showsRepositoryManagement, onDismiss: model.repositoryManagement.dismiss) {
            RepositoryManagementView(model: model.repositoryManagement, palette: palette, appearance: appearance, dismiss: {
                model.repositoryManagement.dismiss()
                model.showsRepositoryManagement = false
            }, completed: { response in
                model.applyManagementResponse(response)
            })
        }
        .sheet(isPresented: $model.showsRepositorySetup, onDismiss: model.repositorySetup.dismiss) {
            RepositorySetupView(model: model.repositorySetup, palette: palette, dismiss: {
                model.repositorySetup.dismiss()
                model.showsRepositorySetup = false
            }, completed: { result in
                guard result.outcome == .succeeded else { return }
                model.repositorySetup.dismiss()
                model.showsRepositorySetup = false
                model.open(result.directory)
            })
        }
        .sheet(isPresented: $model.showsRepositoryMigration, onDismiss: {
            model.repositoryMigration?.dismiss()
            model.workingCopyMigration?.dismiss()
            if let directory = migrationResultToOpen {
                migrationResultToOpen = nil
                model.open(directory)
            } else {
                model.refresh()
            }
        }) {
            if let migration = model.repositoryMigration {
                RepositoryMigrationView(model: migration, workingCopyModel: model.workingCopyMigration, palette: palette, dismiss: {
                    migration.dismiss()
                    model.workingCopyMigration?.dismiss()
                    model.showsRepositoryMigration = false
                }, openResult: { result in
                    migrationResultToOpen = result
                    migration.dismiss()
                    model.workingCopyMigration?.dismiss()
                    model.showsRepositoryMigration = false
                })
            }
        }
        .sheet(isPresented: $model.showsAIReview) {
            if let ai = model.aiReview {
                AIRunView(model: ai, palette: palette, codePalette: codePalette, dismiss: { model.showsAIReview = false })
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
        let initialHistoryHeight = min(290, max(210, size.height * 0.32))
        return Group {
            if historyExpanded {
                SoftVerticalSplit(fixedSide: .bottom, initialHeight: initialHistoryHeight, minimumFixed: 120, flexibleMinimum: 180,
                    storageKey: "workspace.history") {
                    workingCopyEditor(palette: palette, showsBindingPicker: false)
                        .padding(.bottom, inset / 2)
                } bottom: {
                    HistoryWorkspaceView(model: model, appearance: appearance, showAsMainView: false)
                        .padding(.top, inset / 2)
                }
            } else {
                workingCopyEditor(palette: palette, showsBindingPicker: true)
            }
        }
        .padding(inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func workingCopyEditor(palette: AppPalette, showsBindingPicker: Bool) -> some View {
        SoftHorizontalSplit(initialWidth: 240, minimumFixed: 110, flexibleMinimum: 200,
            storageKey: "workspace.files") {
            WorkspaceFileTreeView(model: model, palette: palette, showsBindingPicker: showsBindingPicker)
        } trailing: {
            VStack(spacing: 0) {
                DiffView(model: model, appearance: appearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                commitBar(palette: palette)
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ToolbarContentBuilder private func toolbar(palette: AppPalette) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Menu {
                    Button("打开仓库…", action: model.showRepositoryAcquisition)
                    RecentRepositoriesMenu(model: model)
                    if let workspace = model.workspace {
                        Divider()
                        if workspace.isUnmanaged {
                            Button("初始化版本控制…", action: model.prepareSetup)
                        } else {
                            Button("管理当前仓库…", action: model.prepareManagement)
                            if model.repositoryMigration != nil {
                                Button("迁移仓库…", action: model.showRepositoryMigration)
                            }
                            Button("关联本地工作副本…", action: model.chooseLinkedFolder)
                            if !workspace.linkedDirectories.isEmpty {
                                Menu("已关联的工作副本") {
                                    ForEach(workspace.linkedDirectories, id: \.self) { directory in
                                        Button("移除 \(directory.lastPathComponent)") { model.removeLinkedDirectory(directory) }
                                    }
                                }
                            }
                        }
                        if let monitor = model.monitor {
                            Menu("本地监控") {
                                Picker("检查间隔", selection: Binding(get: { monitor.intervalSeconds }, set: { monitor.intervalSeconds = $0 })) {
                                    Text("关闭").tag(0)
                                    Text("每 15 秒").tag(15)
                                    Text("每 30 秒").tag(30)
                                    Text("每分钟").tag(60)
                                }
                                Divider()
                                if monitor.isChecking {
                                    Label("正在检查本地变更…", systemImage: "arrow.triangle.2.circlepath")
                                } else if let lastCheckedAt = monitor.lastCheckedAt {
                                    Text("上次检查：\(lastCheckedAt.formatted(date: .omitted, time: .shortened))")
                                } else {
                                    Text("尚未完成检查")
                                }
                                if let error = monitor.errorMessage {
                                    Label("最近一次检查失败", systemImage: "exclamationmark.circle")
                                        .help(error)
                                }
                                Button(monitor.isChecking ? "正在检查…" : "立即检查", action: monitor.checkNow)
                                    .disabled(monitor.isChecking)
                            }
                        }
                        Divider()
                        Button("关闭工作区", action: model.closeWorkspace)
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
                Button { model.prepareManagement() } label: {
                    Label("管理仓库", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                .accessibilityLabel("管理仓库")
                .disabled(model.selectedBinding == nil || model.isInteractionLocked)
                .help("推送、分支、暂存、冲突与版本比较")
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
            commitTargetSelector
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

    @ViewBuilder private var commitTargetSelector: some View {
        let bindings = model.workspace?.bindings ?? []
        if Set(bindings.map(\.root)).count > 1 || bindings.count > 2 {
            Menu {
                ForEach(bindings) { binding in
                    Toggle(binding.displayLabel, isOn: Binding(
                        get: { commitTargets.contains(binding.id) },
                        set: { selected in if selected { commitTargets.insert(binding.id) } else { commitTargets.remove(binding.id) } }
                    ))
                    .help(binding.root.path)
                }
            } label: {
                Label("提交目标 \(commitTargets.count)", systemImage: "checklist")
            }
            .buttonStyle(WorkbenchButtonStyle(palette: paletteForCommitBar, role: .quiet))
            .help("选择要提交的版本控制来源")
        } else {
            ForEach(bindings) { binding in
                Toggle(binding.displayLabel, isOn: Binding(
                    get: { commitTargets.contains(binding.id) },
                    set: { selected in if selected { commitTargets.insert(binding.id) } else { commitTargets.remove(binding.id) } }
                )).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize().help(binding.root.path)
            }
        }
    }

    private var paletteForCommitBar: AppPalette {
        appearance.palette(for: appearance.preferredColorScheme ?? systemColorScheme)
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
                Text("\(model.historyRevisions.count) 条历史")
            }
            if model.isOperationInProgress { Text("操作进行中").padding(.leading, 8) }
            if let monitor = model.monitor, !monitor.pendingBindingIDs.isEmpty {
                Button("检测到 \(monitor.pendingBindingIDs.count) 个来源变化") { model.refreshMonitoredChanges() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .disabled(model.isInteractionLocked)
            }
            if let message = model.monitor?.errorMessage {
                Label("本地监控读取失败", systemImage: "exclamationmark.circle")
                    .help(message).accessibilityValue(message)
            }
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
            (model.workspace?.isUnmanaged == true ? "未识别到 Git 或 Subversion 工作副本。可以初始化一种版本控制方式。" : "从「项目」菜单打开仓库，或继续最近的工作。"))
        return VStack(spacing: 24) {
            ContentUnavailableView {
                Label(model.workspace?.isUnmanaged == true ? "此目录尚未受版本控制" : "打开一个工作区", systemImage: "folder")
            } description: {
                Text(description)
            } actions: {
                HStack(spacing: 10) {
                    Button("打开仓库…", action: model.showRepositoryAcquisition).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary))
                    if model.workspace?.isUnmanaged == true {
                        Button("初始化版本控制…", action: model.prepareSetup).buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
                    }
                }
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
