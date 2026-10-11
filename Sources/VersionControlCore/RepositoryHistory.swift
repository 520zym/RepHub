import Foundation

/// 文件历史携带该修订的路径及可选追溯锚点，避免重命名前后的差异指向错误文件。
public struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { revision.id }
    public let revision: Revision
    public let path: String
    public let pegRevision: String?
    public init(revision: Revision, path: String, pegRevision: String? = nil) {
        self.revision = revision; self.path = path; self.pegRevision = pegRevision
    }
}

public enum RevisionSyncState: String, Sendable {
    case incoming, outgoing, synchronized, uncertain
    public var title: String {
        switch self {
        case .incoming: "待更新"
        case .outgoing: "待推送"
        case .synchronized: "已同步"
        case .uncertain: "需核对"
        }
    }
}

/// Git 计数针对当前分支及其上游；SVN 计数和判断范围由说明明确表达。
public struct RepositorySyncStatus: Sendable {
    public let incomingCount: Int?
    public let outgoingCount: Int?
    public let states: [String: RevisionSyncState]
    public let summary: String
    public let detail: String
    public let checkedAt: Date
    public init(incomingCount: Int? = nil, outgoingCount: Int? = nil,
                states: [String: RevisionSyncState] = [:], summary: String, detail: String = "", checkedAt: Date = Date()) {
        self.incomingCount = incomingCount; self.outgoingCount = outgoingCount
        self.states = states; self.summary = summary; self.detail = detail; self.checkedAt = checkedAt
    }
}

/// 可选的历史扩展能力；业务与界面不依赖具体版本控制工具。
public protocol RepositoryHistoryProvider: VersionControlProvider {
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry]
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus
}
