import Foundation
import VersionControlCore

public extension RepositoryService {
    /// 读取部分提交候选。真正写入只会由 `commitPartial` 取得全局仓库操作锁。
    func preparePartialCommit(in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreparation {
        let adapter = try partialCommitProvider(for: binding)
        let current = try await checkedPartialBinding(binding, using: adapter)
        return try await adapter.preparePartialCommit(in: current)
    }

    func previewPartialCommit(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding) async throws -> RepositoryPartialCommitPreview {
        let adapter = try partialCommitProvider(for: binding)
        let current = try await checkedPartialBinding(binding, using: adapter)
        guard request.bindingID == current.id else { throw VersionControlError.invalidRepository("部分提交请求与当前工作副本不一致。") }
        return try await adapter.previewPartialCommit(request, in: current)
    }

    /// 使用与更新、普通提交相同的全局操作锁。适配器仍须在写入前自行复核 source/index 状态。
    func commitPartial(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.commitPartialUnlocked(request, in: binding, progress: progress)
        }
    }

    private func commitPartialUnlocked(_ request: RepositoryPartialCommitRequest, in binding: RepositoryBinding,
                                       progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。") }
        // actor 在 await 时可重入，必须先占用全局写操作锁，再做任何适配器探测。
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        let adapter = try partialCommitProvider(for: binding)
        let current = try await checkedPartialBinding(binding, using: adapter)
        guard request.bindingID == current.id else { throw VersionControlError.invalidRepository("部分提交请求与当前工作副本不一致。") }
        return try await adapter.commitPartial(request, in: current, progress: progress)
    }

    private func partialCommitProvider(for binding: RepositoryBinding) throws -> any RepositoryPartialCommitProvider {
        guard let adapter = try provider(for: binding) as? any RepositoryPartialCommitProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持按块或按行提交。")
        }
        return adapter
    }

    private func checkedPartialBinding(_ requested: RepositoryBinding,
                                       using adapter: any RepositoryPartialCommitProvider) async throws -> RepositoryBinding {
        guard let current = try await adapter.detect(at: requested.root), current.id == requested.id,
              current.currentBranch == requested.currentBranch, current.remoteURL == requested.remoteURL else {
            throw VersionControlError.invalidRepository("工作副本状态已变化，请重新打开后再执行部分提交。")
        }
        return current
    }
}
