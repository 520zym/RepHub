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

    private let service: RepositoryService
    private var workTask: Task<Void, Never>?
    private var requestToken = 0

    public init(service: RepositoryService) {
        self.service = service
    }

    isolated deinit { workTask?.cancel() }

    public func chooseFolder() {
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
        guard isHistoryVisible != visible else { return }
        isHistoryVisible = visible

        if visible {
            selectRevision(snapshot?.revisions.first)
        } else {
            selectChange(preferredFile(in: snapshot?.changes ?? []))
        }
    }

    public func selectBinding(_ binding: RepositoryBinding) {
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
        selectedPath = change?.path
        selectedRevisionID = nil
        revisionFiles = []
        patch = nil
        loadPatch()
    }

    public func selectRevision(_ revision: Revision?) {
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
