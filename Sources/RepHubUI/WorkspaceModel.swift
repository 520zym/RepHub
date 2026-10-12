import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore
import AICore
import AIApplication

/// 工作区界面的状态拥有者；版本控制命令始终由 RepositoryService 调度。
@MainActor
@Observable
public final class WorkspaceModel {
    public let treeState = WorkspaceTreeState()
    public let fileBrowser = WorkspaceFileBrowser()
    public private(set) var filePreview: WorkspaceFilePreview?
    public private(set) var workspace: Workspace?
    public private(set) var snapshots: [String: BindingSnapshot] = [:]
    public private(set) var selectedBindingID: String?
    public private(set) var historyReference: String?
    /// 非空时，历史列表只表示这个相对文件路径。它不能复用 `selectedPath`：后者同时服务工作区和差异阅读。
    public private(set) var historyFilePath: String?
    /// 文件历史的锚点（例如从旧路径继续追溯），不应覆盖仓库的分支筛选。
    public private(set) var historyFileReference: String?
    public private(set) var historyFileEntries: [FileHistoryEntry] = []
    private var fileHistoryNextCursor: String?
    public private(set) var isLoadingMoreHistory = false
    public private(set) var historyPageError: String?
    private var historyPageTask: Task<Void, Never>?
    private var historyPageGeneration = 0
    private var fileHistorySyncStatus: RepositorySyncStatus?
    private var fileHistoryIssues: [String] = []
    private var explicitHistoryIssues: [String] = []
    /// 仓库历史显示仓库级同步状态；文件范围显示同一路径计算出的状态。
    public var historySyncStatus: RepositorySyncStatus? {
        historyFilePath == nil ? snapshot?.syncStatus : fileHistorySyncStatus
    }
    public var historyIssues: [String] {
        if !explicitHistoryIssues.isEmpty { return explicitHistoryIssues }
        return historyFilePath == nil ? (snapshot?.issues ?? []) : fileHistoryIssues
    }
    /// 文件历史请求的版本号；历史主视图据此切换到提交历史页面。
    public private(set) var historyPresentationRequest = 0
    public var selectedPath: String?
    public var selectedRevisionID: String?
    public private(set) var revisionFiles: [FileChange] = []
    public private(set) var patch: RepositoryPatch?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var isHistoryVisible = false
    public private(set) var operationKind: RepositoryOperationKind?
    public private(set) var operationBinding: RepositoryBinding?
    public private(set) var operationProgressMessage = ""
    public let operationTransferProgress = TransferProgressState()
    public private(set) var operationResult: RepositoryOperationResult?
    public private(set) var isOperationCancelling = false
    public var showsRepositoryAcquisition = false
    public let recentRepositories: RecentRepositoryStore
    public let workspaceLinks: WorkspaceLinkStore
    public let monitor: WorkspaceMonitor?
    public let repositoryManagement: RepositoryManagementModel
    public let repositorySetup: RepositorySetupModel
    public var showsRepositoryManagement = false
    public var showsRepositorySetup = false
    public var recentRepositoryError: String?
    public var showsAIReview = false
    public let aiReview: AIRunModel?

    private let service: RepositoryService
    /// 远程克隆／检出独立于已有工作副本的更新状态；认证信息仅在本次应用会话中使用。
    public let repositoryAcquisition: RepositoryAcquisitionModel
    /// 提交窗口拥有本次选择与结果；工作区只负责在完成后接收服务层已刷新的快照。
    public let repositoryCommit: RepositoryCommitModel
    private var workTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var requestToken = 0
    private var operationToken = 0
    private var workingSelection: ReadingSelection?
    private var historySelection: ReadingSelection?

    private struct ReadingSelection {
        let bindingID: String
        let reference: String?
        let revisionID: String?
        let path: String?
        let files: [FileChange]
        let patch: RepositoryPatch?
        let preview: WorkspaceFilePreview?
    }

    public init(service: RepositoryService, aiSettings: AISettingsStore? = nil, aiService: AIService? = nil,
                recentRepositories: RecentRepositoryStore = RecentRepositoryStore(),
                workspaceLinks: WorkspaceLinkStore = WorkspaceLinkStore(), monitor: WorkspaceMonitor? = nil) {
        self.service = service
        self.recentRepositories = recentRepositories
        self.workspaceLinks = workspaceLinks
        self.monitor = monitor
        self.repositoryManagement = RepositoryManagementModel(service: service)
        self.repositorySetup = RepositorySetupModel(service: service)
        self.repositoryAcquisition = RepositoryAcquisitionModel(service: service)
        if let aiSettings, let aiService {
            self.aiReview = AIRunModel(settings: aiSettings, service: aiService)
            self.repositoryCommit = RepositoryCommitModel(service: service, ai: AIRunModel(settings: aiSettings, service: aiService))
        } else {
            self.aiReview = nil
            self.repositoryCommit = RepositoryCommitModel(service: service)
        }
    }

    public func showAIReview(revision: String? = nil) {
        guard !isInteractionLocked, let binding = selectedBinding, let aiReview else { return }
        let paths = revision == nil ? (snapshot?.changes.map(\.path) ?? []) : revisionFiles.map(\.path)
        let contexts = RepositoryAIContextService(service: service)
        aiReview.prepare(kind: .codeReview,
                         sourceLabel: "\(binding.providerName) · \(revision.map { String($0.prefix(12)) } ?? "工作区改动")",
                         paths: paths) { selected in
            if let revision { return try await contexts.revision(in: binding, revision: revision, selectedPaths: selected) }
            return try await contexts.workingCopy(in: binding, selectedPaths: selected)
        }
        showsAIReview = true
    }

    isolated deinit {
        workTask?.cancel()
        operationTask?.cancel()
        historyPageTask?.cancel()
    }

