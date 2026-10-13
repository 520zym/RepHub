import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 按块提交")
struct GitPartialCommitTests {
    @Test("只提交所选行，并保留其他工作区和暂存内容")
    func commitsOnlySelectedLines() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(fixture)
        let readme = fixture.gitReader.appendingPathComponent("README.md")
        try "first selected\nsecond stays\n".write(to: readme, atomically: true, encoding: .utf8)
        try "already staged\n".write(to: fixture.gitReader.appendingPathComponent("kept.md"), atomically: true, encoding: .utf8)
        try await success(fixture, ["add", "--", "kept.md"])

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.preparePartialCommit(in: binding)
        let file = try #require(prepared.files.first { $0.path == "README.md" })
        #expect(file.hunks.allSatisfy { $0.header.hasPrefix("@@ -") })
        let selected = try #require(file.hunks.flatMap(\.lines).first { $0.kind == .addition && $0.text.contains("first selected") })
        let request = RepositoryPartialCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision,
                                                     stateToken: prepared.stateToken,
                                                     selections: [.init(path: file.path, fingerprint: file.fingerprint, selectedLineIDs: [selected.id])],
                                                     message: "只提交第一行")
        let preview = try await provider.previewPartialCommit(request, in: binding)
        #expect(preview.patch.text.contains("first selected"))
        #expect(!preview.patch.text.contains("second stays"))
        let result = try await provider.commitPartial(request, in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded, "\(result.summary) \(result.details)")
        let committed = try await output(fixture, ["show", "HEAD:README.md"])
        #expect(committed == "initial fixture\nfirst selected\n")
        #expect(try String(contentsOf: readme, encoding: .utf8) == "first selected\nsecond stays\n")
        let staged = try await output(fixture, ["diff", "--cached", "--name-only"])
        #expect(staged.split(whereSeparator: \.isNewline).map(String.init).contains("kept.md"))
        #expect(!staged.split(whereSeparator: \.isNewline).map(String.init).contains("README.md"))
        let remaining = try await output(fixture, ["diff", "--", "README.md"])
        #expect(remaining.contains("second stays"))
    }

    @Test("预览后工作区或暂存区变化会拒绝按块提交")
    func rejectsStaleState() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(fixture)
        let readme = fixture.gitReader.appendingPathComponent("README.md")
        try "chosen\ninitial fixture\n".write(to: readme, atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.preparePartialCommit(in: binding)
        let file = try #require(prepared.files.first { $0.path == "README.md" })
        let line = try #require(file.hunks.flatMap(\.lines).first(where: { $0.selectable }))
        let request = RepositoryPartialCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision,
                                                     stateToken: prepared.stateToken,
                                                     selections: [.init(path: file.path, fingerprint: file.fingerprint, selectedLineIDs: [line.id])],
                                                     message: "stale")
        try "changed after preview\ninitial fixture\n".write(to: readme, atomically: true, encoding: .utf8)
        let result = try await provider.commitPartial(request, in: binding, progress: { _ in })
        #expect(result.outcome == .failed)
        #expect((try await output(fixture, ["log", "-1", "--format=%s"])).trimmingCharacters(in: .whitespacesAndNewlines) == "fixture initial commit")
    }

    private func configureAuthor(_ fixture: LocalRepositoryFixture) async throws {
        try await success(fixture, ["config", "user.name", "RepHub Fixture"])
        try await success(fixture, ["config", "user.email", "fixture@localhost"])
    }
    private func success(_ fixture: LocalRepositoryFixture, _ arguments: [String]) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: fixture.gitReader), tool: "git")
    }
    private func output(_ fixture: LocalRepositoryFixture, _ arguments: [String]) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: fixture.gitReader), tool: "git").output
    }
}
