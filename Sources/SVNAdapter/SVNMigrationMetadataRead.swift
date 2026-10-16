import Foundation
import ToolExecution
import VersionControlCore

/// 仅用于固定修订的只读元数据查询；不会重放检出、切换或任何提交操作。
enum SVNMigrationMetadataRead {
    static let timeout: TimeInterval = 120

    static func run(
        revision: Int,
        progress: @escaping RepositoryOperationProgressHandler,
        operation: @Sendable () async throws -> CommandResult
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch VersionControlError.timedOut {
            try Task.checkCancellation()
            await progress(RepositoryOperationProgress(
                "重新查询 SVN 历史节点 · r\(revision)",
                detail: "只读查询超过 \(Int(timeout)) 秒，正在自动重试一次；已转换的提交仍保留。"
            ))
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
