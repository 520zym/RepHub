import Foundation

public enum RepositoryManagementOutcome: Sendable, Equatable {
    case succeeded, conflicts, failed, cancelled, unknown
}

public struct RepositoryRemote: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let url: String
    public let pushURL: String?
    public init(name: String, url: String, pushURL: String? = nil) {
        self.name = name; self.url = url; self.pushURL = pushURL
    }
}

public struct RepositoryConflict: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let detail: String
    public let canMarkResolved: Bool
    public init(path: String, detail: String, canMarkResolved: Bool = true) {
        self.path = path; self.detail = detail; self.canMarkResolved = canMarkResolved
    }
}

/// 适配器提供可操作的真实状态；token 仅用于执行前复核，界面不可解析。
public struct RepositoryManagementContext: Sendable {
    public let binding: RepositoryBinding
    public let stateToken: String
    public let headRevision: String?
    public let remotes: [RepositoryRemote]
    public let branches: [BranchReference]
    public let changes: [FileChange]
    public let conflicts: [RepositoryConflict]
    public let canFinishMerge: Bool
    public let authorName: String?
    public let authorEmail: String?
    public init(binding: RepositoryBinding, stateToken: String, headRevision: String? = nil,
                remotes: [RepositoryRemote] = [], branches: [BranchReference] = [], changes: [FileChange] = [],
                conflicts: [RepositoryConflict] = [], canFinishMerge: Bool = false,
                authorName: String? = nil, authorEmail: String? = nil) {
        self.binding = binding; self.stateToken = stateToken; self.headRevision = headRevision
        self.remotes = remotes; self.branches = branches; self.changes = changes
        self.conflicts = conflicts; self.canFinishMerge = canFinishMerge
        self.authorName = authorName; self.authorEmail = authorEmail
    }
}

public enum RepositoryManagementAction: Sendable {
    case setRemote(name: String, url: String)
    case setIdentity(name: String, email: String)
    case push(remote: String, branch: String, setUpstream: Bool)
    case stage(paths: [String])
    case unstage(paths: [String])
    case createBranch(name: String, startPoint: String)
    case switchBranch(name: String)
    case merge(reference: String)
    case finishMerge(message: String)
    /// 用户在外部编辑器中解决内容后，复核并记录解决状态；不自动选边覆盖内容。
    case markResolved(paths: [String])

    public var title: String {
        switch self {
        case .setRemote: "配置远端"
        case .setIdentity: "设置提交身份"
        case .push: "推送提交"
        case .stage: "暂存文件"
        case .unstage: "取消暂存"
        case .createBranch: "创建分支"
        case .switchBranch: "切换分支"
        case .merge: "合并分支"
        case .finishMerge: "完成合并提交"
        case .markResolved: "标记冲突已解决"
        }
    }
    public var capability: RepositoryCapabilities {
        switch self {
        case .push, .setRemote: .push
        case .setIdentity: .staging
        case .stage, .unstage: .staging
        case .createBranch, .switchBranch, .merge, .finishMerge: .branchManagement
        case .markResolved: .conflictResolution
        }
    }
}

public struct RepositoryManagementRequest: Sendable {
    public let action: RepositoryManagementAction
    public let stateToken: String
    public init(action: RepositoryManagementAction, stateToken: String) {
        self.action = action; self.stateToken = stateToken
    }
}

public struct RepositoryManagementResult: Sendable {
    public let outcome: RepositoryManagementOutcome
    public let summary: String
    public let details: String
    public init(outcome: RepositoryManagementOutcome, summary: String, details: String = "") {
        self.outcome = outcome; self.summary = summary; self.details = details
    }
}

public protocol RepositoryManagementProvider: VersionControlProvider {
    func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext
    func performManagement(_ request: RepositoryManagementRequest, in binding: RepositoryBinding,
                           progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryManagementResult
    func stagedDiff(in binding: RepositoryBinding, path: String) async throws -> RepositoryPatch
}

public extension RepositoryManagementProvider {
    func stagedDiff(in binding: RepositoryBinding, path: String) async throws -> RepositoryPatch {
        throw VersionControlError.unsupported("当前来源没有独立暂存区。")
    }
}

public struct RepositoryComparison: Sendable {
    public let fromRevision: String
    public let toRevision: String
    public let files: [FileChange]
    public init(fromRevision: String, toRevision: String, files: [FileChange]) {
        self.fromRevision = fromRevision; self.toRevision = toRevision; self.files = files
    }
}

public protocol RepositoryComparisonProvider: VersionControlProvider {
    func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison
    func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison, path: String) async throws -> RepositoryPatch
}
