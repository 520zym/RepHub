import SwiftUI
import Observation
import DesignSystem
import VersionControlCore

public struct WorkspaceView: View {
    @Bindable private var model: WorkspaceModel
    @Bindable private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var section: WorkspaceSection = .workingCopy
    @State private var showsCommitInspector = true
    @State private var commitSelection = WorkspaceCommitSelection()
    @State private var commitMessage = ""
    @State private var commitMessagesByBinding: [String: String] = [:]
    @State private var commitTargets: Set<String> = []
    @State private var showsOperationSheet = false
    @State private var showsCommitSheet = false
    @State private var startsCommitWithAI = false
    @State private var migrationResultToOpen: URL?
    @State private var conflictToOpen: String?

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
            commitTargets = Set(commitBindings.map(\.id))
            commitSelection = WorkspaceCommitSelection()
            commitMessage = ""
            commitMessagesByBinding = [:]
            model.fileBrowser.mode = .changes
            reconcileCommitSelection()
        }
        .onChange(of: commitSelectionSignature) { _, _ in reconcileCommitSelection() }
        .onChange(of: model.workingCopyPresentationRequest) { _, _ in
            section = .workingCopy
            model.setHistoryVisible(false)
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
            preserveCommitDraft()
            if !model.repositoryCommit.isBusy { model.repositoryCommit.dismiss() }
        }) {
            RepositoryCommitView(
                model: model.repositoryCommit,
                palette: palette,
                appearance: appearance,
                workspace: model.workspace,
                dismiss: {
                    guard !model.repositoryCommit.isBusy else { return }
                    preserveCommitDraft()
                    model.repositoryCommit.dismiss()
                    showsCommitSheet = false
                },
                committed: model.applyCommitResponse,
                viewHistory: { bindingID, revisionID in
                    preserveCommitDraft()
                    model.repositoryCommit.dismiss()
                    showsCommitSheet = false
                    model.showCommittedRevision(bindingID: bindingID, revisionID: revisionID)
                },
                startsWithAI: startsCommitWithAI
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
        .sheet(isPresented: $model.showsRepositoryManagement, onDismiss: {
            model.repositoryManagement.dismiss()
            if let path = conflictToOpen {
                conflictToOpen = nil
                model.showConflictEditor(path: path)
            }
        }) {
            RepositoryManagementView(model: model.repositoryManagement, palette: palette, appearance: appearance, dismiss: {
                model.repositoryManagement.dismiss()
                model.showsRepositoryManagement = false
            }, completed: { response in
                model.applyManagementResponse(response)
            }, editConflict: { path in
                conflictToOpen = path
                model.showsRepositoryManagement = false
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
                RepositoryMigrationView(model: migration, workingCopyModel: model.workingCopyMigration, startsInWorkingCopy: model.migrationStartsInWorkingCopy, palette: palette, dismiss: {
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
                AIRunView(model: ai, palette: palette, codePalette: codePalette, dismiss: { model.showsAIReview = false }, onLocateFinding: model.locateReviewFinding)
            }
        }
        .sheet(item: $model.toolRequest, onDismiss: { model.toolIsBusy = false }) { request in
            WorkspaceToolView(model: model, request: request, palette: palette, appearance: appearance)
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
        VStack(spacing: 10) {
            if !currentConflicts.isEmpty { conflictBanner(palette: palette) }
            workingCopyEditor(palette: palette)
        }
        .padding(10)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func workingCopyEditor(palette: AppPalette) -> some View {
        SoftHorizontalSplit(initialWidth: 280, minimumFixed: 120, flexibleMinimum: 360,
            storageKey: "workspace.current.files") {
            WorkspaceFileTreeView(model: model, palette: palette, showsBindingPicker: true,
                                  selectedChangePaths: selectedChangePaths)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .padding(.trailing, 5)
        } trailing: {
            if showsCommitInspector {
                SoftHorizontalSplit(fixedSide: .trailing, initialWidth: 292, minimumFixed: 170, flexibleMinimum: 280,
                                    storageKey: "workspace.current.commit") {
                    workingDiff.padding(.horizontal, 5)
                } trailing: {
                    WorkspaceCommitInspector(palette: palette, bindings: commitBindings,
                        message: unifiedCommitMessage, targets: Binding(get: { effectiveCommitTargets }, set: { commitTargets = $0 }), selectedCount: selectedCommitCount,
                        blockedReason: commitBlockedReason, aiAvailable: model.repositoryCommit.ai != nil,
                        isLocked: model.isInteractionLocked, collapse: { showsCommitInspector = false },
                        prepare: { prepareSelectedCommit() }, prepareAI: { prepareSelectedCommit(withAI: true) })
                        .clipShape(RoundedRectangle(cornerRadius: 9)).padding(.leading, 5)
                }
            } else {
                workingDiff.padding(.leading, 5)
            }
        }
    }

    private var workingDiff: some View {
        DiffView(model: model, appearance: appearance, focusLine: model.diffFocusLine, focusToken: model.diffFocusToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func conflictBanner(palette: AppPalette) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 19)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("当前工作区有 \(currentConflicts.count) 个冲突").font(.system(size: 13, weight: .semibold))
                Text("处理后可继续提交此来源的变更。").font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
            Button("解决冲突", action: resolveCurrentConflict)
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
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
                            Button("全历史搜索…", action: model.showFullHistorySearch)
                            Button("搁置与恢复改动…", action: model.showShelves)
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
                        if let monitor = model.migrationMonitor {
                            Menu("迁移源提醒") {
                                Button("立即检查源 SVN") { monitor.checkNow() }.disabled(monitor.isChecking)
                                Toggle("自动检查", isOn: Binding(get: { !monitor.isPaused }, set: { monitor.setPaused(!$0) }))
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
                    Label(model.selectedBinding?.capabilities.contains(.push) == true ? "拉取" : "更新", systemImage: "arrow.down.to.line").labelStyle(.titleAndIcon)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                .accessibilityLabel("更新工作区")
                .disabled(model.workspace?.bindings.contains(where: { model.supports(.fetch, for: $0) || model.supports(.update, for: $0) }) != true || model.isInteractionLocked)
                .help("获取远端或更新一个版本控制来源")
                if model.selectedBinding?.capabilities.contains(.push) == true {
                    Button(action: model.prepareManagement) { Label("推送", systemImage: "arrow.up.to.line") }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                        .disabled(model.isInteractionLocked)
                        .help("查看远端与目标分支，确认后推送")
                }
                Button { model.prepareManagement() } label: {
                    Label("管理仓库", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet))
                .accessibilityLabel("管理仓库")
                .disabled(model.selectedBinding == nil || model.isInteractionLocked)
                .help("推送、分支、暂存、冲突与版本比较")
                if section == .workingCopy && !showsCommitInspector {
                    Button { showsCommitInspector = true } label: {
                        Label("准备提交", systemImage: "sidebar.right")
                    }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
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

    private var commitBindings: [RepositoryBinding] {
        (model.workspace?.bindings ?? []).filter { $0.capabilities.contains(.commit) }
    }

    private var effectiveCommitTargets: Set<String> {
        if commitBindings.count == 1, let binding = commitBindings.first { return [binding.id] }
        return commitTargets
    }

    private var selectedChangePaths: Binding<Set<String>> {
        Binding(get: {
            guard let binding = model.selectedBinding else { return [] }
            return commitSelection.paths(in: binding)
        }, set: { paths in
            guard let binding = model.selectedBinding else { return }
            commitSelection.setPaths(paths, in: binding)
        })
    }

    /// 工作区右侧只有一份“统一草稿”。用户在这里主动编辑时，明确以新内容覆盖各目标保留的独立草稿。
    private var unifiedCommitMessage: Binding<String> {
        Binding(get: { commitMessage }, set: { value in
            commitMessage = value
            commitMessagesByBinding = Dictionary(uniqueKeysWithValues: commitBindings.map { ($0.id, value) })
        })
    }

    private var selectedCommitCount: Int {
        commitSelection.count(in: commitBindings.filter { effectiveCommitTargets.contains($0.id) })
    }

    private var currentConflicts: [FileChange] {
        model.snapshot?.changes.filter { $0.kind == .conflicted } ?? []
    }

    private var commitBlockedReason: String? {
        let conflicts = commitBindings.filter { effectiveCommitTargets.contains($0.id) }.reduce(0) { count, binding in
            count + (model.snapshots[binding.id]?.changes.filter { $0.kind == .conflicted }.count ?? 0)
        }
        return conflicts > 0 ? "所选来源有 \(conflicts) 个冲突，请先处理。" : nil
    }

    private var commitSelectionSignature: String {
        model.snapshots.keys.sorted().map { id in
            id + ":" + (model.snapshots[id]?.changes.map { $0.path + "=" + $0.kind.rawValue }.joined(separator: "\u{1F}") ?? "")
        }.joined(separator: "\u{1E}")
    }

    private func reconcileCommitSelection() {
        for binding in commitBindings {
            if let snapshot = model.snapshots[binding.id] {
                commitSelection.reconcile(changes: snapshot.changes, in: binding)
            }
        }
    }

    private func prepareSelectedCommit(withAI: Bool = false) {
        guard commitBlockedReason == nil, selectedCommitCount > 0, !effectiveCommitTargets.isEmpty else { return }
        startsCommitWithAI = withAI
        model.prepareCommit(initialTargets: effectiveCommitTargets, initialMessage: commitMessage,
                            initialPathsByBinding: commitSelection.pathsByBinding(commitBindings),
                            initialMessages: commitMessagesByBinding)
        showsCommitSheet = true
    }

    private func resolveCurrentConflict() {
        guard let conflict = currentConflicts.first else { return }
        if model.selectedBinding?.capabilities.contains(.conflictResolution) == true {
            model.showConflictEditor(path: conflict.path)
        } else {
            model.prepareManagement()
        }
    }

    private func preserveCommitDraft() {
        let commit = model.repositoryCommit
        if commit.phase == .finished, !commit.results.isEmpty, commit.results.allSatisfy({ $0.outcome == .succeeded }) {
            commitMessage = ""
            commitMessagesByBinding = [:]
        } else {
            guard !commit.preparations.isEmpty else { return }
            commitMessagesByBinding = Dictionary(uniqueKeysWithValues: commit.preparations.map {
                ($0.binding.id, commit.message(for: $0.binding.id))
            })
            if let id = commit.selectedBindingID {
                commitMessage = commit.message(for: id)
            }
        }
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
                if section == .history {
                    Text("·")
                    Text("\(model.historyRevisions.count) 条历史")
                }
            }
            if model.isOperationInProgress { Text("操作进行中").padding(.leading, 8) }
            if let monitor = model.monitor, !monitor.pendingBindingIDs.isEmpty {
                Button("检测到 \(monitor.pendingBindingIDs.count) 个来源变化") { model.refreshMonitoredChanges() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                    .disabled(model.isInteractionLocked)
            }
            if let monitor = model.migrationMonitor {
                if let notice = monitor.notices.first {
                    Button("源 SVN 有新提交 · \(notice.latestRevision)") { model.showMigrationSupplement(notice) }
                        .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                        .help("上次迁至 \(notice.migratedRevision)，点击预览补迁；不会自动修改或推送代码。")
                        .disabled(model.isInteractionLocked)
                }
                if let failure = monitor.errors.first {
                    Label("迁移源检查失败", systemImage: "exclamationmark.circle").help(failure.message)
                }
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
