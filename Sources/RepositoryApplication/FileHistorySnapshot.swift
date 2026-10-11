import VersionControlCore

public struct FileHistorySnapshot: Sendable {
    public let path: String
    public let entries: [FileHistoryEntry]
    /// 当前页之后的不透明游标；为空表示适配器没有更多已知记录。
    public let nextCursor: String?
    public let syncStatus: RepositorySyncStatus?
    public let issues: [String]
    public init(path: String, entries: [FileHistoryEntry], nextCursor: String? = nil,
                syncStatus: RepositorySyncStatus? = nil, issues: [String] = []) {
        self.path = path; self.entries = entries; self.nextCursor = nextCursor; self.syncStatus = syncStatus; self.issues = issues
    }
}
