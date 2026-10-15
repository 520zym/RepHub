import Foundation

/// 可选的批次导入能力。只服务于业务层创建的隔离目标仓库，不接触原工作副本。
public protocol RepositoryVerifiedMigrationTargetProvider: RepositoryMigrationTargetProvider {
    func makeVerifiedMigrationSession(at repository: URL) async throws -> any RepositoryVerifiedMigrationSession
}

/// 一个会话内复用已验证的不可变对象，避免每个修订反复导出未变化的内容。
/// append 返回前必须核对全部路径、类型、执行位及对象内容，并保持目标工作树干净。
/// files 是业务层对本次 source 快照读取实际字节生成的清单；目录可由目标忽略。
/// 调用失败后会话不可继续使用。完成后业务层仍执行一次完整导出与逐文件核对。
public protocol RepositoryVerifiedMigrationSession: Sendable {
    func appendVerifiedSnapshot(from snapshot: URL, files: [MigrationFileEntry],
                                revision: MigrationRevision, author: MigrationAuthor,
                                progress: @escaping RepositoryOperationProgressHandler) async throws -> String
}
