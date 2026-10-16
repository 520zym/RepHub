import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNHistoryTests: XCTestCase {
    func testFileHistoryAndDiffFollowCopiedPathWithSpacesAtSignAndChinese() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let oldPath = "archive/旧 文件@版本.txt"
        let newPath = "renamed/新 文件@版本.txt"
        try FileManager.default.createDirectory(at: fixture.svnWriter.appendingPathComponent("archive"), withIntermediateDirectories: true)
        try "first\n".write(to: fixture.svnWriter.appendingPathComponent(oldPath), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "archive"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add special file"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["mkdir", "renamed"], directory: fixture.svnWriter)
        // 源路径的 @ 需要空 peg 转义；svn move 的目标参数不接受该转义，必须原样给出。
        try await success(fixture, "svn", ["move", svnLiteralPath(oldPath), newPath], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "rename special file"], directory: fixture.svnWriter)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let entries = try await provider.fileHistory(in: binding, path: newPath, limit: 10, reference: "r4")

        XCTAssertEqual(entries.first?.revision.id, "r4")
        XCTAssertTrue(entries.contains { $0.revision.id == "r3" })
        let oldEntry = try XCTUnwrap(entries.first { $0.revision.id == "r3" })
        XCTAssertEqual(oldEntry.path, newPath)
        XCTAssertEqual(oldEntry.pegRevision, "r4")
        let patch = try await provider.fileHistoryDiff(in: binding, entry: oldEntry)
        // SVN 的差异标题按历史节点显示基名，不保证保留当前目录前缀。
        XCTAssertTrue(patch.text.contains("Index: \((oldPath as NSString).lastPathComponent)"))
        XCTAssertTrue(patch.text.contains("+first"))
    }

    func testSynchronizationMarksIncomingAndMixedBaseWithoutPushCount() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        try "r3\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "r3 readme"], directory: fixture.svnWriter)
        try "r4\n".write(to: fixture.svnWriter.appendingPathComponent("remote-only.txt"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "remote-only.txt"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "r4 remote only"], directory: fixture.svnWriter)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let history = try await provider.history(in: binding, limit: 10, reference: nil)
        let beforeUpdate = try await provider.synchronization(in: binding, revisions: history, path: nil)
        XCTAssertEqual(beforeUpdate.incomingCount, 2)
        XCTAssertNil(beforeUpdate.outgoingCount)
        XCTAssertEqual(beforeUpdate.states["r4"], .incoming)
        XCTAssertEqual(beforeUpdate.states["r2"], .synchronized)

        try await success(fixture, "svn", ["update", "-r", "3", "README.md"], directory: fixture.svnReader)
        let mixed = try await provider.synchronization(in: binding, revisions: history, path: nil)
        XCTAssertEqual(mixed.states["r4"], .incoming)
        // r3 的唯一变更 README 已在本地 BASE，精确核对后可以确认同步。
        XCTAssertEqual(mixed.states["r3"], .synchronized)
        XCTAssertEqual(mixed.states["r2"], .synchronized)
        XCTAssertNil(mixed.outgoingCount)
    }

    func testMixedWorkingCopyConfirmsLatestCommitWhenAllChangedFilesHaveLocalBase() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        // 保持 reader 在 r2，同时让仓库先出现一个未更新的 r3；随后 reader 自己提交
        // 两个普通文件，结果为 r2:r4。此时不能仅因 mixed range 把刚提交的 r4 标为需核对。
        try "remote only\n".write(to: fixture.svnWriter.appendingPathComponent("remote-only.txt"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "remote-only.txt"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "r3 remote only"], directory: fixture.svnWriter)

        try "reader change\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let added = "新 文件@r4.txt "
        try "added locally\n".write(to: fixture.svnReader.appendingPathComponent(added), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", svnLiteralPath(added)], directory: fixture.svnReader)
        try await success(fixture, "svn", ["commit", "-m", "r4 local two files"], directory: fixture.svnReader)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let history = try await provider.history(in: binding, limit: 10, reference: nil)
        let state = try await provider.synchronization(in: binding, revisions: history, path: nil)

        XCTAssertEqual(state.states["r4"], .synchronized)
        XCTAssertEqual(state.states["r3"], .uncertain)
        XCTAssertEqual(state.states["r2"], .synchronized)
        // 同步判定只读本地 BASE；没有调用 update，因此 mixed 形态仍然保留。
        let version = try await fixture.run(executable: "svnversion", arguments: [], directory: fixture.svnReader)
        XCTAssertTrue(try requireSuccess(version, tool: "svnversion").output.contains(":"))

        // 后续回退其中一个本次提交文件后，不能沿用先前的同步结论。
        try await success(fixture, "svn", ["update", "-r", "2", "README.md"], directory: fixture.svnReader)
        let afterRollback = try await provider.synchronization(in: binding, revisions: history, path: nil)
        XCTAssertEqual(afterRollback.states["r4"], .uncertain)
    }

    func testMixedWorkingCopyKeepsMaximumUncertainWhenOnlyPartOfItsChangesAreUpdated() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let second = "含 空格@文件.txt"
        try "r3 readme\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "r3 second\n".write(to: fixture.svnWriter.appendingPathComponent(second), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", svnLiteralPath(second)], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "r3 two files"], directory: fixture.svnWriter)

        // 只更新该 revision 涉及的一个文件；另一个新增文件尚未检出，不能把 r3 判为已同步。
        try await success(fixture, "svn", ["update", "README.md"], directory: fixture.svnReader)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let history = try await provider.history(in: binding, limit: 10, reference: nil)
        let state = try await provider.synchronization(in: binding, revisions: history, path: nil)

        XCTAssertEqual(state.states["r3"], .uncertain)
        XCTAssertEqual(state.states["r2"], .synchronized)
    }

    func testFileSynchronizationUsesItsOwnBaseRevision() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        try "r3\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "r3 readme"], directory: fixture.svnWriter)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let history = try await provider.history(in: binding, limit: 10, reference: nil)

        let state = try await provider.synchronization(in: binding, revisions: history, path: "README.md")
        XCTAssertEqual(state.incomingCount, 1)
        XCTAssertEqual(state.states["r3"], .incoming)
    }

    func testDeletedFileHistoryUsesPreviousPegAndKeepsDeletionRevision() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let deletedPath = "已删除 文件@版本.txt"
        try "before deletion\n".write(to: fixture.svnWriter.appendingPathComponent(deletedPath), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", svnLiteralPath(deletedPath)], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add deleted file"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["delete", svnLiteralPath(deletedPath)], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "delete special file"], directory: fixture.svnWriter)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let entries = try await provider.fileHistory(in: binding, path: deletedPath, limit: 10, reference: "r4")
        XCTAssertEqual(entries.first?.revision.id, "r4")
        XCTAssertTrue(entries.contains { $0.revision.id == "r3" })
        XCTAssertEqual(entries.first?.pegRevision, "r3")
        let deletion = try XCTUnwrap(entries.first)
        let patch = try await provider.fileHistoryDiff(in: binding, entry: deletion)
        XCTAssertTrue(patch.text.contains(deletedPath))
        XCTAssertTrue(patch.text.contains("-before deletion"))
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 单文件历史测试。")
        }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ executable: String, _ arguments: [String], directory: URL) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }

    private func svnLiteralPath(_ path: String) -> String {
        path.contains("@") ? path + "@" : path
    }
}
