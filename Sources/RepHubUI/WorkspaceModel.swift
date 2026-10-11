import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 工作区界面的状态拥有者；版本控制命令始终由 RepositoryService 调度。
@MainActor
@Observable
public final class WorkspaceModel {
    public private(set) var workspace: Workspace?
    public private(set) var snapshots: [String: BindingSnapshot] = [:]
    public private(set) var selectedBindingID: String?
    public private(set) var historyReference: String?
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
    public private(set) var operationResult: RepositoryOperationResult?
    public private(set) var isOperationCancelling = false

    private let service: RepositoryService
    private var workTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var requestToken = 0
    private var operationToken = 0

    public init(service: RepositoryService) {
        self.service = service
    }

    isolated deinit {
        workTask?.cancel()
        operationTask?.cancel()
    }

    /// 版本控制写操作期间，所有会改变所选工作区或读取范围的入口均应保持锁定。
    public var isOperationInProgress: Bool { operationKind != nil && operationResult == nil }
    /// 供应用退出保护使用；操作后的状态核对同样属于进行中状态。
    public var isOperating: Bool { isOperationInProgress }
    public var isInteractionLocked: Bool { isOperationInProgress }
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

    public func open(_ url: URL) {
        guard !isInteractionLocked else { return }
        start { [service] token in
            let workspace = try await service.open(directory: url)
            guard self.accepts(token) else { return }
            self.workspace = workspace
            self.snapshots = [:]
            self.patch = nil
            self.selectedPath = nil
            self.selectedRevisionID = nil
            self.revisionFiles = []
            self.selectedBindingID = workspace.bindings.first?.id
            self.historyReference = nil
            if let binding = workspace.bindings.first {
                try await self.load(binding: binding, reference: nil, token: token)
            }
        }
    }

    public func refresh() {
        guard !isInteractionLocked else { return }
        guard let binding = selectedBinding else { return }
        let revisionID = selectedRevisionID
        let reference = historyReference
        selectedRevisionID = nil
        revisionFiles = []
        selectedPath = nil
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.load(binding: binding, reference: reference, token: token, readsWorkingPatch: revisionID == nil)
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
        isHistoryVisible = visible

        if visible {
            selectRevision(snapshot?.revisions.first)
        } else {
            selectChange(preferredFile(in: snapshot?.changes ?? []))
        }
    }

    public func selectBinding(_ binding: RepositoryBinding) {
        guard !isInteractionLocked else { return }
        guard selectedBindingID != binding.id else { return }
        selectedBindingID = binding.id
        historyReference = nil
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
        selectedPath = change?.path
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        loadPatch()
    }

    public func selectRevision(_ revision: Revision?) {
        guard !isInteractionLocked else { return }
        selectedRevisionID = revision?.id
        selectedPath = nil
        revisionFiles = []
        patch = nil
        guard let binding = selectedBinding, let revision else {
            patch = nil
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
        selectedPath = change?.path
        patch = nil
        guard let binding = selectedBinding,
              let revisionID = selectedRevisionID,
              let path = change?.path else { return }
        start { [weak self] token in
            guard let self else { return }
            let patch = try await self.service.diff(in: binding, path: path, revision: revisionID)
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

    /// 单次写操作只针对一个绑定。服务层负责串行化以及结束后的全部绑定刷新。
    public func performOperation(_ kind: RepositoryOperationKind, on binding: RepositoryBinding) {
        guard !isInteractionLocked,
              workspace != nil,
              supports(kind, for: binding) else { return }

        operationToken += 1
        let token = operationToken
        operationKind = kind
        operationBinding = binding
        operationResult = nil
        operationProgressMessage = "正在准备\(kind.title)…"
        isOperationCancelling = false
        // 读取任务不得在写操作进行时以迟到结果覆盖服务层的操作后快照。
        workTask?.cancel()
        requestToken += 1
        isLoading = false

        // 记录阅读上下文。写操作结束后的快照来自服务层，补回当前所选差异即可。
        let preservedBindingID = selectedBindingID
        let preservedReference = historyReference
        let preservedRevisionID = selectedRevisionID
        let preservedPath = selectedPath
        let operationWorkspace = workspace ?? Workspace(directory: binding.root, bindings: [binding], issues: [])
        operationTask = Task { [weak self, service] in
            do {
                let response = try await service.perform(kind, bindingID: binding.id, in: operationWorkspace) { progress in
                    await MainActor.run {
                        guard let self, self.operationToken == token else { return }
                        self.operationProgressMessage = progress.message
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
                self.isOperationCancelling = false
            } catch {
                guard let self, self.operationToken == token else { return }
                self.operationResult = RepositoryOperationResult(kind: kind, bindingID: binding.id, outcome: .failed, summary: "操作未完成", details: error.localizedDescription)
                self.operationProgressMessage = self.operationResult?.summary ?? "操作未完成"
                self.isOperationCancelling = false
            }
        }
    }

    private func applyOperationResponse(
        _ response: WorkspaceOperationResult,
        service: RepositoryService,
        preferredBindingID: String?,
        reference: String?,
        revisionID: String?,
        path: String?,
        token: Int
    ) async {
        guard operationToken == token else { return }
        workspace = response.workspace
        snapshots = Dictionary(uniqueKeysWithValues: response.snapshots.map { ($0.binding.id, $0) })
        await restoreSelectionAfterOperation(
            service: service,
            preferredBindingID: preferredBindingID,
            reference: reference,
            revisionID: revisionID,
            path: path,
            token: token
        )
        guard operationToken == token else { return }
        operationResult = response.result
        operationProgressMessage = response.result.summary
        isOperationCancelling = false
    }

    /// 取消并不回滚已由 Git/SVN 落地的步骤；仍等待服务层刷新真实状态。
    public func cancelOperation() {
        guard isOperationInProgress, !isOperationCancelling else { return }
        isOperationCancelling = true
        operationProgressMessage = "正在取消并核对工作区状态…"
        operationTask?.cancel()
    }

    public func dismissOperationResult() {
        guard !isOperationInProgress else { return }
        operationKind = nil
        operationBinding = nil
        operationProgressMessage = ""
        operationResult = nil
        isOperationCancelling = false
    }

    private func restoreSelectionAfterOperation(
        service: RepositoryService,
        preferredBindingID: String?,
        reference: String?,
        revisionID: String?,
        path: String?,
        token: Int
    ) async {
        guard let workspace else { return }
        let binding = workspace.bindings.first { $0.id == preferredBindingID } ?? workspace.bindings.first
        selectedBindingID = binding?.id
        historyReference = reference
        selectedRevisionID = revisionID
        selectedPath = path
        revisionFiles = []
        patch = nil
        guard let binding else { return }

        // service.perform 的全量快照采用默认历史范围。保留分支筛选时必须重新按该范围读取。
        do {
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
            } catch is CancellationError {
            } catch {
                guard self?.accepts(token) == true else { return }
                self?.isLoading = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}
