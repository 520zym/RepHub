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
    public var selectedPath: String?
    public var selectedRevisionID: String?
    public private(set) var revisionFiles: [FileChange] = []
    public private(set) var patch: RepositoryPatch?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

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
            if let binding = workspace.bindings.first {
                try await self.load(binding: binding, reference: nil, token: token)
            }
        }
    }

    public func refresh() {
        guard let binding = selectedBinding else { return }
        selectedRevisionID = nil
        revisionFiles = []
        selectedPath = nil
        patch = nil
        start { [weak self] token in
            guard let self else { return }
            try await self.load(binding: binding, reference: nil, token: token)
        }
    }

    public func selectBinding(_ binding: RepositoryBinding) {
        guard selectedBindingID != binding.id else { return }
        selectedBindingID = binding.id
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
            let files = try await self.service.changedFiles(in: binding, revision: revision.id)
            guard self.accepts(token), self.selectedBindingID == binding.id, self.selectedRevisionID == revision.id else { return }
            let patch = try await self.service.diff(in: binding, path: nil, revision: revision.id)
            guard self.accepts(token), self.selectedBindingID == binding.id, self.selectedRevisionID == revision.id else { return }
            self.revisionFiles = files
            self.patch = patch
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

    private func load(binding: RepositoryBinding, reference: String?, token: Int) async throws {
        let snapshot = await service.load(binding, reference: reference)
        guard accepts(token), selectedBindingID == binding.id else { return }
        snapshots[binding.id] = snapshot
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
