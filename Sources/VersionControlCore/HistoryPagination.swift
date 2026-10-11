import Foundation

/// 游标由具体适配器生成和验证；业务与界面仅保存、传回，不解析工具语义。
public struct HistoryPageRequest: Sendable {
    public let limit: Int
    public let reference: String?
    public let cursor: String?

    public init(limit: Int = 150, reference: String? = nil, cursor: String? = nil) {
        self.limit = limit
        self.reference = reference
        self.cursor = cursor
    }
}

public struct RepositoryHistoryPage: Sendable {
    public let revisions: [Revision]
    public let nextCursor: String?
    public init(revisions: [Revision], nextCursor: String? = nil) {
        self.revisions = revisions
        self.nextCursor = nextCursor
    }
}

public struct FileHistoryPage: Sendable {
    public let entries: [FileHistoryEntry]
    public let nextCursor: String?
    public init(entries: [FileHistoryEntry], nextCursor: String? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// 首次读取固定历史起点，后续页继续该次读取；刷新时丢弃游标并重新获取最新历史。
public protocol RepositoryHistoryPagingProvider: RepositoryHistoryProvider {
    func historyPage(in binding: RepositoryBinding, request: HistoryPageRequest) async throws -> RepositoryHistoryPage
    func fileHistoryPage(in binding: RepositoryBinding, path: String, request: HistoryPageRequest) async throws -> FileHistoryPage
}