    /// 版本控制写操作期间，所有会改变所选工作区或读取范围的入口均应保持锁定。
    public var isOperationInProgress: Bool { operationKind != nil && operationResult == nil }
    /// 供应用退出保护使用；操作后的状态核对同样属于进行中状态。
    public var isOperating: Bool {
        isOperationInProgress || repositoryAcquisition.isAcquiring || repositoryCommit.isBusy
            || repositoryManagement.isBusy || repositorySetup.isBusy
    }
    public var isInteractionLocked: Bool { isOperating }
    public var operationRefreshIssues: [String] {
        var seen = Set<String>()
        return ((workspace?.issues ?? []) + snapshots.values.flatMap(\.issues)).filter { seen.insert($0).inserted }
    }

    public func supports(_ operation: RepositoryOperationKind, for binding: RepositoryBinding) -> Bool {
        binding.capabilities.contains(operation.capability)
    }

    public func chooseFolder() {
        guard !isInteractionLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "打开工作区"
        panel.message = "选择已有 Git 或 Subversion 工作目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    public func showRepositoryAcquisition() {
        guard !isInteractionLocked else { return }
        cancelHistoryPage()
        showsRepositoryAcquisition = true
        repositoryAcquisition.prepare()
    }

    public func prepareCommit(initialTargets: Set<String>, initialMessage: String) {
        guard !isInteractionLocked, let workspace, !workspace.isUnmanaged else { return }
        cancelHistoryPage()
        repositoryCommit.prepare(in: workspace, initialTargets: initialTargets, initialMessage: initialMessage)
    }

    public func prepareManagement() {
        prepareManagement(comparing: nil)
    }

    public func prepareComparison(revision: Revision) {
        prepareManagement(comparing: revision)
    }

    private func prepareManagement(comparing revision: Revision?) {
        guard !isInteractionLocked, let workspace, let binding = selectedBinding else { return }
        cancelReading()
        cancelHistoryPage()
        let comparisonSeed = revision.map { revision in
            RepositoryComparisonSeed(
                fromRevision: revision.parents.first ?? previousRevisionIdentifier(for: revision, binding: binding),
                toRevision: revision.id
            )
        }
        repositoryManagement.prepare(in: workspace, binding: binding, comparisonSeed: comparisonSeed)
        showsRepositoryManagement = true
    }

    private func previousRevisionIdentifier(for revision: Revision, binding: RepositoryBinding) -> String? {
        guard binding.providerID == .svn,
              revision.id.first == "r",
              let value = Int(revision.id.dropFirst()), value > 0 else { return nil }
        return "r\(value - 1)"
    }

    public func prepareSetup() {
        guard !isInteractionLocked, let workspace, workspace.isUnmanaged else { return }
        repositorySetup.prepare(directory: workspace.directory)
        showsRepositorySetup = true
    }

    public func applyManagementResponse(_ response: WorkspaceManagementResult) {
        applyCommitResponse(WorkspaceCommitResult(results: [], workspace: response.workspace, snapshots: response.snapshots))
    }

    public func chooseLinkedFolder() {
        guard !isInteractionLocked, workspace != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "关联另一个工作副本"
        panel.message = "关联已有 Git 或 SVN 工作副本，在当前项目中分别查看和操作；不会复制或同步两个目录的文件。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        attachDirectory(directory)
    }

    public func attachDirectory(_ directory: URL) {
        guard !isInteractionLocked, let previous = workspace else { return }
        cancelHistoryPage()
        start { [weak self, service] token in
            guard let self else { return }
            let candidate = try await service.open(directory: directory)
            guard self.accepts(token), self.workspace?.id == previous.id else { return }
            guard !candidate.bindings.isEmpty, candidate.issues.isEmpty else {
                throw VersionControlError.invalidRepository(candidate.issues.isEmpty
                    ? "所选目录没有可关联的版本控制工作副本。" : candidate.issues.joined(separator: "\n"))
            }
            let directories = previous.linkedDirectories + [candidate.directory]
            let updated = try await service.open(directory: previous.directory, linkedDirectories: directories)
            guard self.accepts(token), self.workspace?.id == previous.id else { return }
            self.workspaceLinks.setDirectories(updated.linkedDirectories, for: previous.directory)
            self.workspace = updated
            self.recentRepositories.record(updated)
            self.restartMonitoring()
        }
    }

    public func removeLinkedDirectory(_ directory: URL) {
        guard !isInteractionLocked, let previous = workspace else { return }
        let normalized = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard previous.linkedDirectories.contains(normalized) else { return }
        cancelHistoryPage()
        start { [weak self, service] token in
            guard let self else { return }
            let directories = previous.linkedDirectories.filter { $0 != normalized }
            let updated = try await service.open(directory: previous.directory, linkedDirectories: directories)
            guard self.accepts(token), self.workspace?.id == previous.id else { return }
            self.workspaceLinks.setDirectories(updated.linkedDirectories, for: previous.directory)
            self.workspace = updated
            self.snapshots = self.snapshots.filter { key, _ in updated.bindings.contains { $0.id == key } }
            self.recentRepositories.record(updated)
            if !updated.bindings.contains(where: { $0.id == self.selectedBindingID }) {
                self.invalidateReadingCache()
                self.historyReference = nil
                self.clearFileHistoryState()
                self.selectedRevisionID = nil
                self.selectedPath = nil
                self.revisionFiles = []
                self.patch = nil
                self.selectedBindingID = updated.bindings.first?.id
                self.fileBrowser.setRoot(updated.bindings.first?.root)
                if let binding = updated.bindings.first {
                    try await self.load(binding: binding, reference: nil, token: token)
                }
            }
            self.restartMonitoring()
        }
    }

    public func closeWorkspace() {
        guard !isInteractionLocked else { return }
        cancelReading()
        invalidateReadingCache()
        monitor?.stop()
        repositoryManagement.dismiss()
        repositorySetup.dismiss()
        repositoryCommit.reset()
        workspace = nil
        snapshots = [:]
        selectedBindingID = nil
        historyReference = nil
        clearFileHistoryState()
        selectedPath = nil
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        errorMessage = nil
        fileBrowser.setRoot(nil)
        showsRepositoryManagement = false
        showsRepositorySetup = false
        isHistoryVisible = false
    }

