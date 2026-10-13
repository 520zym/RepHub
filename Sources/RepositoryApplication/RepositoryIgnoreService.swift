import Foundation
import VersionControlCore

public extension RepositoryService {
    func prepareIgnore(in binding: RepositoryBinding) async throws -> RepositoryIgnorePreparation {
        let adapter = try ignoreProvider(for: binding)
        let current = try await checkedIgnoreBinding(binding, using: adapter)
        return try await adapter.prepareIgnore(in: current)
    }

    func previewIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding) async throws -> RepositoryIgnorePreview {
        let adapter = try ignoreProvider(for: binding)
        let current = try await checkedIgnoreBinding(binding, using: adapter)
        guard request.bindingID == current.id else { throw VersionControlError.invalidRepository("忽略规则请求与当前工作副本不一致。") }
        return try await adapter.previewIgnore(request, in: current)
    }

    /// 忽略规则会修改工作副本元数据，因此与其他写操作共享服务锁；不会创建版本提交。
    func applyIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding,
                     progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryIgnoreResult {
        guard !isPerformingOperation else { throw VersionControlError.unsupported("已有仓库操作正在执行，请等待完成或取消后的状态核对结束。") }
        // actor 在 await 时可重入，必须先占用全局写操作锁，再做任何适配器探测。
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        let adapter = try ignoreProvider(for: binding)
        let current = try await checkedIgnoreBinding(binding, using: adapter)
        guard request.bindingID == current.id else { throw VersionControlError.invalidRepository("忽略规则请求与当前工作副本不一致。") }
        return try await adapter.applyIgnore(request, in: current, progress: progress)
    }

    private func ignoreProvider(for binding: RepositoryBinding) throws -> any RepositoryIgnoreProvider {
        guard let adapter = try provider(for: binding) as? any RepositoryIgnoreProvider else {
            throw VersionControlError.unsupported("当前版本控制来源不支持添加忽略规则。")
        }
        return adapter
    }

    private func checkedIgnoreBinding(_ requested: RepositoryBinding,
                                      using adapter: any RepositoryIgnoreProvider) async throws -> RepositoryBinding {
        guard let current = try await adapter.detect(at: requested.root), current.id == requested.id,
              current.currentBranch == requested.currentBranch, current.remoteURL == requested.remoteURL else {
            throw VersionControlError.invalidRepository("工作副本状态已变化，请重新打开后再修改忽略规则。")
        }
        return current
    }
}
