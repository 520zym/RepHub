import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNHistoryPagingTests: XCTestCase {
    func testEmptyRepositoryAtRevisionZeroReturnsEmptyHistoryPage() async throws {
        try requireSVN()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RepHub-EmptySVN-History-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workingCopy = root.appendingPathComponent("working-copy", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = CommandRunner(isolatedHome: home)
        _ = try requireSuccess(
            try await runner.run(executable: "svnadmin", arguments: ["create", repository.path], directory: root),
            tool: "svnadmin"
        )
        _ = try requireSuccess(
            try await runner.run(
                executable: "svn", arguments: ["checkout", repository.absoluteURL.absoluteString, workingCopy.path], directory: root
            ),
            tool: "svn"
        )

        let provider = SVNProvider(runner: runner)
        let detected = try await provider.detect(at: workingCopy)
        let binding = try XCTUnwrap(detected)
        let page = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 150))
        XCTAssertTrue(page.revisions.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    func testRepositoryHistoryPagesPast150WithoutDuplicatesWhenNewRevisionArrives() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let file = fixture.svnWriter.appendingPathComponent("paged.txt")
        try "0\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "paged.txt"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add paged file"], directory: fixture.svnWriter)
        // 单个隔离仓库构造超过默认 150 条的真实 SVN 历史；不要触及业务仓库。
        for revision in 1...151 {
            try "\(revision)\n".write(to: file, atomically: true, encoding: .utf8)
            try await success(fixture, "svn", ["commit", "-m", "page \(revision)"], directory: fixture.svnWriter)
        }

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let baseline = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 500))
        let expected = baseline.revisions
        XCTAssertGreaterThan(expected.count, 150)
        let first = try await provider.historyPage(in: binding, request: HistoryPageRequest(limit: 150))
        XCTAssertEqual(first.revisions.count, 150)

        // 第二页前插入新提交；续页必须沿首屏的数值游标继续，不能把新 HEAD 混进去。
        try "new head\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "new head after first page"], directory: fixture.svnWriter)

        var actual = first.revisions
        var cursor = first.nextCursor
        while let current = cursor {
            let page = try await provider.historyPage(
                in: binding,
                request: HistoryPageRequest(limit: 150, cursor: current)
            )
            actual += page.revisions
            cursor = page.nextCursor
        }
        XCTAssertEqual(actual.map(\.id), expected.map(\.id))
        XCTAssertEqual(Set(actual.map(\.id)).count, actual.count)
    }

    func testFileHistoryPagesFollowRenameAndDeletionAcrossSmallPages() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let oldPath = "nested/old-name.txt"
        let newPath = "nested/renamed-name.txt"
        try FileManager.default.createDirectory(at: fixture.svnWriter.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "first\n".write(to: fixture.svnWriter.appendingPathComponent(oldPath), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "nested"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add nested file"], directory: fixture.svnWriter)
        try "second\n".write(to: fixture.svnWriter.appendingPathComponent(oldPath), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "modify nested file"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["move", oldPath, newPath], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "rename nested file"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["delete", newPath], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "delete nested file"], directory: fixture.svnWriter)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let first = try await provider.fileHistoryPage(
            in: binding, path: newPath, request: HistoryPageRequest(limit: 1, reference: "r6")
        )
        XCTAssertEqual(first.entries.map(\.revision.id), ["r6"])
        XCTAssertEqual(first.entries.first?.pegRevision, "r5")

        var entries = first.entries
        var cursor = first.nextCursor
        while let current = cursor {
            let page = try await provider.fileHistoryPage(
                in: binding, path: newPath, request: HistoryPageRequest(limit: 1, reference: "r6", cursor: current)
            )
            entries += page.entries
            cursor = page.nextCursor
        }
        XCTAssertEqual(entries.map(\.revision.id), ["r6", "r5", "r4", "r3"])
        XCTAssertEqual(Set(entries.map(\.revision.id)).count, entries.count)

        guard let firstCursor = first.nextCursor else { return XCTFail("删除页后应还有文件历史") }
        do {
            _ = try await provider.fileHistoryPage(
                in: binding, path: "README.md", request: HistoryPageRequest(limit: 1, reference: "r6", cursor: firstCursor)
            )
            XCTFail("文件历史游标不应跨路径使用")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("游标"))
        }
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 分页历史测试。")
        }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ executable: String, _ arguments: [String], directory: URL) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
}
