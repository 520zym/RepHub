import Foundation

public enum WorkingCopyMigrationAction: String, Sendable, Codable {
    case initial, supplement
    public var title: String { self == .initial ? "迁入空 Git 仓库" : "补迁 SVN 新提交" }
}

public struct MigrationWorkingCopyInfo: Sendable, Equatable {
    public let directory: URL
    public let sourceURL: String
    public let repositoryUUID: String
    public let baseRevision: String
    public init(directory: URL, sourceURL: String, repositoryUUID: String, baseRevision: String) {
        self.directory = directory; self.sourceURL = sourceURL
        self.repositoryUUID = repositoryUUID; self.baseRevision = baseRevision
    }
}

/// 当前目录模式仍只读取 SVN；补迁不更新或提交 SVN 工作副本。
public protocol RepositoryWorkingCopyMigrationSourceProvider: RepositoryMigrationSourceProvider {
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo
    /// 在预检、准备与应用前按固定修订复核 URL 和仓库 UUID，防止同地址被替换为另一仓库。
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation,
                                          repositoryUUID: String, revision: String) async throws
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode,
                                through revision: String?, after previousRevision: String?,
                                progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan
}

/// 保存到本地 Git 元数据，修订来源同时写入每个迁移提交，不能靠说明相似度去重。
public struct WorkingCopyMigrationRecord: Codable, Sendable {
    public let version: Int
    public let sourceURL: String
    public let repositoryUUID: String
    public let startRevision: String
    public let cutoverRevision: String
    public let lastRevision: String
    public let remoteURL: String
    public let branch: String
    public let mappings: [MigrationMapping]
    public init(sourceURL: String, repositoryUUID: String, startRevision: String, lastRevision: String,
                remoteURL: String, branch: String, mappings: [MigrationMapping], cutoverRevision: String? = nil) {
        version = 1; self.sourceURL = sourceURL; self.repositoryUUID = repositoryUUID
        self.startRevision = startRevision; self.lastRevision = lastRevision
        self.cutoverRevision = cutoverRevision ?? lastRevision
        self.remoteURL = remoteURL; self.branch = branch; self.mappings = mappings
    }
}

public protocol RepositoryWorkingCopyMigrationTargetProvider: RepositoryMigrationTargetProvider {
    /// 对照实际 Git 提交来源，避免本地记录损坏后跳过未迁移的 SVN 修订。
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws
    /// nil 表示必须未被 Git 管理；非 nil 表示必须仍在指定的干净分支及提交。
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String?
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws
    /// 把 SVN 前后两版的差异三方应用到隔离 Git 结果，不能用 SVN 全树覆盖 Git 新修改。
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor,
                                         to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String
    /// 仅在用户确认预览后调用。首次只安装 .git；补迁仅快进到预览结果并保留 .svn。
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String,
                                   branch: String, record: Data) async throws
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String,
                                     expectedBeforeTip: String?, expectedTip: String,
                                     progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult
}

public struct WorkingCopyMigrationPlan: Identifiable, Sendable {
    public let id: UUID
    public let action: WorkingCopyMigrationAction
    public let workingCopy: MigrationWorkingCopyInfo
    public let source: MigrationSourcePlan
    public let remoteURL: String
    public let branch: String
    public let expectedGitTip: String?
    public let previousRecord: WorkingCopyMigrationRecord?
    public var authors: [String: MigrationAuthor]
    public init(id: UUID = UUID(), action: WorkingCopyMigrationAction, workingCopy: MigrationWorkingCopyInfo,
                source: MigrationSourcePlan, remoteURL: String, branch: String, expectedGitTip: String?,
                previousRecord: WorkingCopyMigrationRecord?, authors: [String: MigrationAuthor]) {
        self.id = id; self.action = action; self.workingCopy = workingCopy; self.source = source
        self.remoteURL = remoteURL; self.branch = branch; self.expectedGitTip = expectedGitTip
        self.previousRecord = previousRecord; self.authors = authors
    }
}

public struct WorkingCopyMigrationPreview: Identifiable, Sendable {
    public var id: UUID { plan.id }
    public let plan: WorkingCopyMigrationPlan
    public let repository: URL
    public let mappings: [MigrationMapping]
    public let files: [MigrationFileComparison]
    public let warnings: [String]
    public var tip: String { mappings.last?.targetCommit ?? "" }
    public init(plan: WorkingCopyMigrationPlan, repository: URL, mappings: [MigrationMapping],
                files: [MigrationFileComparison], warnings: [String]) {
        self.plan = plan; self.repository = repository; self.mappings = mappings; self.files = files; self.warnings = warnings
    }
}

public struct WorkingCopyMigrationResult: Sendable {
    public let directory: URL
    public let publication: MigrationPublicationResult
    public init(directory: URL, publication: MigrationPublicationResult) { self.directory = directory; self.publication = publication }
}
