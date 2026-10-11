import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 提交")
struct GitCommitTests {
    @Test("只提交所选工作区文件并保留未选暂存内容")
    func commitsOnlySelectedFilesAndPreservesIndex() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(in: fixture.gitReader, fixture: fixture)
        try "selected current\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "must stay staged\n".write(to: fixture.gitReader.appendingPathComponent("staged.md"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "--", "staged.md"], in: fixture.gitReader, fixture: fixture)
        try "unselected worktree\n".write(to: fixture.gitReader.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let selected = try #require(prepared.files.first { $0.change.path == "README.md" })
        let preview = try await provider.commitDiff(in: binding, file: selected)
        #expect(preview.text.contains("selected current"))

        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: [selected], message: "只提交选中内容"),
            in: binding,
            progress: { _ in }
        )
        #expect(result.outcome == .succeeded)
        #expect(result.revisionID != nil)
        let names = try await output("git", ["show", "--format=", "--name-only", "HEAD"], in: fixture.gitReader, fixture: fixture)
        #expect(names.split(whereSeparator: \.isNewline).map(String.init) == ["README.md"])
        let staged = try await output("git", ["diff", "--cached", "--name-only"], in: fixture.gitReader, fixture: fixture)
        #expect(staged.split(whereSeparator: \.isNewline).map(String.init).contains("staged.md"))
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "selected current\n")
    }

    @Test("未跟踪文件预览使用当前工作区内容")
    func previewsUntrackedFileWithHead() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "untracked preview\n".write(to: fixture.gitReader.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let file = try #require(prepared.files.first { $0.change.path == "new.md" && $0.change.kind == .untracked })
        let preview = try await provider.commitDiff(in: binding, file: file)
        #expect(preview.text.contains("untracked preview"))
        #expect(preview.text.contains("new.md"))
    }

    @Test("首个提交支持新增和删除")
    func commitsNewAndDeletedFiles() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(in: fixture.gitReader, fixture: fixture)
        try FileManager.default.removeItem(at: fixture.gitReader.appendingPathComponent("README.md"))
        try "new file\n".write(to: fixture.gitReader.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let files = prepared.files.filter { ["README.md", "new.md"].contains($0.change.path) }
        #expect(files.count == 2)
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: files, message: "新增并删除"),
            in: binding,
            progress: { _ in }
        )
        #expect(result.outcome == .succeeded)
        let names = try await output("git", ["show", "--format=", "--name-status", "HEAD"], in: fixture.gitReader, fixture: fixture)
        #expect(names.contains("D\tREADME.md"))
        #expect(names.contains("A\tnew.md"))
    }

    @Test("重命名会同时更新旧路径和新路径")
    func commitsRename() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(in: fixture.gitReader, fixture: fixture)
        try "rename me\n".write(to: fixture.gitReader.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "--", "old.md"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "add old"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["mv", "old.md", "new.md"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let renamed = try #require(prepared.files.first { $0.change.path == "new.md" && $0.change.originalPath == "old.md" })
        let result = try await provider.commit(RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: [renamed], message: "rename"), in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded)
        let names = try await output("git", ["show", "--format=", "--name-status", "HEAD"], in: fixture.gitReader, fixture: fixture)
        #expect(names.contains("old.md"))
        #expect(names.contains("new.md"))
    }

    @Test("首个提交只提交所选新增文件")
    func commitsSelectedFilesInUnbornRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-UpdateFixture-commit-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = CommandRunner(isolatedHome: root.appendingPathComponent("home", isDirectory: true))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.config", isDirectory: true), withIntermediateDirectories: true)
        try requireSuccess(try await runner.run(executable: "git", arguments: ["init", "-q"], directory: root), tool: "git")
        try requireSuccess(try await runner.run(executable: "git", arguments: ["config", "user.name", "Fixture"], directory: root), tool: "git")
        try requireSuccess(try await runner.run(executable: "git", arguments: ["config", "user.email", "fixture@localhost"], directory: root), tool: "git")
        try "one\n".write(to: root.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: runner)
        let binding = try #require(await provider.detect(at: root))
        let prepared = try await provider.prepareCommit(in: binding)
        let one = try #require(prepared.files.first { $0.change.path == "one.md" })
        let result = try await provider.commit(RepositoryCommitRequest(bindingID: binding.id, baseRevision: nil, files: [one], message: "first"), in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded)
        let names = try requireSuccess(try await runner.run(executable: "git", arguments: ["show", "--format=", "--name-only", "HEAD"], directory: root), tool: "git").output
        #expect(names.split(whereSeparator: \.isNewline).map(String.init) == ["one.md"])
    }

    @Test("准备后文件或暂存状态变化会拒绝提交")
    func rejectsStalePreparation() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(in: fixture.gitReader, fixture: fixture)
        try "first version\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let selected = try #require(prepared.files.first { $0.change.path == "README.md" })
        try "changed after preview\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: [selected], message: "stale"),
            in: binding,
            progress: { _ in }
        )
        #expect(result.outcome == .failed)
        let head = try await output("git", ["log", "--format=%s", "-1"], in: fixture.gitReader, fixture: fixture)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture initial commit")
    }

    @Test("准备阶段无法锁定索引时返回失败而不抛出未知结果")
    func reportsPreflightLockFailure() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await configureAuthor(in: fixture.gitReader, fixture: fixture)
        try "change\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let selected = try #require(prepared.files.first { $0.change.path == "README.md" })
        let lock = fixture.gitReader.appendingPathComponent(".git/index.lock")
        try Data("fixture lock".utf8).write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: [selected], message: "blocked"),
            in: binding,
            progress: { _ in }
        )
        #expect(result.outcome == .failed)
        #expect(result.summary.contains("未开始"))
    }

    @Test("空白提交说明不会启动 Git 提交")
    func rejectsWhitespaceOnlyMessage() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "change\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let prepared = try await provider.prepareCommit(in: binding)
        let selected = try #require(prepared.files.first { $0.change.path == "README.md" })
        let result = try await provider.commit(
            RepositoryCommitRequest(bindingID: binding.id, baseRevision: prepared.baseRevision, files: [selected], message: " \n\t "),
            in: binding,
            progress: { _ in }
        )
        #expect(result.outcome == .notStarted)
        let subject = try await output("git", ["log", "--format=%s", "-1"], in: fixture.gitReader, fixture: fixture)
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture initial commit")
    }

    private func configureAuthor(in directory: URL, fixture: LocalRepositoryFixture) async throws {
        try await success("git", ["config", "user.name", "RepHub Fixture"], in: directory, fixture: fixture)
        try await success("git", ["config", "user.email", "fixture@localhost"], in: directory, fixture: fixture)
    }

    private func success(_ executable: String, _ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }

    private func output(_ executable: String, _ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable).output
    }
}