    private func restartMonitoring() {
        guard let workspace else { monitor?.stop(); return }
        monitor?.start(workspace: workspace, shouldPoll: { [weak self] in
            guard let self else { return false }
            return NSApplication.shared.isActive && !self.isInteractionLocked && !self.isLoading
                && !self.isLoadingMoreHistory && !self.showsRepositoryManagement && !self.showsRepositorySetup
        }, canCheckManually: { [weak self] in
            guard let self else { return false }
            return !self.isInteractionLocked && !self.isLoading
                && !self.isLoadingMoreHistory && !self.showsRepositoryManagement && !self.showsRepositorySetup
        })
    }

    public func refreshMonitoredChanges() {
        guard !isInteractionLocked else { return }
        monitor?.acknowledge()
        refreshWorkspace(allBindings: true)
    }

    /// 服务层提交结束后始终返回全工作区新快照，界面不自行猜测哪些文件已写入。
    public func applyCommitResponse(_ response: WorkspaceCommitResult) {
        // 提交前的工作区/历史差异读取可能仍在外部工具中执行。先增加读取令牌，
        // 防止其迟到结果覆盖服务层已经核对并返回的新快照。
        cancelReading()
        errorMessage = nil
        workspace = response.workspace
        snapshots = Dictionary(uniqueKeysWithValues: response.snapshots.map { ($0.binding.id, $0) })
        restartMonitoring()
        fileBrowser.refresh()
        invalidateReadingCache()
        historyReference = nil
        clearFileHistoryState()
        isHistoryVisible = false
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        filePreview = nil
        if let binding = workspace?.bindings.first(where: { $0.id == selectedBindingID }) ?? workspace?.bindings.first {
            selectedBindingID = binding.id
            fileBrowser.setRoot(binding.root)
            let preferred = preferredFile(in: snapshots[binding.id]?.changes ?? [])
            selectedPath = preferred?.path
            if preferred == nil {
                selectedPath = nil
            } else {
                // 与常规工作区选择完全相同的读取与令牌路径，避免另起裸任务。
                loadPatch()
            }
        }
    }

