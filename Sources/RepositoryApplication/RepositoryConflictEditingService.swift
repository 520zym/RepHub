import Foundation
import VersionControlCore

/// 冲突编辑的写入结果必须携带重新识别后的全部工作区，供调用方一次性刷新界面。
public struct WorkspaceConflictResolutionResult: Sendable {
    public let result: RepositoryConflictResolutionResult
    public let workspace: Workspace
    public let snapshots: [BindingSnapshot]

    public init(result: RepositoryConflictResolutionResult, workspace: Workspace, snapshots: [BindingSnapshot]) {
        self.result = result
        self.workspace = workspace
        self.snapshots = snapshots
    }
}

public extension RepositoryService {
    func contentConflict(in binding: RepositoryBinding, path: String) async throws -> RepositoryContentConflict {
        guard binding.capabilities.contains(.conflictResolution),
              let provider = try provider(for: binding) as? any RepositoryConflictEditingProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持内置冲突编辑。")
        }
        guard let current = try await provider.detect(at: binding.root), current.id == binding.id,
              current.currentBranch == binding.currentBranch, current.remoteURL == binding.remoteURL else {
            throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新打开冲突。")
        }
        let conflict = try await provider.contentConflict(in: current, path: path)
        guard conflict.binding.id == current.id, conflict.path == path else {
            throw VersionControlError.invalidData("版本控制适配器返回了不属于当前冲突的内容。")
        }
        return conflict
    }

    /// 保存由服务统一加锁；适配器仍会在实际写入前复核自身冲突令牌和文件内容。
    func resolveContentConflict(_ request: RepositoryConflictResolutionRequest,
                                bindingID: String,
                                in workspace: Workspace) async throws -> WorkspaceConflictResolutionResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.resolveContentConflictUnlocked(request, bindingID: bindingID, in: workspace)
        }
    }

    private func resolveContentConflictUnlocked(_ request: RepositoryConflictResolutionRequest,
                                                bindingID: String,
                                                in workspace: Workspace) async throws -> WorkspaceConflictResolutionResult {
        guard !isPerformingOperation else {
            throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。")
        }
        guard let binding = workspace.bindings.first(where: { $0.id == bindingID }),
              binding.capabilities.contains(.conflictResolution),
              let provider = try provider(for: binding) as? any RepositoryConflictEditingProvider else {
            throw VersionControlError.unsupported("所选版本控制来源不支持内置冲突编辑。")
        }
        try validateManagedPath(request.path)
        guard !request.stateToken.isEmpty, request.content.utf8.count <= 4 * 1024 * 1024 else {
            throw VersionControlError.invalidData("冲突编辑请求无效，请重新打开冲突文件。")
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }

        let result: RepositoryConflictResolutionResult
        var didStart = false
        do {
            try Task.checkCancellation()
            guard let current = try await provider.detect(at: binding.root), current.id == binding.id,
                  current.currentBranch == binding.currentBranch, current.remoteURL == binding.remoteURL else {
                throw VersionControlError.invalidRepository("仓库位置、分支或远端已经改变，请刷新后重新打开冲突。")
            }
            didStart = true
            result = try await provider.resolveContentConflict(request, in: current)
        } catch is CancellationError {
            result = RepositoryConflictResolutionResult(
                outcome: didStart ? .unknown : .cancelled,
                summary: didStart ? "冲突保存结果需要核对。" : "冲突保存已取消。",
                details: didStart ? "保存可能已开始，请根据刷新后的工作区状态核对，勿直接重复执行。" : "取消不会自动回滚已经写入的最终内容。"
            )
        } catch {
            result = RepositoryConflictResolutionResult(
                outcome: didStart ? .unknown : .failed,
                summary: didStart ? "冲突保存结果需要核对。" : "冲突保存未完成。",
                details: RepositoryDisplaySanitizer.redact(error.localizedDescription)
            )
        }
        let refreshed = await refreshAfterConflictResolution(workspace)
        return WorkspaceConflictResolutionResult(result: sanitizedConflictResult(result), workspace: refreshed.workspace, snapshots: refreshed.snapshots)
    }
}

private extension RepositoryService {
    func refreshAfterConflictResolution(_ previous: Workspace) async -> (workspace: Workspace, snapshots: [BindingSnapshot]) {
        let workspace: Workspace
        do { workspace = try await open(directory: previous.directory, linkedDirectories: previous.linkedDirectories) }
        catch {
            workspace = Workspace(directory: previous.directory, linkedDirectories: previous.linkedDirectories,
                                  bindings: previous.bindings,
                                  issues: ["冲突保存后无法重新识别工作区：\(RepositoryDisplaySanitizer.redact(error.localizedDescription))"])
        }
        var snapshots: [BindingSnapshot] = []
        for binding in workspace.bindings { snapshots.append(await load(binding)) }
        return (workspace, snapshots)
    }

    func sanitizedConflictResult(_ result: RepositoryConflictResolutionResult) -> RepositoryConflictResolutionResult {
        RepositoryConflictResolutionResult(outcome: result.outcome,
                                           summary: RepositoryDisplaySanitizer.redact(result.summary),
                                           details: RepositoryDisplaySanitizer.redact(result.details))
    }
}
