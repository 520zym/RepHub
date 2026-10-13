import Foundation

/// 单行最后一次受控修改的来源。`revision` 始终是固定提交，不能指向工作区的临时内容。
public struct RepositoryBlameLine: Identifiable, Hashable, Sendable {
    public let lineNumber: Int
    public let revision: Revision
    public let content: String

    public var id: Int { lineNumber }

    public init(lineNumber: Int, revision: Revision, content: String) {
        self.lineNumber = lineNumber
        self.revision = revision
        self.content = content
    }
}

public struct RepositoryBlame: Sendable {
    public let path: String
    public let reference: String
    public let lines: [RepositoryBlameLine]

    public init(path: String, reference: String, lines: [RepositoryBlameLine]) {
        self.path = path
        self.reference = reference
        self.lines = lines
    }
}

/// 全历史检索条件。条件均按 AND 组合；空条件等同浏览固定历史快照。
public struct RepositoryHistorySearchQuery: Hashable, Sendable {
    public let text: String
    public let author: String
    public let path: String
    public let fromDate: Date?
    public let toDate: Date?

    public init(text: String = "", author: String = "", path: String = "", fromDate: Date? = nil, toDate: Date? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fromDate = fromDate
        self.toDate = toDate
    }

    public var isEmpty: Bool {
        text.isEmpty && author.isEmpty && path.isEmpty && fromDate == nil && toDate == nil
    }

    public func matches(_ revision: Revision) -> Bool {
        let locale = Locale.current
        let contains: (String, String) -> Bool = { value, needle in
            value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale) != nil
        }
        guard text.isEmpty || contains(revision.message, text),
              author.isEmpty || contains(revision.author, author) else { return false }
        if let fromDate, revision.date < fromDate { return false }
        if let toDate, revision.date > toDate { return false }
        return true
    }
}

/// 应用层迭代适配器分页的搜索结果；游标是不透明值，只能传回服务层。
public struct RepositoryHistorySearchPage: Sendable {
    public let revisions: [Revision]
    public let nextCursor: String?
    public let scannedCount: Int
    public let isComplete: Bool

    public init(revisions: [Revision], nextCursor: String?, scannedCount: Int, isComplete: Bool) {
        self.revisions = revisions
        self.nextCursor = nextCursor
        self.scannedCount = scannedCount
        self.isComplete = isComplete
    }
}

/// 逐行追溯是可选读取能力；查询结果必须对应一个已提交修订，不对未跟踪内容虚构历史。
public protocol RepositoryInspectionProvider: VersionControlProvider {
    func blame(in binding: RepositoryBinding, path: String, reference: String?) async throws -> RepositoryBlame
}
