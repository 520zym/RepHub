import Foundation
import GitAdapter
import TestSupport
import Testing
import ToolExecution
import VersionControlCore

@Suite("Git 内置冲突编辑")
struct GitConflictEditingTests {
    @Test("读取三份版本并保存最终内容后标记已解决")
    func readsAndResolvesRealMergeConflict() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try await createConflict(fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))

        let conflict = try await provider.contentConflict(in: binding, path: "README.md")
        #expect(conflict.base == "initial fixture\n")
        #expect(conflict.local == "main side\n")
        #expect(conflict.incoming == "topic side\n")
        #expect(conflict.working.contains("<<<<<<<"))

        let result = try await provider.resolveContentConflict(
            .init(path: conflict.path, stateToken: conflict.stateToken, content: "kept both\n"), in: binding
        )
        #expect(result.outcome == .succeeded)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "kept both\n")
        let staged = try requireSuccess(try await fixture.run(executable: "git", arguments: ["diff", "--cached", "--name-only"], directory: fixture.gitReader), tool: "git")
        #expect(staged.output.trimmingCharacters(in: .whitespacesAndNewlines) == "README.md")
        let status = try requireSuccess(try await fixture.run(executable: "git", arguments: ["status", "--porcelain"], directory: fixture.gitReader), tool: "git")
        #expect(!status.output.contains("UU"))
    }

    @Test("工作文件变化后拒绝过期冲突令牌")
    func rejectsStaleConflictToken() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try await createConflict(fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let conflict = try await provider.contentConflict(in: binding, path: "README.md")
        try "changed outside editor\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try await provider.resolveContentConflict(
            .init(path: conflict.path, stateToken: conflict.stateToken, content: "stale result\n"), in: binding
        )
        #expect(result.outcome == .failed)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "changed outside editor\n")
    }

    private func createConflict(_ fixture: LocalRepositoryFixture) async throws {
        try await success("git", ["checkout", "-b", "topic"], in: fixture.gitReader, fixture: fixture)
        try "topic side\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success("git", ["commit", "-am", "topic"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["checkout", "main"], in: fixture.gitReader, fixture: fixture)
        try "main side\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success("git", ["commit", "-am", "main"], in: fixture.gitReader, fixture: fixture)
        let merge = try await fixture.run(executable: "git", arguments: ["merge", "topic"], directory: fixture.gitReader)
        #expect(merge.exitCode != 0)
    }

    private func configure(_ fixture: LocalRepositoryFixture) async throws {
        try await success("git", ["config", "user.name", "Fixture"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["config", "user.email", "fixture@example.invalid"], in: fixture.gitReader, fixture: fixture)
    }

    private func success(_ executable: String, _ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
}
