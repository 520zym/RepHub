import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNFileContentTests: XCTestCase {
    func testReadsExactHistoricalBytesAcrossRenameInsteadOfWorkingCopy() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let oldPath = "legacy/旧 文件@版本.bin"
        let newPath = "moved/新 文件@版本.bin"
        let historical = Data([0x00, 0xFF, 0x41, 0x0A, 0x80, 0x42])
        try FileManager.default.createDirectory(at: fixture.svnWriter.appendingPathComponent("legacy"), withIntermediateDirectories: true)
        try historical.write(to: fixture.svnWriter.appendingPathComponent(oldPath))
        try await success(fixture, ["add", "--parents", svnLiteralPath(oldPath)])
        try await success(fixture, ["commit", "-m", "add binary with special path"])

        try await success(fixture, ["mkdir", "moved"])
        try await success(fixture, ["move", svnLiteralPath(oldPath), newPath])
        try await success(fixture, ["commit", "-m", "move binary across directory"])
        // 这是未提交的工作副本内容；历史读取必须完全忽略它。
        try Data("local uncommitted replacement".utf8).write(to: fixture.svnWriter.appendingPathComponent(newPath))

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let content = try await provider.fileContent(
            in: binding, path: newPath, revision: "r3", pegRevision: "r4"
        )
        XCTAssertEqual(content, historical)
    }

    func testReturnsNilOnlyForDeletedNodeAtRequestedRevision() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let path = "删除/带 空格@文件.bin"
        try FileManager.default.createDirectory(at: fixture.svnWriter.appendingPathComponent("删除"), withIntermediateDirectories: true)
        try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: fixture.svnWriter.appendingPathComponent(path))
        try await success(fixture, ["add", "--parents", svnLiteralPath(path)])
        try await success(fixture, ["commit", "-m", "add deleted binary"])
        try await success(fixture, ["delete", svnLiteralPath(path)])
        try await success(fixture, ["commit", "-m", "delete binary"])

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let beforeDeletion = try await provider.fileContent(in: binding, path: path, revision: "r3", pegRevision: "r3")
        XCTAssertEqual(beforeDeletion, Data([0xCA, 0xFE, 0xBA, 0xBE]))
        let deleted = try await provider.fileContent(in: binding, path: path, revision: "r4", pegRevision: "r3")
        XCTAssertNil(deleted)
    }

    func testRejectsDirectoryAndSVNSpecialNode() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let specialPath = "links/目标@链接"
        try FileManager.default.createDirectory(at: fixture.svnWriter.appendingPathComponent("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.svnWriter.appendingPathComponent(specialPath).path,
            withDestinationPath: "target/path"
        )
        try await success(fixture, ["add", "--parents", svnLiteralPath(specialPath)])
        try await success(fixture, ["commit", "-m", "add special node"])

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let directoryError: Error?
        do {
            _ = try await provider.fileContent(in: binding, path: "links", revision: "r3", pegRevision: "r3")
            directoryError = nil
        } catch {
            directoryError = error
        }
        XCTAssertNotNil(directoryError)

        let specialError: Error?
        do {
            _ = try await provider.fileContent(in: binding, path: specialPath, revision: "r3", pegRevision: "r3")
            specialError = nil
        } catch {
            specialError = error
        }
        XCTAssertNotNil(specialError)
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 历史字节读取测试。")
        }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ arguments: [String]) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: arguments, directory: fixture.svnWriter), tool: "svn")
    }

    private func svnLiteralPath(_ path: String) -> String { path.contains("@") ? path + "@" : path }
}
