import Foundation

/// 按目标准备提交；指纹由适配器解释，界面不推断暂存区或工作副本语义。
public struct RepositoryCommitFile: Identifiable, Hashable, Sendable {
    public var id: String { change.path }
    public let change: FileChange
    public let fingerprint: String
    public let restriction: String?
    /// 适配器在准备提交时确认的节点类型；界面据此呈现目录的非递归提交语义。
    public let isDirectory: Bool
    public init(change: FileChange, fingerprint: String, restriction: String? = nil, isDirectory: Bool = false) {
        self.change = change; self.fingerprint = fingerprint; self.restriction = restriction; self.isDirectory = isDirectory
    }
}

public struct RepositoryCommitPreparation: Sendable {
    public let binding: RepositoryBinding
    public let baseRevision: String?
    public let files: [RepositoryCommitFile]
    public let notice: String
    public let blockingReason: String?
    public init(binding: RepositoryBinding, baseRevision: String?, files: [RepositoryCommitFile],
                notice: String = "", blockingReason: String? = nil) {
        self.binding = binding; self.baseRevision = baseRevision; self.files = files
        self.notice = notice; self.blockingReason = blockingReason
    }
}

public struct RepositoryCommitRequest: Sendable {
    public let bindingID: String
    public let baseRevision: String?
    public let files: [RepositoryCommitFile]
    public let message: String
    public init(bindingID: String, baseRevision: String?, files: [RepositoryCommitFile], message: String) {
        self.bindingID = bindingID; self.baseRevision = baseRevision; self.files = files; self.message = message
    }
}

public enum RepositoryCommitOutcome: String, Sendable {
    case succeeded, failed, cancelled, unknown, notStarted
}

public struct RepositoryCommitResult: Sendable {
    public let bindingID: String
    public let outcome: RepositoryCommitOutcome
    public let revisionID: String?
    public let summary: String
    public let details: String
    public let committedFiles: [FileChange]
    public init(bindingID: String, outcome: RepositoryCommitOutcome, revisionID: String? = nil,
                summary: String, details: String = "", committedFiles: [FileChange] = []) {
        self.bindingID = bindingID; self.outcome = outcome; self.revisionID = revisionID
        self.summary = summary; self.details = details; self.committedFiles = committedFiles
    }
}

public struct RepositoryCommitProgress: Sendable {
    public let bindingID: String
    public let progress: RepositoryOperationProgress
    public init(bindingID: String, progress: RepositoryOperationProgress) {
        self.bindingID = bindingID; self.progress = progress
    }
}

public typealias RepositoryCommitProgressHandler = @Sendable (RepositoryCommitProgress) async -> Void

/// 提交独立于获取和更新；Git 本地提交与 SVN 远端提交保留各自语义。
public protocol RepositoryCommitProvider: VersionControlProvider {
    func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation
    func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch
    func commit(_ request: RepositoryCommitRequest, in binding: RepositoryBinding,
                progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult
}