    /// 从提交结果跳到对应来源的历史；新提交不在当前读取窗口时仍打开历史页并保留提示，而不会伪造定位成功。
    public func showCommittedRevision(bindingID: String, revisionID: String) {
        guard !isInteractionLocked, let binding = workspace?.bindings.first(where: { $0.id == bindingID }) else { return }
        historyPresentationRequest += 1
        clearFileHistoryState()
        historyReference = nil
        isHistoryVisible = true
        if selectedBindingID != binding.id {
            selectedBindingID = binding.id
            fileBrowser.setRoot(binding.root)
        }
        guard let revision = snapshots[binding.id]?.revisions.first(where: { $0.id == revisionID }) else {
            errorMessage = "已刷新工作区，但最新历史窗口中尚未找到该提交（\(revisionID)）。"
            return
        }
        selectedRevisionID = revision.id
        selectedPath = nil
        revisionFiles = []
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.loadRevision(revision, binding: binding, token: token)
        }
    }

    public func dismissRepositoryAcquisition() {
        guard !repositoryAcquisition.isBusy else { return }
        showsRepositoryAcquisition = false
    }

    public func openRecentRepository(_ repository: RecentRepository) {
        guard !isInteractionLocked, !repositoryAcquisition.isBusy else { return }
        showsRepositoryAcquisition = false
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isReadableFile(atPath: repository.path) else {
            recentRepositoryError = "文件夹不存在或无法访问：\n\(repository.path)\n\n请确认磁盘已连接，或从打开入口重新选择位置。可以在最近打开列表中移除此记录。"
            return
        }
        recentRepositoryError = nil
        openWorkspace(repository.directory, requiresManagedRepository: true)
    }

    public func open(_ url: URL) {
        openWorkspace(url, requiresManagedRepository: false)
    }

    private func openWorkspace(_ url: URL, requiresManagedRepository: Bool) {
        guard !isInteractionLocked else { return }
        cancelHistoryPage()
        start { [service] token in
            let linked = self.workspaceLinks.directories(for: url)
            let workspace = try await service.open(directory: url, linkedDirectories: linked)
            guard self.accepts(token) else { return }
            if requiresManagedRepository, workspace.bindings.isEmpty {
                let reason = workspace.issues.isEmpty ? "此文件夹已无法识别为受版本控制的仓库。" : workspace.issues.joined(separator: "\n")
                self.recentRepositoryError = "\(reason)\n\n\(url.path)\n\n当前工作区保持打开，可以移除此记录或重新选择仓库位置。"
                return
            }
            self.invalidateReadingCache()
            self.fileBrowser.setRoot(nil)
            self.workspace = workspace
            self.restartMonitoring()
            self.recentRepositories.record(workspace)
            self.snapshots = [:]
            self.patch = nil
            self.selectedPath = nil
            self.selectedRevisionID = nil
            self.revisionFiles = []
            self.selectedBindingID = workspace.bindings.first?.id
            self.historyReference = nil
            self.clearFileHistoryState()
            self.fileBrowser.setRoot(workspace.bindings.first?.root)
            if let binding = workspace.bindings.first {
                try await self.load(binding: binding, reference: nil, token: token)
            }
        }
    }

    public func refresh() {
        refreshWorkspace(allBindings: false)
    }

    private func refreshWorkspace(allBindings: Bool) {
        guard !isInteractionLocked else { return }
        guard let priorBinding = selectedBinding, let previous = workspace else { return }
        cancelHistoryPage()
        let revisionID = selectedRevisionID
        let reference = historyReference
        let filePath = historyFilePath
        let fileReference = historyFileReference
        let workingPath = selectedRevisionID == nil ? selectedPath : nil
        invalidateReadingCache()
        fileBrowser.refresh()
        selectedRevisionID = nil
        revisionFiles = []
        selectedPath = nil
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            let updated = try await self.service.open(directory: previous.directory, linkedDirectories: previous.linkedDirectories)
            guard self.accepts(token), self.workspace?.id == previous.id else { return }
            self.workspace = updated
            guard let binding = updated.bindings.first(where: { $0.id == priorBinding.id }) ?? updated.bindings.first else {
                self.snapshots = [:]
                self.selectedBindingID = nil
                self.fileBrowser.setRoot(nil)
                self.restartMonitoring()
                return
            }
            self.selectedBindingID = binding.id
            self.fileBrowser.setRoot(binding.root)
            if allBindings {
                for other in updated.bindings where other.id != binding.id {
                    let snapshot = await self.service.load(other)
                    guard self.accepts(token) else { return }
                    self.snapshots[other.id] = snapshot
                }
            }
            self.restartMonitoring()
            if let filePath {
                try await self.reloadFileHistory(binding: binding, path: filePath, reference: fileReference,
                                                 preferredRevisionID: revisionID, token: token)
                return
            }
            try await self.load(binding: binding, reference: reference, token: token, readsWorkingPatch: revisionID == nil && workingPath == nil)
            if revisionID == nil, let workingPath, self.accepts(token) {
                try await self.loadWorkingFile(path: workingPath, binding: binding, token: token)
            }
            if let revisionID, self.accepts(token),
               let revision = self.snapshot?.revisions.first(where: { $0.id == revisionID }) ?? self.snapshot?.revisions.first {
                self.selectedRevisionID = revision.id
                try await self.loadRevision(revision, binding: binding, token: token)
            }
        }
    }

    /// 切换主视图时同步选择范围，避免历史页继续展示工作区差异。
    public func setHistoryVisible(_ visible: Bool) {
        guard !isInteractionLocked else { return }
        guard isHistoryVisible != visible else { return }
        saveReadingSelection()
        cancelReading()
        isHistoryVisible = visible

        if visible {
            if !restoreReadingSelection(historySelection) { selectRevision(historyRevisions.first) }
        } else {
            clearFileHistoryState()
            if !restoreReadingSelection(workingSelection) { selectChange(preferredFile(in: snapshot?.changes ?? [])) }
        }
    }

    public func selectBinding(_ binding: RepositoryBinding) {
        guard !isInteractionLocked else { return }
        guard selectedBindingID != binding.id else { return }
        invalidateReadingCache()
        fileBrowser.setRoot(binding.root)
        selectedBindingID = binding.id
        historyReference = nil
        clearFileHistoryState()
        selectedPath = nil
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.load(binding: binding, reference: nil, token: token)
        }
    }

    public func selectChange(_ change: FileChange?) {
        guard !isInteractionLocked else { return }
        saveReadingSelection()
        filePreview = nil
        selectedPath = change?.path
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        loadPatch()
    }

    /// 全部文件树复用变更差异，未修改文件显示有界的只读内容。
    public func selectWorkspaceFile(path: String) {
        guard !isInteractionLocked, let binding = selectedBinding,
              let path = validatedRelativePath(path) else { return }
        if let change = snapshot?.changes.first(where: { $0.path == path }) {
            selectChange(change)
            return
        }
        saveReadingSelection()
        selectedPath = path
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        filePreview = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.loadWorkingFile(path: path, binding: binding, token: token)
        }
    }

    /// 显示某一文件的历史。调用方可传入已删除的历史路径；只有路径本身越界时会被拒绝。
    public func showFileHistory(path: String, reference: String? = nil) {
        guard !isInteractionLocked, let binding = selectedBinding else { return }
        cancelHistoryPage()
        saveReadingSelection()
        filePreview = nil
        guard let path = validatedRelativePath(path) else {
            clearFileHistoryState()
            selectedRevisionID = nil
            selectedPath = nil
            revisionFiles = []
            patch = nil
            explicitHistoryIssues = ["文件路径无效，不能使用绝对路径或上级目录。"]
            errorMessage = explicitHistoryIssues.first
            return
        }

        historyPresentationRequest += 1
        historyFilePath = path
        historyFileEntries = []
        fileHistoryNextCursor = nil
        fileHistorySyncStatus = nil
        fileHistoryIssues = []
        explicitHistoryIssues = []
        historyFileReference = reference
        selectedRevisionID = nil
        selectedPath = nil
        revisionFiles = []
        patch = nil
        isHistoryVisible = true

        start { [weak self] token in
            guard let self else { return }
            let fileHistory: FileHistorySnapshot
            do {
                fileHistory = try await self.service.fileHistory(in: binding, path: path, reference: reference)
            } catch {
                guard self.accepts(token), self.selectedBindingID == binding.id,
                      self.historyFilePath == path, self.historyFileReference == reference else { throw error }
                self.fileHistoryIssues = ["文件历史：\(error.localizedDescription)"]
                throw error
            }
            guard self.accepts(token), self.selectedBindingID == binding.id,
                  self.historyFilePath == path, self.historyFileReference == reference else { return }
            self.historyFileEntries = fileHistory.entries
            self.fileHistoryNextCursor = fileHistory.nextCursor
            self.fileHistorySyncStatus = fileHistory.syncStatus
            self.fileHistoryIssues = fileHistory.issues
            guard let entry = fileHistory.entries.first else { return }
            self.selectedRevisionID = entry.revision.id
            try await self.loadFileHistoryRevision(entry, binding: binding, token: token)
        }
    }

    /// 从当前工作目录挑选文件。面板中必须解析真实路径，防止符号链接越出仓库根目录。
    public func chooseFileHistory() {
        guard !isInteractionLocked, let binding = selectedBinding else { return }
        let reference = historyFilePath == nil ? historyReference : historyFileReference
        let panel = NSOpenPanel()
        panel.title = "查看文件历史"
        panel.message = "选择当前仓库中的一个文件"
        panel.directoryURL = binding.root
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let path = relativePathInsideBinding(url, binding: binding) else { return }
        showFileHistory(path: path, reference: reference)
    }

    public func clearFileHistory() {
        guard !isInteractionLocked else { return }
        clearFileHistoryState()
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        if isHistoryVisible, !restoreReadingSelection(historySelection) { selectRevision(snapshot?.revisions.first) }
    }

    public func selectRevision(_ revision: Revision?) {
        guard !isInteractionLocked else { return }
        saveReadingSelection()
        if historyFilePath == nil, let revision, historySelection?.revisionID == revision.id,
           restoreReadingSelection(historySelection) { return }
        filePreview = nil
        selectedRevisionID = revision?.id
        selectedPath = nil
        revisionFiles = []
        patch = nil
        guard let binding = selectedBinding, let revision else {
            patch = nil
            return
        }
        if historyFilePath != nil {
            guard let entry = historyFileEntries.first(where: { $0.revision.id == revision.id }) else { return }
            start { [weak self] token in
                guard let self else { return }
                try await self.loadFileHistoryRevision(entry, binding: binding, token: token)
            }
            return
        }
        start { [weak self] token in
            guard let self else { return }
            try await self.loadRevision(revision, binding: binding, token: token)
        }
    }

    /// 分支入口只改变历史查询范围，不改动当前工作副本。
    public func selectHistoryReference(_ reference: String?) {
        guard !isInteractionLocked else { return }
        guard let binding = selectedBinding else { return }
        historyReference = reference
        historySelection = nil
        filePreview = nil
        clearFileHistoryState()
        selectedRevisionID = nil
        selectedPath = nil
        revisionFiles = []
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.load(binding: binding, reference: reference, token: token, readsWorkingPatch: false)
            guard self.accepts(token), let first = self.snapshot?.revisions.first else { return }
            self.selectedRevisionID = first.id
            try await self.loadRevision(first, binding: binding, token: token)
        }
    }

    /// 历史文件只缩小当前修订的差异范围，不改变已选修订或工作区状态列表。
    public func selectRevisionFile(_ change: FileChange?) {
        guard !isInteractionLocked else { return }
        filePreview = nil
        selectedPath = change?.path
        patch = nil
        guard let binding = selectedBinding,
              let revisionID = selectedRevisionID,
              let path = change?.path else { return }
        start { [weak self] token in
            guard let self else { return }
            let patch: RepositoryPatch
            if let entry = self.historyFileEntries.first(where: { $0.revision.id == revisionID && $0.path == path }) {
                patch = try await self.service.fileHistoryDiff(in: binding, entry: entry)
            } else {
                patch = try await self.service.diff(in: binding, path: path, revision: revisionID)
            }
            guard self.accepts(token), self.selectedBindingID == binding.id,
                  self.selectedRevisionID == revisionID, self.selectedPath == path else { return }
            self.patch = patch
        }
    }

    public var selectedBinding: RepositoryBinding? {
        workspace?.bindings.first { $0.id == selectedBindingID }
    }

    public var snapshot: BindingSnapshot? {
        selectedBindingID.flatMap { snapshots[$0] }
    }

    /// 当前历史范围内可展示的提交；文件范围下保留适配器提供的重命名/peg 信息，选择时会回查对应条目。
    public var historyRevisions: [Revision] {
        historyFilePath == nil ? (snapshot?.revisions ?? []) : historyFileEntries.map(\.revision)
    }

    public var hasMoreHistory: Bool { nextHistoryCursor != nil }

    public func cancelLoadingMoreHistory() { cancelHistoryPage() }

    private var nextHistoryCursor: String? {
        historyFilePath == nil ? snapshot?.nextHistoryCursor : fileHistoryNextCursor
    }

    /// 翻页有独立任务，选中某条提交读取差异不会取消正在加载的历史。
    public func loadMoreHistory() {
        guard !isInteractionLocked, !isLoading, !isLoadingMoreHistory,
              let binding = selectedBinding, let cursor = nextHistoryCursor else { return }
        let generation = historyPageGeneration
        let workspaceID = workspace?.id
        let reference = historyReference
        let filePath = historyFilePath
        let fileReference = historyFileReference
        let loadedRevisions = historyRevisions
        isLoadingMoreHistory = true
        historyPageError = nil
        historyPageTask = Task { [weak self, service] in
            guard let self else { return }
            @MainActor func acceptsPage() -> Bool {
                !Task.isCancelled && self.historyPageGeneration == generation && self.workspace?.id == workspaceID
                    && self.selectedBindingID == binding.id && self.historyReference == reference
                    && self.historyFilePath == filePath && self.historyFileReference == fileReference
                    && self.nextHistoryCursor == cursor && !self.isInteractionLocked
            }
            do {
                if let filePath {
                    let page = try await service.fileHistory(in: binding, path: filePath, reference: fileReference,
                                                            cursor: cursor, loadedRevisions: loadedRevisions)
                    guard acceptsPage() else { return }
                    guard page.nextCursor != cursor else { throw VersionControlError.invalidData("历史分页未能继续，请刷新后重试。") }
                    var seen = Set(self.historyFileEntries.map(\.id))
                    self.historyFileEntries += page.entries.filter { seen.insert($0.id).inserted }
                    self.fileHistoryNextCursor = page.nextCursor
                    self.fileHistorySyncStatus = page.syncStatus ?? self.fileHistorySyncStatus
                    self.fileHistoryIssues = Self.mergingIssues(self.fileHistoryIssues, page.issues)
                } else {
                    let page = try await service.historyPage(in: binding, reference: reference, cursor: cursor,
                                                            loadedRevisions: loadedRevisions)
                    guard acceptsPage(), let current = self.snapshots[binding.id] else { return }
                    guard page.nextCursor != cursor else { throw VersionControlError.invalidData("历史分页未能继续，请刷新后重试。") }
                    var seen = Set(current.revisions.map(\.id))
                    let revisions = current.revisions + page.revisions.filter { seen.insert($0.id).inserted }
                    self.snapshots[binding.id] = BindingSnapshot(
                        binding: current.binding, changes: current.changes, revisions: revisions,
                        branches: current.branches, issues: Self.mergingIssues(current.issues, page.issues),
                        syncStatus: page.syncStatus ?? current.syncStatus, nextHistoryCursor: page.nextCursor)
                }
                self.isLoadingMoreHistory = false
            } catch is CancellationError {
                if self.historyPageGeneration == generation { self.isLoadingMoreHistory = false }
            } catch {
                guard acceptsPage() else { return }
                self.isLoadingMoreHistory = false
                self.historyPageError = RepositoryDisplaySanitizer.redact(error.localizedDescription)
            }
        }
    }

    private func cancelHistoryPage() {
        historyPageTask?.cancel()
        historyPageTask = nil
        historyPageGeneration += 1
        isLoadingMoreHistory = false
        historyPageError = nil
    }

    private static func mergingIssues(_ previous: [String], _ next: [String]) -> [String] {
        var seen = Set<String>()
        return (previous + next).filter { seen.insert($0).inserted }
    }

    /// 单次写操作只针对一个绑定。服务层负责串行化以及结束后的全部绑定刷新。
    public func performOperation(_ kind: RepositoryOperationKind, on binding: RepositoryBinding) {
        guard !isInteractionLocked,
              workspace != nil,
              supports(kind, for: binding) else { return }

        invalidateReadingCache()

        operationToken += 1
        let token = operationToken
        operationKind = kind
        operationBinding = binding
        operationResult = nil
        operationProgressMessage = "正在准备\(kind.title)…"
        operationTransferProgress.begin(operationProgressMessage)
        isOperationCancelling = false
        // 读取任务不得在写操作进行时以迟到结果覆盖服务层的操作后快照。
        workTask?.cancel()
        requestToken += 1
        isLoading = false

        // 记录阅读上下文。写操作结束后的快照来自服务层，补回当前所选差异即可。
        let preservedBindingID = selectedBindingID
        let preservedReference = historyReference
        let preservedFilePath = historyFilePath
        let preservedFileReference = historyFileReference
        let preservedRevisionID = selectedRevisionID
        let preservedPath = selectedPath
        let operationWorkspace = workspace ?? Workspace(directory: binding.root, bindings: [binding], issues: [])
        operationTask = Task { [weak self, service] in
            do {
                let response = try await service.perform(kind, bindingID: binding.id, in: operationWorkspace) { progress in
                    await MainActor.run {
                        guard let self, self.operationToken == token else { return }
                        self.operationProgressMessage = progress.message
                        self.operationTransferProgress.consume(progress)
                    }
                }
                // 取消后的调用任务带有取消标记。差异恢复必须切到独立任务，
                // 不能让已取消的上下文直接中断服务层已核对完的快照恢复。
                Task.detached { [weak self, service] in
                    await self?.applyOperationResponse(
                        response,
                        service: service,
                        preferredBindingID: preservedBindingID,
                        reference: preservedReference,
                        filePath: preservedFilePath,
                        fileReference: preservedFileReference,
                        revisionID: preservedRevisionID,
                        path: preservedPath,
                        token: token
                    )
                }
            } catch is CancellationError {
                // 服务层会在取消后核对状态并返回结果；这里仅兜底处理异常早退。
                guard let self, self.operationToken == token else { return }
                self.operationResult = RepositoryOperationResult(kind: kind, bindingID: binding.id, outcome: .cancelled, summary: "已取消，未确认是否产生远端或工作区变更。")
                self.operationProgressMessage = self.operationResult?.summary ?? "已取消"
                self.operationTransferProgress.finish(self.operationProgressMessage)
                self.isOperationCancelling = false
            } catch {
                guard let self, self.operationToken == token else { return }
                self.operationResult = RepositoryOperationResult(kind: kind, bindingID: binding.id, outcome: .failed, summary: "操作未完成", details: error.localizedDescription)
                self.operationProgressMessage = self.operationResult?.summary ?? "操作未完成"
                self.operationTransferProgress.finish(self.operationProgressMessage)
                self.isOperationCancelling = false
            }
        }
    }

    private func applyOperationResponse(
        _ response: WorkspaceOperationResult,
        service: RepositoryService,
        preferredBindingID: String?,
        reference: String?,
        filePath: String?,
        fileReference: String?,
        revisionID: String?,
        path: String?,
        token: Int
    ) async {
        guard operationToken == token else { return }
        workspace = response.workspace
        snapshots = Dictionary(uniqueKeysWithValues: response.snapshots.map { ($0.binding.id, $0) })
        fileBrowser.refresh()
        await restoreSelectionAfterOperation(
            service: service,
            preferredBindingID: preferredBindingID,
            reference: reference,
            filePath: filePath,
            fileReference: fileReference,
            revisionID: revisionID,
            path: path,
            token: token
        )
        guard operationToken == token else { return }
        operationResult = response.result
        operationProgressMessage = response.result.summary
        operationTransferProgress.finish(response.result.summary)
        isOperationCancelling = false
        restartMonitoring()
    }

    /// 取消并不回滚已由 Git/SVN 落地的步骤；仍等待服务层刷新真实状态。
    public func cancelOperation() {
        if repositoryManagement.isBusy { repositoryManagement.cancel(); return }
        if repositorySetup.isExecuting { repositorySetup.cancel(); return }
        if repositoryCommit.isBusy { repositoryCommit.cancel(); return }
        if repositoryAcquisition.isAcquiring {
            repositoryAcquisition.cancel()
            return
        }
        guard isOperationInProgress, !isOperationCancelling else { return }
        isOperationCancelling = true
        operationProgressMessage = "正在取消并核对工作区状态…"
        operationTransferProgress.consume(RepositoryOperationProgress(operationProgressMessage))
        operationTask?.cancel()
    }

    public func dismissOperationResult() {
        guard !isOperationInProgress else { return }
        operationKind = nil
        operationBinding = nil
        operationProgressMessage = ""
        operationTransferProgress.clear()
        operationResult = nil
        isOperationCancelling = false
    }

    private func restoreSelectionAfterOperation(
        service: RepositoryService,
        preferredBindingID: String?,
        reference: String?,
        filePath: String?,
        fileReference: String?,
        revisionID: String?,
        path: String?,
        token: Int
    ) async {
        guard let workspace else { return }
        let binding = workspace.bindings.first { $0.id == preferredBindingID } ?? workspace.bindings.first
        selectedBindingID = binding?.id
        fileBrowser.setRoot(binding?.root)
        historyReference = reference
        historyFilePath = filePath
        historyFileReference = fileReference
        historyFileEntries = []
        fileHistorySyncStatus = nil
        fileHistoryIssues = []
        explicitHistoryIssues = []
        selectedRevisionID = revisionID
        selectedPath = path
        revisionFiles = []
        patch = nil
        guard let binding else { return }

        // service.perform 的全量快照采用默认历史范围。保留分支筛选时必须重新按该范围读取。
        do {
            if let filePath {
                try await reloadFileHistory(binding: binding, path: filePath, reference: fileReference,
                                            preferredRevisionID: revisionID, token: token, restoresOperation: true)
                return
            }
            if let reference {
                let scopedSnapshot = await service.load(binding, reference: reference)
                guard operationToken == token, selectedBindingID == binding.id else { return }
                snapshots[binding.id] = scopedSnapshot
            }

            if isHistoryVisible {
                let revision = revisionID.flatMap { requested in
                    snapshots[binding.id]?.revisions.first(where: { $0.id == requested })
                } ?? snapshots[binding.id]?.revisions.first
                guard let revision else {
                    selectedRevisionID = nil
                    selectedPath = nil
                    revisionFiles = []
                    patch = nil
                    return
                }
                selectedRevisionID = revision.id
                selectedPath = nil
                try await loadRevisionAfterOperation(revision, binding: binding, service: service, token: token)
            } else if let revisionID,
                      let revision = snapshots[binding.id]?.revisions.first(where: { $0.id == revisionID }) {
                try await loadRevisionAfterOperation(revision, binding: binding, service: service, token: token)
            } else {
                if let path, !snapshots[binding.id, default: BindingSnapshot(binding: binding)].changes.contains(where: { $0.path == path }),
                   FileManager.default.fileExists(atPath: binding.root.appendingPathComponent(path).path) {
                    let preview = try await fileBrowser.preview(path: path)
                    guard operationToken == token, selectedBindingID == binding.id else { return }
                    selectedRevisionID = nil
                    selectedPath = path
                    filePreview = preview
                    return
                }
                let candidate = path.flatMap { requested in
                    snapshots[binding.id]?.changes.first(where: { $0.path == requested })
                } ?? preferredFile(in: snapshots[binding.id]?.changes ?? [])
                selectedRevisionID = nil
                selectedPath = candidate?.path
                let patch = try await service.diff(in: binding, path: candidate?.path, revision: nil)
                guard operationToken == token, selectedBindingID == binding.id else { return }
                self.patch = patch
            }
        } catch {
            guard operationToken == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadRevisionAfterOperation(_ revision: Revision, binding: RepositoryBinding, service: RepositoryService, token: Int) async throws {
        let files = try await service.changedFiles(in: binding, revision: revision.id)
        guard operationToken == token, selectedBindingID == binding.id, selectedRevisionID == revision.id else { return }
        revisionFiles = files
        let file = preferredFile(in: files)
        selectedPath = file?.path
        let patch = try await service.diff(in: binding, path: file?.path, revision: revision.id)
        guard operationToken == token, selectedBindingID == binding.id, selectedRevisionID == revision.id, selectedPath == file?.path else { return }
        self.patch = patch
    }

    private func load(binding: RepositoryBinding, reference: String?, token: Int, readsWorkingPatch: Bool = true) async throws {
        let snapshot = await service.load(binding, reference: reference)
        guard accepts(token), selectedBindingID == binding.id else { return }
        snapshots[binding.id] = snapshot
        guard readsWorkingPatch else { return }

        if isHistoryVisible {
            guard let revision = snapshot.revisions.first else {
                selectedRevisionID = nil
                selectedPath = nil
                revisionFiles = []
                patch = nil
                return
            }
            selectedRevisionID = revision.id
            selectedPath = nil
            revisionFiles = []
            patch = nil
            try await loadRevision(revision, binding: binding, token: token)
            return
        }

        guard let first = preferredFile(in: snapshot.changes) else { return }
        selectedPath = first.path
        let patch = try await service.diff(in: binding, path: first.path, revision: nil)
        guard accepts(token), selectedBindingID == binding.id, selectedRevisionID == nil, selectedPath == first.path else { return }
        self.patch = patch
    }

    private func loadRevision(_ revision: Revision, binding: RepositoryBinding, token: Int) async throws {
        let files = try await service.changedFiles(in: binding, revision: revision.id)
        guard accepts(token), selectedBindingID == binding.id, selectedRevisionID == revision.id else { return }
        revisionFiles = files
        let file = preferredFile(in: files)
        selectedPath = file?.path
        let patch = try await service.diff(in: binding, path: file?.path, revision: revision.id)
        guard accepts(token), selectedBindingID == binding.id, selectedRevisionID == revision.id, selectedPath == file?.path else { return }
        self.patch = patch
    }

    private func loadWorkingFile(path: String, binding: RepositoryBinding, token: Int) async throws {
        selectedRevisionID = nil
        selectedPath = path
        revisionFiles = []
        if snapshot?.changes.contains(where: { $0.path == path }) == true {
            let value = try await service.diff(in: binding, path: path, revision: nil)
            guard accepts(token), selectedBindingID == binding.id, selectedRevisionID == nil, selectedPath == path else { return }
            filePreview = nil
            patch = value
        } else {
            let value = try await fileBrowser.preview(path: path)
            guard accepts(token), selectedBindingID == binding.id, selectedRevisionID == nil, selectedPath == path else { return }
            patch = nil
            filePreview = value
        }
    }

    /// TAB 往返只恢复阅读状态；显式刷新、更新和切源才使缓存失效。
    private func saveReadingSelection() {
        guard !isLoading, errorMessage == nil, historyFilePath == nil, let bindingID = selectedBindingID else { return }
        let selection = ReadingSelection(bindingID: bindingID, reference: historyReference,
                                         revisionID: selectedRevisionID, path: selectedPath,
                                         files: revisionFiles, patch: patch, preview: filePreview)
        if selectedRevisionID != nil { historySelection = selection }
        else { workingSelection = selection }
    }

    private func restoreReadingSelection(_ selection: ReadingSelection?) -> Bool {
        guard let selection, selection.bindingID == selectedBindingID,
              selection.revisionID == nil || selection.reference == historyReference else { return false }
        cancelReading()
        selectedRevisionID = selection.revisionID
        selectedPath = selection.path
        revisionFiles = selection.files
        patch = selection.patch
        filePreview = selection.preview
        errorMessage = nil
        return true
    }

    private func invalidateReadingCache() {
        cancelHistoryPage()
        workingSelection = nil
        historySelection = nil
        filePreview = nil
    }

    private func cancelReading() {
        workTask?.cancel()
        requestToken += 1
        isLoading = false
    }

    private func reloadFileHistory(
        binding: RepositoryBinding,
        path: String,
        reference: String?,
        preferredRevisionID: String?,
        token: Int,
        restoresOperation: Bool = false
    ) async throws {
        // 先清空旧数据；读取失败时绝不能把旧文件的同步状态或提交列表保留在界面上。
        historyFileEntries = []
        fileHistoryNextCursor = nil
        fileHistorySyncStatus = nil
        fileHistoryIssues = []
        explicitHistoryIssues = []
        let fileHistory: FileHistorySnapshot
        do {
            fileHistory = try await service.fileHistory(in: binding, path: path, reference: reference)
        } catch {
            guard acceptsHistoryLoad(token, restoresOperation: restoresOperation), selectedBindingID == binding.id,
                  historyFilePath == path, historyFileReference == reference else { throw error }
            fileHistoryIssues = ["文件历史：\(error.localizedDescription)"]
            throw error
        }
        guard acceptsHistoryLoad(token, restoresOperation: restoresOperation), selectedBindingID == binding.id,
              historyFilePath == path, historyFileReference == reference else { return }
        historyFileEntries = fileHistory.entries
        fileHistoryNextCursor = fileHistory.nextCursor
        fileHistorySyncStatus = fileHistory.syncStatus
        fileHistoryIssues = fileHistory.issues
        guard let entry = preferredRevisionID.flatMap({ requested in
            fileHistory.entries.first(where: { $0.revision.id == requested })
        }) ?? fileHistory.entries.first else {
            selectedRevisionID = nil
            selectedPath = nil
            revisionFiles = []
            patch = nil
            return
        }
        selectedRevisionID = entry.revision.id
        try await loadFileHistoryRevision(entry, binding: binding, token: token, restoresOperation: restoresOperation)
    }

    private func loadFileHistoryRevision(
        _ entry: FileHistoryEntry,
        binding: RepositoryBinding,
        token: Int,
        restoresOperation: Bool = false
    ) async throws {
        guard historyFilePath != nil else { return }
        let revisionID = entry.revision.id
        selectedRevisionID = revisionID
        selectedPath = entry.path
        // 文件历史的右侧列表只能包含该文件，不能误把整次提交的改动带入。
        revisionFiles = [FileChange(path: entry.path, kind: .modified)]
        let patch = try await service.fileHistoryDiff(in: binding, entry: entry)
        guard acceptsHistoryLoad(token, restoresOperation: restoresOperation), selectedBindingID == binding.id,
              historyFilePath != nil, selectedRevisionID == revisionID,
              selectedPath == entry.path else { return }
        self.patch = patch
    }

    private func clearFileHistoryState() {
        cancelHistoryPage()
        historyFilePath = nil
        historyFileReference = nil
        historyFileEntries = []
        fileHistoryNextCursor = nil
        fileHistorySyncStatus = nil
        fileHistoryIssues = []
        explicitHistoryIssues = []
    }

    private func validatedRelativePath(_ candidate: String) -> String? {
        guard !candidate.isEmpty, !candidate.hasPrefix("/") else { return nil }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private func relativePathInsideBinding(_ url: URL, binding: RepositoryBinding) -> String? {
        let root = binding.root.standardizedFileURL.resolvingSymlinksInPath()
        let selected = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard selected.path.hasPrefix(rootPath) else { return nil }
        return validatedRelativePath(String(selected.path.dropFirst(rootPath.count)))
    }

    private func preferredFile(in files: [FileChange]) -> FileChange? {
        let sourceExtensions: Set<String> = ["swift", "java", "kt", "js", "ts", "tsx", "py", "go", "rs", "c", "cpp", "h", "xml", "json", "yaml", "yml"]
        return files.first(where: { $0.kind != .untracked && sourceExtensions.contains(($0.path as NSString).pathExtension.lowercased()) })
            ?? files.first(where: { sourceExtensions.contains(($0.path as NSString).pathExtension.lowercased()) })
            ?? files.first
    }

    private func loadPatch() {
        guard let binding = selectedBinding else { return }
        let path = selectedPath
        start { [weak self] token in
            guard let self else { return }
            let patch = try await self.service.diff(in: binding, path: path, revision: nil)
            guard self.accepts(token), self.selectedBindingID == binding.id, self.selectedPath == path, self.selectedRevisionID == nil else { return }
            self.patch = patch
        }
    }

    private func accepts(_ token: Int) -> Bool {
        !Task.isCancelled && requestToken == token
    }

    private func acceptsHistoryLoad(_ token: Int, restoresOperation: Bool) -> Bool {
        restoresOperation ? operationToken == token : accepts(token)
    }

    private func start(_ operation: @escaping (Int) async throws -> Void) {
        workTask?.cancel()
        requestToken += 1
        let token = requestToken
        isLoading = true
        errorMessage = nil
        workTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation(token)
                guard self?.accepts(token) == true else { return }
                self?.isLoading = false
                if self?.monitor?.lastCheckedAt == nil { self?.monitor?.checkNow() }
            } catch is CancellationError {
            } catch {
                guard self?.accepts(token) == true else { return }
                self?.isLoading = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}
