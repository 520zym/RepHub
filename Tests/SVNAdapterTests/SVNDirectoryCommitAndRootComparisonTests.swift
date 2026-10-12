import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

/// 目录提交必须以 `--depth empty` 保持用户选中的精确边界；所有测试仓库均为临时 file:// 设施。
final class SVNDirectoryCommitAndRootComparisonTests: XCTestCase {
    func testCommitsNestedEmptyDirectoryWithOnlyItsNecessaryParent() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let nested = fixture.svnReader.appendingPathComponent("outside/selected-empty", isDirectory: true)
        let sibling = fixture.svnReader.appendingPathComponent("outside/not-selected.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "local sibling\n".write(to: sibling, atomically: true, encoding: .utf8)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "outside/selected-empty" })
        XCTAssertNil(selected.restriction)
        XCTAssertTrue(selected.isDirectory)
        XCTAssertTrue(preparation.notice.contains("目录勾选仅提交自身"))
        let preview = try await provider.commitDiff(in: binding, file: selected)
        XCTAssertTrue(preview.text.contains("未选择的子文件"))

        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "add selected empty directory"),
            in: binding,
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.succeeded.rawValue)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnWriter), tool: "svn")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.svnWriter.appendingPathComponent("outside/selected-empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.svnWriter.appendingPathComponent("outside/not-selected.txt").path))
    }

    func testCommitsOnlyVersionedDirectoryPropertyWithoutChildContent() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let folder = fixture.svnReader.appendingPathComponent("managed", isDirectory: true)
        let child = folder.appendingPathComponent("kept.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "base child\n".write(to: child, atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["add", folder.path], directory: fixture.svnReader), tool: "svn")
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["commit", "-m", "seed managed directory"], directory: fixture.svnReader), tool: "svn")
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnWriter), tool: "svn")

        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["propset", "rephub:scope", "directory-only", folder.path], directory: fixture.svnReader), tool: "svn")
        try "must remain local\n".write(to: child, atomically: true, encoding: .utf8)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "managed" })
        XCTAssertNil(selected.restriction)
        XCTAssertTrue(selected.isDirectory)
        let preview = try await provider.commitDiff(in: binding, file: selected)
        XCTAssertTrue(preview.text.contains("rephub:scope"))
        XCTAssertFalse(preview.text.contains("kept.txt"))
        XCTAssertFalse(preview.text.contains("must remain local"))
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "directory properties only"),
            in: binding,
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.succeeded.rawValue)

        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnWriter), tool: "svn")
        let property = try await fixture.run(executable: "svn", arguments: ["propget", "rephub:scope", "managed"], directory: fixture.svnWriter)
        XCTAssertEqual(property.output.trimmingCharacters(in: .whitespacesAndNewlines), "directory-only")
        XCTAssertEqual(try String(contentsOf: fixture.svnWriter.appendingPathComponent("managed/kept.txt"), encoding: .utf8), "base child\n")
    }

    func testRootOnlyPropertyChangeAppearsInComparisonAndReadsItsDiff() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let before = try await fixture.run(executable: "svn", arguments: ["info", "--show-item", "revision"], directory: fixture.svnReader)
        let start = before.output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["propset", "rephub:root", "root-only", "."], directory: fixture.svnReader), tool: "svn")
        try "child content in same revision\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["commit", "-m", "root property and child content"], directory: fixture.svnReader), tool: "svn")
        let after = try await fixture.run(executable: "svn", arguments: ["info", "--show-item", "revision"], directory: fixture.svnReader)
        let end = after.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let comparison = try await provider.compare(in: binding, from: start, to: end)
        let root = try XCTUnwrap(comparison.files.first { $0.path == "." })
        XCTAssertEqual(root.kind.rawValue, FileChangeKind.modified.rawValue)
        XCTAssertTrue(comparison.files.contains { $0.path == "README.md" })
        let patch = try await provider.comparisonDiff(in: binding, comparison: comparison, path: root.path)
        XCTAssertTrue(patch.text.contains("rephub:root"))
        XCTAssertTrue(patch.text.contains("root-only"))
        XCTAssertFalse(patch.text.contains("README.md"))
        XCTAssertFalse(patch.text.contains("child content in same revision"))
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 目录测试。")
        }
    }
}
