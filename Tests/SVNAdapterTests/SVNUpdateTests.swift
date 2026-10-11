import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNUpdateTests: XCTestCase {
    func testUpdateReadsRemoteFirstAndUpdatesOnlyFixtureWorkingCopy() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 更新测试。")
        }

        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let writerReadme = fixture.svnWriter.appendingPathComponent("README.md")
        try "updated by fixture writer\n".write(to: writerReadme, atomically: true, encoding: .utf8)
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["commit", "-m", "fixture remote update"], directory: fixture.svnWriter),
            tool: "svn"
        )

        let provider = SVNProvider(runner: fixture.runner)
        let detectedBinding = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detectedBinding)
        let recorder = ProgressRecorder()
        let result = try await provider.perform(.update, in: binding) { progress in
            await recorder.append(progress.message)
        }

        guard case .succeeded = result.outcome else {
            return XCTFail("预期 SVN 更新成功，实际为 \(result.summary)：\(result.details)")
        }
        XCTAssertTrue(result.changedFiles.contains { $0.path == "README.md" })
        XCTAssertEqual(
            try String(contentsOf: fixture.svnReader.appendingPathComponent("README.md"), encoding: .utf8),
            "updated by fixture writer\n"
        )
        let progress = await recorder.messages
        XCTAssertEqual(progress, ["检查 SVN 工作副本…", "探测 SVN 连接…", "更新 SVN 工作副本…", "核对 SVN 工作副本状态…"])
    }

    func testUpdateReportsConflictWithoutCleanupOrRetry() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 更新测试。")
        }

        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let readerReadme = fixture.svnReader.appendingPathComponent("README.md")
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["delete", readerReadme.path], directory: fixture.svnReader),
            tool: "svn"
        )
        let writerReadme = fixture.svnWriter.appendingPathComponent("README.md")
        try "remote update\n".write(to: writerReadme, atomically: true, encoding: .utf8)
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["commit", "-m", "fixture remote conflict"], directory: fixture.svnWriter),
            tool: "svn"
        )

        let provider = SVNProvider(runner: fixture.runner)
        let detectedBinding = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detectedBinding)
        let result = try await provider.perform(.update, in: binding) { _ in }

        guard case .conflicts = result.outcome else {
            return XCTFail("预期冲突结果，实际为 \(result.summary)：\(result.details)")
        }
        XCTAssertTrue(result.changedFiles.contains { $0.path == "README.md" && $0.kind == .conflicted })
        let status = try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["status", "--xml"], directory: fixture.svnReader),
            tool: "svn"
        )
        XCTAssertTrue(status.output.contains("tree-conflicted=\"true\"") || status.output.contains("item=\"conflicted\""))
    }

    func testUpdateReportsPropertyOnlyChangeWithSpaceInPath() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 更新测试。")
        }

        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let spacedFile = fixture.svnWriter.appendingPathComponent("space name.txt")
        try "fixture\n".write(to: spacedFile, atomically: true, encoding: .utf8)
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["add", spacedFile.path], directory: fixture.svnWriter),
            tool: "svn"
        )
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["commit", "-m", "fixture add spaced file"], directory: fixture.svnWriter),
            tool: "svn"
        )
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnReader),
            tool: "svn"
        )
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["propset", "rephub:fixture", "value", spacedFile.path], directory: fixture.svnWriter),
            tool: "svn"
        )
        try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["commit", "-m", "fixture property update"], directory: fixture.svnWriter),
            tool: "svn"
        )

        let provider = SVNProvider(runner: fixture.runner)
        let detectedBinding = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detectedBinding)
        let result = try await provider.perform(.update, in: binding) { _ in }

        guard case .succeeded = result.outcome else {
            return XCTFail("预期属性更新成功，实际为 \(result.summary)：\(result.details)")
        }
        XCTAssertTrue(result.changedFiles.contains { $0.path == "space name.txt" && $0.kind == .modified })
    }
}

private actor ProgressRecorder {
    private(set) var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}
