import VersionControlCore

/// 一页仓库历史及其同步摘要。`nextCursor` 为适配器不透明状态，仅可原样用于下一页。
public struct HistoryPageSnapshot: Sendable {
    public let revisions: [Revision]
    public let nextCursor: String?
    public let syncStatus: RepositorySyncStatus?
    public let issues: [String]

    public init(revisions: [Revision], nextCursor: String? = nil,
                syncStatus: RepositorySyncStatus? = nil, issues: [String] = []) {
        self.revisions = revisions
        self.nextCursor = nextCursor
        self.syncStatus = syncStatus
        self.issues = issues
    }
}
