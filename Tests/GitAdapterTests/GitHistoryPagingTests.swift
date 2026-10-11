import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 提交历史分页")
struct GitHistoryPagingTests {
    @Test("超过 150 条提交可逐页读取且无重复遗漏")
    func readsAllPagesWithoutDuplicates() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await makeCommits(153, file: "history.txt", fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))

        var cursor: String?
        var ids: [String] = []
        repeat {
            let page = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 19, cursor: cursor))
            ids += page.revisions.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil

        #expect(ids.count == 154) // 测试设施的初始提交 + 153 条提交。
        #expect(Set(ids).count == ids.count)
    }

    @Test("翻页期间新增提交不会进入已固定的历史快照")
    func keepsInitialTipsBetweenPages() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await makeCommits(9, file: "history.txt", fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let first = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 4))
        let expected = first.revisions.map(\.id)
        let originalCount = 10

        try "later\n".write(to: fixture.gitReader.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "later.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "翻页后新增"], in: fixture.gitReader, fixture: fixture)

        var ids = expected
        var cursor = first.nextCursor
        while let current = cursor {
            let page = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 4, cursor: current))
            ids += page.revisions.map(\.id)
            cursor = page.nextCursor
        }
        let laterID = try await revision("HEAD", in: fixture.gitReader, fixture: fixture)
        #expect(ids.count == originalCount)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(laterID))
    }

    @Test("文件历史跨页重命名后保留旧路径")
    func preservesHistoricalPathAcrossRenamePageBoundary() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(fixture)
        try "old\n".write(to: fixture.gitReader.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "old.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "old"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["mv", "old.txt", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "rename"], in: fixture.gitReader, fixture: fixture)
        try "newer\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "new"], in: fixture.gitReader, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let first = try await provider.fileHistoryPage(in: binding, path: "new.txt", request: HistoryPageRequest(limit: 2))
        let cursor = try #require(first.nextCursor)
        let next = try await provider.fileHistoryPage(in: binding, path: "new.txt", request: HistoryPageRequest(limit: 2, cursor: cursor))
        #expect(first.entries.map(\.revision.subject) == ["new", "rename"])
        #expect(next.entries.map(\.revision.subject) == ["old"])
        #expect(next.entries.first?.path == "old.txt")
    }

    @Test("小页文件历史穿过改名与合并后仍与完整历史一致")
    func preservesCompleteFileHistoryAcrossRenameAndMerge() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(fixture)

        try "old\n".write(to: fixture.gitReader.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "old.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "old"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["mv", "old.txt", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "rename"], in: fixture.gitReader, fixture: fixture)

        try await success("git", ["checkout", "-b", "side"], in: fixture.gitReader, fixture: fixture)
        try "side\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "side"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["checkout", "main"], in: fixture.gitReader, fixture: fixture)
        try "main\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "main"], in: fixture.gitReader, fixture: fixture)

        let merge = try await fixture.run(executable: "git", arguments: ["merge", "--no-ff", "side", "-m", "merge"], directory: fixture.gitReader)
        #expect(merge.exitCode != 0) // 两边都改同一文件，明确走手工合并提交。
        try "merged\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "merge"], in: fixture.gitReader, fixture: fixture)
        try "latest\n".write(to: fixture.gitReader.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "new.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "latest"], in: fixture.gitReader, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let complete = try await provider.fileHistory(in: binding, path: "new.txt", limit: 500, reference: nil)
        var paged: [FileHistoryEntry] = []
        var cursor: String?
        repeat {
            let page = try await provider.fileHistoryPage(in: binding, path: "new.txt", request: HistoryPageRequest(limit: 1, cursor: cursor))
            paged += page.entries
            cursor = page.nextCursor
        } while cursor != nil

        #expect(paged.map { "\($0.revision.id)|\($0.path)" } == complete.map { "\($0.revision.id)|\($0.path)" })
    }

    @Test("其他仓库不能复用历史游标")
    func rejectsCursorFromDifferentRepository() async throws {
        let firstFixture = try await LocalRepositoryFixture.create()
        let secondFixture = try await LocalRepositoryFixture.create()
        defer { try? firstFixture.remove(); try? secondFixture.remove() }
        try await makeCommits(1, file: "cursor.txt", fixture: firstFixture)
        let provider = GitProvider(runner: firstFixture.runner)
        let firstBinding = try #require(await provider.detect(at: firstFixture.gitReader))
        let page = try await provider.historyPage(in: firstBinding, request: HistoryPageRequest(limit: 1))
        let cursor = try #require(page.nextCursor)
        let secondBinding = try #require(await provider.detect(at: secondFixture.gitReader))
        await #expect(throws: VersionControlError.self) {
            try await provider.historyPage(in: secondBinding, request: HistoryPageRequest(limit: 1, cursor: cursor))
        }
    }

    private func makeCommits(_ count: Int, file: String, fixture: LocalRepositoryFixture) async throws {
        try await configureAuthor(fixture)
        for index in 0..<count {
            try "\(index)\n".write(to: fixture.gitReader.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await success("git", ["add", file], in: fixture.gitReader, fixture: fixture)
            try await success("git", ["commit", "-m", "page \(index)"], in: fixture.gitReader, fixture: fixture)
        }
    }

    private func configureAuthor(_ fixture: LocalRepositoryFixture) async throws {
        try await success("git", ["config", "user.name", "RepHub Fixture"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["config", "user.email", "fixture@localhost"], in: fixture.gitReader, fixture: fixture)
    }

    private func revision(_ reference: String, in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        let result = try await fixture.run(executable: "git", arguments: ["rev-parse", "--verify", reference], directory: directory)
        return try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func success(_ executable: String, _ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
}
