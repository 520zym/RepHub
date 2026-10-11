import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("仓库历史分页业务编排")
struct RepositoryHistoryPaginationServiceTests {
    @Test("仓库历史页按原样传递范围和游标，并保留同步摘要")
    func passesRepositoryPageRequest() async throws {
        let log = PageInvocationLog()
        let provider = PagingFixture(log: log)
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))

        let first = try await service.historyPage(in: binding, reference: "feature/demo")
        #expect(first.revisions.map(\.id) == ["new"])
        #expect(first.nextCursor == "cursor-2")
        #expect(first.syncStatus?.summary == "同步完成")
        #expect(await log.historyRequests() == [.init(reference: "feature/demo", cursor: nil, limit: 150)])

        let second = try await service.historyPage(in: binding, reference: "feature/demo", cursor: first.nextCursor)
        #expect(second.revisions.map(\.id) == ["old"])
        #expect(second.nextCursor == nil)
        #expect(await log.historyRequests() == [
            .init(reference: "feature/demo", cursor: nil, limit: 150),
            .init(reference: "feature/demo", cursor: "cursor-2", limit: 150),
        ])

        let secondWithLoaded = try await service.historyPage(
            in: binding, reference: "feature/demo", cursor: first.nextCursor, loadedRevisions: first.revisions
        )
        #expect(secondWithLoaded.revisions.map(\.id) == ["old"])
        #expect(await log.synchronizationRevisionIDs().last == ["new", "old"])
    }

    @Test("首页快照使用分页适配器且不重复查询同步状态")
    func loadUsesFirstPageOnce() async throws {
        let log = PageInvocationLog()
        let provider = PagingFixture(log: log)
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))

        let snapshot = await service.load(binding, reference: "release")

        #expect(snapshot.revisions.map(\.id) == ["new"])
        #expect(snapshot.nextHistoryCursor == "cursor-2")
        #expect(snapshot.syncStatus?.summary == "同步完成")
        #expect(await log.historyRequests() == [.init(reference: "release", cursor: nil, limit: 150)])
        #expect(await log.synchronizationCalls() == 1)
    }

    @Test("文件历史分页传递路径、范围和游标")
    func passesFilePageRequest() async throws {
        let log = PageInvocationLog()
        let provider = PagingFixture(log: log)
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))

        let page = try await service.fileHistory(in: binding, path: "Sources/App.swift", reference: "r30", cursor: "file-2")

        #expect(page.entries.map(\.revision.id) == ["file-old"])
        #expect(page.nextCursor == nil)
        #expect(await log.fileRequests() == [.init(path: "Sources/App.swift", reference: "r30", cursor: "file-2", limit: 150)])
    }

    @Test("旧适配器仍可读取首页，续页明确说明不支持")
    func legacyProviderFallsBackOnlyForFirstPage() async throws {
        let provider = LegacyHistoryFixture()
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))

        let first = try await service.historyPage(in: binding, reference: "main")
        #expect(first.revisions.map(\.id) == ["legacy"])
        #expect(first.nextCursor == nil)
        await #expect(throws: VersionControlError.self) {
            try await service.historyPage(in: binding, reference: "main", cursor: "older")
        }

        let file = try await service.fileHistory(in: binding, path: "README.md")
        #expect(file.entries.map(\.revision.id) == ["legacy-file"])
        await #expect(throws: VersionControlError.self) {
            try await service.fileHistory(in: binding, path: "README.md", cursor: "older")
        }
    }

    @Test("同步失败不吞掉已经读取成功的历史页")
    func synchronizationFailureDoesNotDiscardPage() async throws {
        let provider = PagingFixture(failsSynchronization: true)
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))

        let page = try await service.historyPage(in: binding)

        #expect(page.revisions.map(\.id) == ["new"])
        #expect(page.nextCursor == "cursor-2")
        #expect(page.syncStatus == nil)
        #expect(page.issues.count == 1)
        #expect(!page.issues[0].contains("secret"))
    }

    @Test("取消分页读取不会返回部分页面")
    func cancellationStopsPageRead() async throws {
        let provider = PagingFixture(delay: .milliseconds(200))
        let service = RepositoryService(providers: [provider])
        let binding = try #require(await provider.detect(at: FileManager.default.temporaryDirectory))
        let task = Task { try await service.historyPage(in: binding) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private struct PagingFixture: RepositoryHistoryPagingProvider {
    let id = ProviderID(rawValue: "paging-fixture")
    let displayName = "分页测试"
    let log: PageInvocationLog
    let failsSynchronization: Bool
    let delay: Duration?

    init(log: PageInvocationLog = PageInvocationLog(), failsSynchronization: Bool = false, delay: Duration? = nil) {
        self.log = log
        self.failsSynchronization = failsSynchronization
        self.delay = delay
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        .init(providerID: id, providerName: displayName, root: directory,
              capabilities: [.history, .fileHistory, .synchronization])
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] { [] }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch { .init(text: "") }

    func historyPage(in binding: RepositoryBinding, request: HistoryPageRequest) async throws -> RepositoryHistoryPage {
        await log.recordHistory(request)
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if request.cursor == nil {
            return .init(revisions: [.init(id: "new", author: "zym", date: .distantPast, message: "new")], nextCursor: "cursor-2")
        }
        return .init(revisions: [.init(id: "old", author: "zym", date: .distantPast, message: "old")])
    }

    func fileHistoryPage(in binding: RepositoryBinding, path: String, request: HistoryPageRequest) async throws -> FileHistoryPage {
        await log.recordFile(path: path, request: request)
        let id = request.cursor == nil ? "file-new" : "file-old"
        return .init(entries: [.init(revision: .init(id: id, author: "zym", date: .distantPast, message: id), path: path)],
                     nextCursor: request.cursor == nil ? "file-2" : nil)
    }

    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        await log.recordSynchronization(revisions.map(\.id))
        if failsSynchronization {
            throw VersionControlError.executionFailed("https://user:secret@example.invalid/history")
        }
        return .init(summary: "同步完成")
    }
}

private struct LegacyHistoryFixture: RepositoryHistoryProvider {
    let id = ProviderID(rawValue: "legacy-history-fixture")
    let displayName = "旧历史测试"

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        .init(providerID: id, providerName: displayName, root: directory, capabilities: [.history, .fileHistory])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        [.init(id: "legacy", author: "", date: .distantPast, message: "legacy")]
    }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] {
        [.init(revision: .init(id: "legacy-file", author: "", date: .distantPast, message: "legacy"), path: path)]
    }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch { .init(text: "") }
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus { .init(summary: "") }
}

private actor PageInvocationLog {
    struct HistoryRequest: Equatable, Sendable {
        let reference: String?
        let cursor: String?
        let limit: Int
    }
    struct FileRequest: Equatable, Sendable {
        let path: String
        let reference: String?
        let cursor: String?
        let limit: Int
    }

    private var history: [HistoryRequest] = []
    private var file: [FileRequest] = []
    private var synchronizationRevisionHistory: [[String]] = []

    func recordHistory(_ request: HistoryPageRequest) {
        history.append(.init(reference: request.reference, cursor: request.cursor, limit: request.limit))
    }
    func recordFile(path: String, request: HistoryPageRequest) {
        file.append(.init(path: path, reference: request.reference, cursor: request.cursor, limit: request.limit))
    }
    func recordSynchronization(_ revisionIDs: [String]) { synchronizationRevisionHistory.append(revisionIDs) }
    func historyRequests() -> [HistoryRequest] { history }
    func fileRequests() -> [FileRequest] { file }
    func synchronizationCalls() -> Int { synchronizationRevisionHistory.count }
    func synchronizationRevisionIDs() -> [[String]] { synchronizationRevisionHistory }
}
