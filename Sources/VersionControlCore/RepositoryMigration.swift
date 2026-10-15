import Foundation

public enum MigrationMode: String, CaseIterable, Sendable, Codable {
    case history, snapshot
    public var title: String { self == .history ? "保留可读取历史" : "仅迁移当前版本代码" }
}

public struct MigrationRevision: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let author: String
    public let date: Date
    public let message: String
    public init(id: String, author: String, date: Date, message: String) {
        self.id = id; self.author = author; self.date = date; self.message = message
    }
}

public struct MigrationAuthor: Sendable, Codable, Equatable {
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
}

/// 固定来源修订；revisions 按从旧到新排列，不允许静默截断。
public struct MigrationSourcePlan: Sendable {
    public let providerID: ProviderID
    public let location: RemoteRepositoryLocation
    public let anchor: String
    public let mode: MigrationMode
    public let revisions: [MigrationRevision]
    public let warnings: [String]
    public init(providerID: ProviderID, location: RemoteRepositoryLocation, anchor: String,
                mode: MigrationMode, revisions: [MigrationRevision], warnings: [String] = []) {
        self.providerID = providerID; self.location = location; self.anchor = anchor
        self.mode = mode; self.revisions = revisions; self.warnings = warnings
    }
}

/// 迁移独立于初始化与提交。来源适配器只读远端，导出到业务层创建的隔离路径。
public protocol RepositoryMigrationSourceProvider: Sendable {
    var id: ProviderID { get }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws
}

public enum MigrationPublicationState: String, Sendable, Codable { case published, notPublished, unknown }
public struct MigrationPublicationResult: Sendable {
    public let state: MigrationPublicationState
    public let message: String
    public init(state: MigrationPublicationState, message: String) { self.state = state; self.message = message }
}

/// 目标生成、只读核对与远端发布分别调用，预览不隐式发布。
public protocol RepositoryMigrationTargetProvider: Sendable {
    var id: ProviderID { get }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws
    func initializeMigration(at directory: URL, branch: String) async throws
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor,
                                 to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws
    /// 恢复前核对已验证的检查点；nil 表示必须仍是没有提交的空仓库。
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL,
                             progress: @escaping RepositoryOperationProgressHandler) async throws
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String,
                          progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult
}

public extension RepositoryMigrationTargetProvider {
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL,
                             progress: @escaping RepositoryOperationProgressHandler) async throws {
        await progress(RepositoryOperationProgress("正在读取 Git 对象树并核对转换内容…"))
        try await exportMigrationTree(at: directory, revision: revision, to: destination)
    }

    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {
        guard let expectedTip else { throw VersionControlError.unsupported("无法核对空迁移检查点，请返回重新预检。") }
        try await verifyMigration(at: directory, expectedTip: expectedTip, branch: branch)
    }
}

public struct MigrationPlan: Identifiable, Sendable {
    public let id: UUID
    public let source: MigrationSourcePlan
    public let targetProviderID: ProviderID
    public let remoteURL: String
    public let branch: String
    public let destination: URL
    public let authors: [String: MigrationAuthor]
    public init(id: UUID = UUID(), source: MigrationSourcePlan, targetProviderID: ProviderID,
                remoteURL: String, branch: String, destination: URL, authors: [String: MigrationAuthor]) {
        self.id = id; self.source = source; self.targetProviderID = targetProviderID
        self.remoteURL = remoteURL; self.branch = branch; self.destination = destination; self.authors = authors
    }
}

public struct MigrationMapping: Identifiable, Codable, Sendable {
    public var id: String { source.id }
    public let source: MigrationRevision
    public let author: MigrationAuthor
    public let targetCommit: String
    public init(source: MigrationRevision, author: MigrationAuthor, targetCommit: String) {
        self.source = source; self.author = author; self.targetCommit = targetCommit
    }
}

public struct MigrationFileEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let digest: String
    public let size: UInt64
    public let executable: Bool
    public init(path: String, kind: Kind, digest: String, size: UInt64, executable: Bool = false) {
        self.path = path; self.kind = kind; self.digest = digest; self.size = size; self.executable = executable
    }
}

public struct MigrationFileComparison: Identifiable, Sendable {
    public enum State: String, Sendable { case identical, omittedDirectory, different }
    public var id: String { path }
    public let path: String
    public let source: MigrationFileEntry?
    public let target: MigrationFileEntry?
    public let state: State
    public init(path: String, source: MigrationFileEntry?, target: MigrationFileEntry?, state: State) {
        self.path = path; self.source = source; self.target = target; self.state = state
    }
}

public struct MigrationPreview: Identifiable, Sendable {
    public var id: UUID { plan.id }
    public let plan: MigrationPlan
    public let repository: URL
    public let reportURL: URL
    public let mappings: [MigrationMapping]
    public let files: [MigrationFileComparison]
    public let warnings: [String]
    public var tip: String { mappings.last?.targetCommit ?? "" }
    public var canPublish: Bool { !tip.isEmpty && mappings.count == plan.source.revisions.count && !files.contains { $0.state == .different } }
    public init(plan: MigrationPlan, repository: URL, reportURL: URL, mappings: [MigrationMapping],
                files: [MigrationFileComparison], warnings: [String]) {
        self.plan = plan; self.repository = repository; self.reportURL = reportURL
        self.mappings = mappings; self.files = files; self.warnings = warnings
    }
}

public struct MigrationFilePreview: Sendable {
    public let sourceText: String
    public let targetText: String
    public let isBinary: Bool
    public let isTruncated: Bool
    public init(sourceText: String, targetText: String, isBinary: Bool, isTruncated: Bool) {
        self.sourceText = sourceText; self.targetText = targetText
        self.isBinary = isBinary; self.isTruncated = isTruncated
    }
}
