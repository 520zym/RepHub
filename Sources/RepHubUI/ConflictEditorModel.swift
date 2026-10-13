import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 内置冲突编辑器的短生命周期状态；只接收抽象的三份文本，不了解 Git index 或 SVN 文件名。
@MainActor
@Observable
public final class ConflictEditorModel {
    public enum Phase: Equatable { case loading, ready, saving, finished, failed }

    public private(set) var phase: Phase = .loading
    public private(set) var conflict: RepositoryContentConflict?
    public private(set) var blocks: [RepositoryConflictBlock] = []
    public var finalText = ""
    public private(set) var message: String?
    public private(set) var result: WorkspaceConflictResolutionResult?
    public var canSave: Bool { phase == .ready && !RepositoryConflictTextResolver.containsMarkers(in: finalText) }
    public var isBusy: Bool { phase == .loading || phase == .saving }

    private let service: RepositoryService
    private let binding: RepositoryBinding
    private let path: String
    private let workspace: Workspace?
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(service: RepositoryService, binding: RepositoryBinding, path: String, workspace: Workspace? = nil) {
        self.service = service
        self.binding = binding
        self.path = path
        self.workspace = workspace
    }

    isolated deinit { task?.cancel() }

    public func load() {
        generation += 1
        let token = generation
        task?.cancel()
        phase = .loading
        message = nil
        result = nil
        task = Task { [weak self, service, binding, path] in
            do {
                let conflict = try await service.contentConflict(in: binding, path: path)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.conflict = conflict
                self.finalText = conflict.working
                self.blocks = RepositoryConflictTextResolver.blocks(in: conflict.working)
                self.phase = .ready
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.message = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    public func apply(_ choice: RepositoryConflictChoice, to block: RepositoryConflictBlock) {
        guard phase == .ready else { return }
        finalText = RepositoryConflictTextResolver.applying(choice, to: block.id, in: finalText)
        blocks = RepositoryConflictTextResolver.blocks(in: finalText)
    }

    public func save(completed: @escaping @MainActor @Sendable (WorkspaceConflictResolutionResult) -> Void) {
        guard canSave, let conflict else { return }
        generation += 1
        let token = generation
        task?.cancel()
        phase = .saving
        message = nil
        let workspace = self.workspace ?? Workspace(directory: binding.root, bindings: [binding], issues: [])
        let request = RepositoryConflictResolutionRequest(path: conflict.path, stateToken: conflict.stateToken, content: finalText)
        task = Task { [weak self, service, binding] in
            do {
                let response = try await service.resolveContentConflict(request, bindingID: binding.id, in: workspace)
                guard let self, self.generation == token else { return }
                self.result = response
                self.message = response.result.summary
                self.phase = response.result.outcome == .succeeded ? .finished : .failed
                completed(response)
            } catch is CancellationError {
                guard let self, self.generation == token else { return }
                self.message = "保存已取消，请刷新工作区确认状态。"
                self.phase = .failed
            } catch {
                guard let self, self.generation == token else { return }
                self.message = error.localizedDescription
                self.phase = .failed
            }
        }
    }
}
