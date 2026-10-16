import Foundation
import VersionControlCore

/// 应用内所有会写入真实工作副本、最终目标或远端的操作共用的门禁。
///
/// 隔离目录中的转换预览不经过此门禁；预览完成后把结果移动到用户指定的最终
/// 目录，以及后续发布，仍必须经过门禁。这里刻意不排队：等待中的预检、分支和
/// 工作区状态都可能已经失效，调用方应在当前操作结束后重新读取。
public actor RepositoryWriteGate {
    private var owner: UUID?

    public init() {}

    /// 在持有期间运行一次真实写操作。无论正常返回、抛错或任务取消，门禁都会释放。
    public func withExclusiveAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard owner == nil else {
            throw VersionControlError.unsupported("另一窗口正在执行仓库写操作，请等待其结束后重新核对。")
        }
        let lease = UUID()
        owner = lease
        do {
            let result = try await operation()
            release(lease)
            return result
        } catch {
            release(lease)
            throw error
        }
    }

    private func release(_ lease: UUID) {
        guard owner == lease else { return }
        owner = nil
    }
}
