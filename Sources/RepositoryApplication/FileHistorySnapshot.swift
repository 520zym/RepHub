import VersionControlCore

public struct FileHistorySnapshot: Sendable {
    public let path: String
    public let entries: [FileHistoryEntry]
    public let syncStatus: RepositorySyncStatus?
    public let issues: [String]
    public init(path: String, entries: [FileHistoryEntry], syncStatus: RepositorySyncStatus? = nil, issues: [String] = []) {
        self.path = path; self.entries = entries; self.syncStatus = syncStatus; self.issues = issues
    }
}
