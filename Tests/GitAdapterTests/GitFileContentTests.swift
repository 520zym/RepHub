import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 历史文件原始内容")
struct GitFileContentTests {
    @Test("固定提交返回二进制原始字节，不读取未提交工作区内容")
    func readsExactBinaryBlobAtFixedCommit() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let path = "assets/zero bytes.bin"
        let expected = Data([0, 255, 16, 0, 128, 42])
        let file = fixture.gitWriter.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try expected.write(to: file)
        try await success(["add", "--", path], in: fixture.gitWriter, fixture: fixture)
        try await success(["commit", "-m", "add binary"], in: fixture.gitWriter, fixture: fixture)
        let committed = try await revision("HEAD", in: fixture.gitWriter, fixture: fixture)
        try await success(["push", "origin", "HEAD:main"], in: fixture.gitWriter, fixture: fixture)
        try await success(["fetch", "origin"], in: fixture.gitReader, fixture: fixture)

        let localFile = fixture.gitReader.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: localFile)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let actual = try #require(await provider.fileContent(in: binding, path: path, revision: committed, pegRevision: nil))

        #expect(actual == expected)
        let localContent = try Data(contentsOf: localFile)
        #expect(actual != localContent)
    }

    @Test("删除后的节点返回 nil，旧提交与重命名前路径仍可读取")
    func returnsNilOnlyForMissingPathAndReadsOldRenamePath() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let oldPath = "docs/旧名.dat"
        let newPath = "docs/新名.dat"
        let bytes = Data([0, 18, 52, 86])
        let oldFile = fixture.gitWriter.appendingPathComponent(oldPath)
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: oldFile)
        try await success(["add", "--", oldPath], in: fixture.gitWriter, fixture: fixture)
        try await success(["commit", "-m", "old name"], in: fixture.gitWriter, fixture: fixture)
        let oldCommit = try await revision("HEAD", in: fixture.gitWriter, fixture: fixture)
        try await success(["--literal-pathspecs", "mv", "--", oldPath, newPath], in: fixture.gitWriter, fixture: fixture)
        try await success(["commit", "-m", "rename"], in: fixture.gitWriter, fixture: fixture)
        try await success(["rm", "--", newPath], in: fixture.gitWriter, fixture: fixture)
        try await success(["commit", "-m", "delete"], in: fixture.gitWriter, fixture: fixture)
        let deletedCommit = try await revision("HEAD", in: fixture.gitWriter, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitWriter))
        let old = try #require(await provider.fileContent(in: binding, path: oldPath, revision: oldCommit, pegRevision: nil))
        let deleted = try await provider.fileContent(in: binding, path: newPath, revision: deletedCommit, pegRevision: nil)

        #expect(old == bytes)
        #expect(deleted == nil)
    }

    @Test("拒绝分支名、目录和符号链接")
    func rejectsUnfixedOrUnsupportedTreeEntries() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = fixture.gitWriter.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        let docs = fixture.gitWriter.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: docs.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(atPath: fixture.gitWriter.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        try await success(["add", "--", "target.txt", "link.txt", "docs/note.txt"], in: fixture.gitWriter, fixture: fixture)
        try await success(["commit", "-m", "add link"], in: fixture.gitWriter, fixture: fixture)
        let commit = try await revision("HEAD", in: fixture.gitWriter, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitWriter))

        await #expect(throws: VersionControlError.self) {
            _ = try await provider.fileContent(in: binding, path: "README.md", revision: "HEAD", pegRevision: nil)
        }
        await #expect(throws: VersionControlError.self) {
            _ = try await provider.fileContent(in: binding, path: "docs", revision: commit, pegRevision: nil)
        }
        await #expect(throws: VersionControlError.self) {
            _ = try await provider.fileContent(in: binding, path: "link.txt", revision: commit, pegRevision: nil)
        }
    }

    private func success(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: directory), tool: "git")
    }

    private func revision(_ reference: String, in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(
            try await fixture.run(executable: "git", arguments: ["rev-parse", "--verify", reference], directory: directory),
            tool: "git"
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
