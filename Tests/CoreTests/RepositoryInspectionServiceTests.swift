import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("全历史搜索服务")
struct RepositoryInspectionServiceTests {
    @Test("分批扫描固定历史，并且可继续到更早提交")
    func scansBeyondInitiallyLoadedHistory() async throws {
        let provider = InspectionFixtureProvider(revisions: (0..<340).map { index in
            Revision(id: "r\(index)", author: index == 321 ? "zym" : "other", date: Date(timeIntervalSince1970: Double(index)), message: index == 321 ? "目标修复" : "普通提交 \(index)")
        })
        let service = RepositoryService(providers: [provider])
        let binding = provider.binding
        let query = RepositoryHistorySearchQuery(text: "目标", author: "zym")

        let first = try await service.searchHistory(in: binding, query: query)
        #expect(first.revisions.isEmpty)
        #expect(first.scannedCount == 300)
        let cursor = try #require(first.nextCursor)
        let second = try await service.searchHistory(in: binding, query: query, cursor: cursor)
        #expect(second.revisions.map(\.id) == ["r321"])
        #expect(second.isComplete)
        #expect(second.scannedCount == 340)
    }

    @Test("搜索游标不能跨条件复用")
    func rejectsCursorFromAnotherQuery() async throws {
        let provider = InspectionFixtureProvider(revisions: (0..<301).map { Revision(id: "r\($0)", author: "a", date: .now, message: "m") })
        let service = RepositoryService(providers: [provider])
        let first = try await service.searchHistory(in: provider.binding, query: .init())
        let cursor = try #require(first.nextCursor)
        await #expect(throws: VersionControlError.self) {
            try await service.searchHistory(in: provider.binding, query: .init(text: "other"), cursor: cursor)
        }
    }
}

private final class InspectionFixtureProvider: RepositoryHistoryPagingProvider, RepositoryInspectionProvider, @unchecked Sendable {
    let id = ProviderID(rawValue: "fixture")
    let displayName = "Fixture"
    let revisions: [Revision]
    let binding: RepositoryBinding

    init(revisions: [Revision]) {
        self.revisions = revisions
        binding = RepositoryBinding(providerID: ProviderID(rawValue: "fixture"), providerName: "Fixture",
                                    root: URL(fileURLWithPath: "/tmp/rephub-inspection-fixture", isDirectory: true),
                                    capabilities: [.history, .fileHistory])
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? { binding }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { Array(revisions.prefix(limit)) }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] {
        Array(revisions.prefix(limit)).map { FileHistoryEntry(revision: $0, path: path) }
    }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch { .init(text: "") }
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        .init(summary: "")
    }
    func historyPage(in binding: RepositoryBinding, request: HistoryPageRequest) async throws -> RepositoryHistoryPage {
        let offset = Int(request.cursor ?? "0") ?? 0
        let page = Array(revisions.dropFirst(offset).prefix(request.limit))
        let next = offset + page.count < revisions.count ? String(offset + page.count) : nil
        return .init(revisions: page, nextCursor: next)
    }
    func fileHistoryPage(in binding: RepositoryBinding, path: String, request: HistoryPageRequest) async throws -> FileHistoryPage {
        let page = try await historyPage(in: binding, request: request)
        return .init(entries: page.revisions.map { FileHistoryEntry(revision: $0, path: path) }, nextCursor: page.nextCursor)
    }
    func blame(in binding: RepositoryBinding, path: String, reference: String?) async throws -> RepositoryBlame {
        .init(path: path, reference: "r0", lines: [])
    }
}
