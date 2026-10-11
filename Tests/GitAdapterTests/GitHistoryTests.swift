import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 文件历史与同步状态")
struct GitHistoryTests {
    @Test("单文件历史追溯重命名，差异使用历史路径并忽略无关提交")
    func followsRenameAndReadsHistoricalDiff() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let oldPath = "旧 文件.txt"
        let newPath = ":新 文件.txt"
        try "第一版\n".write(to: fixture.gitWriter.appendingPathComponent(oldPath), atomically: true, encoding: .utf8)
        try await commitAndPush(["add", "--", oldPath], message: "添加旧文件", fixture: fixture)
        try await success("git", ["--literal-pathspecs", "mv", "--", oldPath, newPath], in: fixture.gitWriter, fixture: fixture)
        try await commitAndPush([], message: "重命名文件", fixture: fixture)
        try "第二版\n".write(to: fixture.gitWriter.appendingPathComponent(newPath), atomically: true, encoding: .utf8)
        try await commitAndPush(["--literal-pathspecs", "add", "--", newPath], message: "修改新文件", fixture: fixture)
        try "无关内容\n".write(to: fixture.gitWriter.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        try await commitAndPush(["add", "--", "unrelated.txt"], message: "无关提交", fixture: fixture)
        try await success("git", ["fetch", "origin"], in: fixture.gitReader, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let entries = try await provider.fileHistory(in: binding, path: newPath, limit: 20, reference: "origin/main")

        #expect(entries.map(\.revision.subject) == ["修改新文件", "重命名文件", "添加旧文件"])
        #expect(entries[0].path == newPath)
        #expect(entries[1].path == newPath)
        #expect(entries[2].path == oldPath)
        #expect(entries.allSatisfy { $0.revision.subject != "无关提交" })
        let original = try #require(entries.last)
        let patch = try await provider.fileHistoryDiff(in: binding, entry: original)
        #expect(patch.text.contains(oldPath))
        #expect(!patch.text.contains(newPath))
    }

    @Test("同步状态只计算当前分支与已获取上游，未合并的其他分支不计入")
    func readsAheadBehindWithoutCountingOtherBranches() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "远端提交\n".write(to: fixture.gitWriter.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try await commitAndPush(["add", "--", "remote.txt"], message: "远端提交", fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let beforeFetch = try await provider.synchronization(in: binding, revisions: [], path: nil)
        #expect(beforeFetch.incomingCount == 0)
        #expect(beforeFetch.outgoingCount == 0)

        try await success("git", ["fetch", "origin"], in: fixture.gitReader, fixture: fixture)
        try "本地提交\n".write(to: fixture.gitReader.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await commit(["add", "--", "local.txt"], message: "本地提交", in: fixture.gitReader, fixture: fixture)
        let localID = try await revision("HEAD", in: fixture.gitReader, fixture: fixture)
        let incomingID = try await revision("origin/main", in: fixture.gitReader, fixture: fixture)
        let sharedID = try await revision("HEAD^", in: fixture.gitReader, fixture: fixture)

        try await success("git", ["checkout", "-b", "unrelated"], in: fixture.gitReader, fixture: fixture)
        try "其他分支\n".write(to: fixture.gitReader.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await commit(["add", "--", "other.txt"], message: "其他分支提交", in: fixture.gitReader, fixture: fixture)
        let otherBranchID = try await revision("HEAD", in: fixture.gitReader, fixture: fixture)
        try await success("git", ["checkout", "main"], in: fixture.gitReader, fixture: fixture)

        let listed = [
            Revision(id: localID, author: "fixture", date: .now, message: "本地提交"),
            Revision(id: incomingID, author: "fixture", date: .now, message: "远端提交"),
            Revision(id: sharedID, author: "fixture", date: .now, message: "共同提交"),
            Revision(id: otherBranchID, author: "fixture", date: .now, message: "其他分支提交")
        ]
        let sync = try await provider.synchronization(in: binding, revisions: listed, path: "local.txt")
        #expect(sync.outgoingCount == 1)
        #expect(sync.incomingCount == 1)
        #expect(sync.states[localID] == .outgoing)
        #expect(sync.states[incomingID] == .incoming)
        #expect(sync.states[sharedID] == .synchronized)
        #expect(sync.states[otherBranchID] == nil)
        #expect(sync.detail.contains("本机"))
        #expect(sync.detail.contains("获取远端"))
    }

    @Test("无上游分支显示未知状态，不把计数误报为零")
    func reportsUnknownWithoutUpstream() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await success("git", ["branch", "--unset-upstream", "main"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let sync = try await provider.synchronization(in: binding, revisions: [], path: nil)
        #expect(sync.incomingCount == nil)
        #expect(sync.outgoingCount == nil)
        #expect(sync.summary == "同步状态未知")
        #expect(sync.detail.contains("上游"))
    }

    @Test("本地分支上游不被误报为待推送远端")
    func reportsUnknownForLocalBranchUpstream() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await success("git", ["branch", "local-upstream", "main"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["config", "branch.main.remote", "."], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["config", "branch.main.merge", "refs/heads/local-upstream"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let sync = try await provider.synchronization(in: binding, revisions: [], path: nil)
        #expect(sync.incomingCount == nil)
        #expect(sync.outgoingCount == nil)
        #expect(sync.detail.contains("本地分支"))
    }

    private func commitAndPush(_ addArguments: [String], message: String, fixture: LocalRepositoryFixture) async throws {
        if !addArguments.isEmpty {
            try await success("git", addArguments, in: fixture.gitWriter, fixture: fixture)
        }
        try await success("git", ["commit", "-m", message], in: fixture.gitWriter, fixture: fixture)
        try await success("git", ["push", "origin", "HEAD:main"], in: fixture.gitWriter, fixture: fixture)
    }

    private func commit(_ addArguments: [String], message: String, in directory: URL, fixture: LocalRepositoryFixture) async throws {
        try await success("git", addArguments, in: directory, fixture: fixture)
        try await success("git", ["commit", "-m", message], in: directory, fixture: fixture)
    }

    private func revision(_ reference: String, in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        let result = try await fixture.run(executable: "git", arguments: ["rev-parse", "--verify", reference], directory: directory)
        return try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func success(_ executable: String, _ arguments: [String], in directory: URL? = nil, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
}
