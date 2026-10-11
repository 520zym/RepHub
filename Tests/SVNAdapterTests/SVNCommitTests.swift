import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNCommitTests: XCTestCase {
    func testCommitsOnlySelectedModifiedFile() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let first = fixture.svnReader.appendingPathComponent("README.md")
        let second = fixture.svnReader.appendingPathComponent("kept-local.txt")
        try "selected\n".write(to: first, atomically: true, encoding: .utf8)
        try "must remain local\n".write(to: second, atomically: true, encoding: .utf8)

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "README.md" })
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "commit selected only"),
            in: binding,
            progress: { _ in }
        )

        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.succeeded.rawValue)
        XCTAssertNotNil(result.revisionID)
        let readerStatus = try await provider.status(in: binding)
        XCTAssertTrue(readerStatus.contains { $0.path == "kept-local.txt" && $0.kind == .untracked })
        let writerUpdate = try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnWriter)
        _ = try requireSuccess(writerUpdate, tool: "svn")
        XCTAssertEqual(try String(contentsOf: fixture.svnWriter.appendingPathComponent("README.md"), encoding: .utf8), "selected\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.svnWriter.appendingPathComponent("kept-local.txt").path))
    }

    func testNewNestedFileAddsOnlyNecessaryParentsAndDoesNotCaptureSibling() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let folder = fixture.svnReader.appendingPathComponent("new-folder/child", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "chosen\n".write(to: folder.appendingPathComponent("chosen.txt"), atomically: true, encoding: .utf8)
        try "sibling\n".write(to: folder.appendingPathComponent("not-chosen.txt"), atomically: true, encoding: .utf8)
        _ = try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["add", "--parents", "new-folder/child/not-chosen.txt"], directory: fixture.svnReader),
            tool: "svn"
        )

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "new-folder/child/chosen.txt" })
        let preview = try await provider.commitDiff(in: binding, file: selected)
        XCTAssertTrue(preview.text.contains("chosen"))
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "commit one nested file"),
            in: binding,
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.succeeded.rawValue)
        let status = try await provider.status(in: binding)
        XCTAssertTrue(status.contains { $0.path == "new-folder/child/not-chosen.txt" && $0.kind == .added })
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnWriter), tool: "svn")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.svnWriter.appendingPathComponent("new-folder/child/chosen.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.svnWriter.appendingPathComponent("new-folder/child/not-chosen.txt").path))
    }

    func testRejectsSnapshotChangedAfterPreparation() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let file = fixture.svnReader.appendingPathComponent("README.md")
        try "first local version\n".write(to: file, atomically: true, encoding: .utf8)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "README.md" })
        try "changed after preview\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "stale snapshot"),
            in: binding,
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.failed.rawValue)
        XCTAssertTrue(result.summary.contains("重新查看"))
        let log = try await fixture.run(executable: "svn", arguments: ["log", "--xml", "--limit", "1"], directory: fixture.svnReader)
        XCTAssertFalse(log.output.contains("stale snapshot"))
    }

    func testRejectsPropertyValueChangedAfterPreparation() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let file = fixture.svnReader.appendingPathComponent("README.md")
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["propset", "rephub:check", "first", file.path], directory: fixture.svnReader), tool: "svn")
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "README.md" })
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["propset", "rephub:check", "second", file.path], directory: fixture.svnReader), tool: "svn")
        let result = try await provider.commit(RepositoryCommitRequest(bindingID: binding.id, baseRevision: preparation.baseRevision, files: [selected], message: "property stale"), in: binding, progress: { _ in })
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.failed.rawValue)
        XCTAssertTrue(result.summary.contains("重新查看"))
    }

    func testPreflightConnectionFailureReturnsFailedBeforeCommit() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let file = fixture.svnReader.appendingPathComponent("README.md")
        try "local\n".write(to: file, atomically: true, encoding: .utf8)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let selected = try XCTUnwrap(preparation.files.first { $0.change.path == "README.md" })
        let unavailable = RepositoryBinding(providerID: .svn, providerName: "Subversion", root: binding.root, remoteURL: "file:///definitely-missing-rephub-repository", capabilities: binding.capabilities)
        let result = try await provider.commit(RepositoryCommitRequest(bindingID: unavailable.id, baseRevision: preparation.baseRevision, files: [selected], message: "must not commit"), in: unavailable, progress: { _ in })
        XCTAssertEqual(result.outcome.rawValue, RepositoryCommitOutcome.failed.rawValue)
    }

    func testAllowsSingleFileDeletionButKeepsItExplicitInPreparation() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let file = fixture.svnReader.appendingPathComponent("README.md")
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["delete", file.path], directory: fixture.svnReader), tool: "svn")
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preparation = try await provider.prepareCommit(in: binding)
        let deleted = try XCTUnwrap(preparation.files.first { $0.change.path == "README.md" })
        XCTAssertNil(deleted.restriction)
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 提交测试。")
        }
    }
}
