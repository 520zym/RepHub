import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("GitProvider")
struct GitProviderTests {

    @Test("获取不改工作区，更新仅允许快进")
    func fetchThenFastForwardUpdate() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await commitAndPush("remote update\n", to: "README.md", in: fixture.gitWriter, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let fetched = try await provider.perform(.fetch, in: binding, progress: { _ in })
        expectSucceeded(fetched)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "initial fixture\n")

        let updated = try await provider.perform(.update, in: binding, progress: { _ in })
        expectSucceeded(updated)
        #expect(updated.changedFiles.contains { $0.path == "README.md" && $0.kind == .modified })
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "remote update\n")
    }

    @Test("有已跟踪本地修改时拒绝更新且不覆盖文件")
    func refusesTrackedLocalChanges() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await commitAndPush("remote update\n", to: "README.md", in: fixture.gitWriter, fixture: fixture)
        try "local change\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let result = try await provider.perform(.update, in: binding, progress: { _ in })
        expectFailed(result)
        #expect(result.details.contains("本地修改"))
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "local change\n")
    }

    @Test("分叉和未跟踪同名文件均拒绝更新")
    func refusesDivergenceAndUntrackedCollision() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))

        try "local commit\n".write(to: fixture.gitReader.appendingPathComponent("local.md"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "local.md"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-m", "local commit"], in: fixture.gitReader, fixture: fixture)
        try await commitAndPush("remote update\n", to: "README.md", in: fixture.gitWriter, fixture: fixture)
        let divergent = try await provider.perform(.update, in: binding, progress: { _ in })
        expectFailed(divergent)
        #expect(divergent.details.contains("分叉"))

        // 用新的隔离设施验证未跟踪文件；避免分叉状态干扰该安全检查。
        let collisionFixture = try await LocalRepositoryFixture.create()
        defer { try? collisionFixture.remove() }
        let collisionProvider = GitProvider(runner: collisionFixture.runner)
        let collisionBinding = try #require(await collisionProvider.detect(at: collisionFixture.gitReader))
        try "keep local\n".write(to: collisionFixture.gitReader.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try await commitAndPush("remote file\n", to: "new.md", in: collisionFixture.gitWriter, fixture: collisionFixture)
        let collision = try await collisionProvider.perform(.update, in: collisionBinding, progress: { _ in })
        expectFailed(collision)
        #expect(collision.details.contains("未跟踪文件"))
        #expect(try String(contentsOf: collisionFixture.gitReader.appendingPathComponent("new.md"), encoding: .utf8) == "keep local\n")
    }

    @Test("忽略的同名本地文件不能被 Git 更新覆盖")
    func refusesIgnoredPathCollision() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let exclude = fixture.gitReader.appendingPathComponent(".git/info/exclude")
        try "*.ignored\n".write(to: exclude, atomically: true, encoding: .utf8)
        let protected = fixture.gitReader.appendingPathComponent("protected.ignored")
        try "keep ignored local file\n".write(to: protected, atomically: true, encoding: .utf8)
        try await commitAndPush("remote file\n", to: "protected.ignored", in: fixture.gitWriter, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let result = try await provider.perform(.update, in: binding, progress: { _ in })
        expectFailed(result)
        #expect(result.details.contains("未跟踪文件"))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "keep ignored local file\n")
    }

    @Test("Git 与 SVN 共管目录中的 .svn 元数据不阻塞 Git 快进更新")
    func updatesDualWorkingCopyWithoutTreatingSVNMetadataAsConflict() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let dualRemote = fixture.root.appendingPathComponent("remotes/dual-origin.git", isDirectory: true)
        let writer = fixture.root.appendingPathComponent("dual-writer", isDirectory: true)
        try await success("git", ["clone", dualRemote.path, writer.path], fixture: fixture)
        try await success("git", ["checkout", "main"], in: writer, fixture: fixture)
        try await configureAuthor(in: writer, fixture: fixture)
        try await commitAndPush("dual remote update\n", to: "README.md", in: writer, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.dualWorkingCopy))
        let result = try await provider.perform(.update, in: binding, progress: { _ in })
        expectSucceeded(result)
        #expect(FileManager.default.fileExists(atPath: fixture.dualWorkingCopy.appendingPathComponent(".svn").path))
        #expect(try String(contentsOf: fixture.dualWorkingCopy.appendingPathComponent("README.md"), encoding: .utf8) == "dual remote update\n")
    }

    @Test("分支跟踪非 origin 远端时显示并更新该远端")
    func usesCurrentBranchConfiguredRemoteInsteadOfOrigin() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let otherRemote = fixture.root.appendingPathComponent("remotes/other.git", isDirectory: true)
        let otherWriter = fixture.root.appendingPathComponent("other-writer", isDirectory: true)
        try await success("git", ["init", "--bare", otherRemote.path], fixture: fixture)
        try await success("git", ["clone", fixture.gitRemote.path, otherWriter.path], fixture: fixture)
        try await success("git", ["checkout", "main"], in: otherWriter, fixture: fixture)
        try await configureAuthor(in: otherWriter, fixture: fixture)
        try await success("git", ["remote", "add", "other", otherRemote.path], in: otherWriter, fixture: fixture)
        try await success("git", ["push", "-u", "other", "main"], in: otherWriter, fixture: fixture)
        try await commitAndPush("other remote update\n", to: "README.md", in: otherWriter, remote: "other", fixture: fixture)

        try await success("git", ["remote", "add", "other", otherRemote.path], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["fetch", "other", "refs/heads/main:refs/remotes/other/main"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["branch", "--set-upstream-to=other/main", "main"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        #expect(binding.remoteURL == otherRemote.path)

        let result = try await provider.perform(.update, in: binding, progress: { _ in })
        expectSucceeded(result)
        #expect(try String(contentsOf: fixture.gitReader.appendingPathComponent("README.md"), encoding: .utf8) == "other remote update\n")
    }

    @Test("空 Git 仓库可识别且没有历史")
    func detectsEmptyRepository() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try git(["init", "-q"], in: directory)

        let provider = GitProvider()
        let binding = try #require(await provider.detect(at: directory))
        #expect(binding.currentBranch.isEmpty || binding.currentBranch == "main" || binding.currentBranch == "master")
        #expect(try await provider.history(in: binding, limit: 20, reference: nil).isEmpty)
        #expect(try await provider.status(in: binding).isEmpty)
    }

    @Test("状态与差异保留空格和换行路径")
    func readsSpecialPaths() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try git(["init", "-q"], in: directory)
        try git(["config", "user.name", "RepHub Test"], in: directory)
        try git(["config", "user.email", "test@example.invalid"], in: directory)
        let tracked = directory.appendingPathComponent("tracked file.txt")
        try "before\n".write(to: tracked, atomically: true, encoding: .utf8)
        try git(["add", "--", "tracked file.txt"], in: directory)
        try git(["commit", "-qm", "initial commit"], in: directory)

        let specialName = "new\nfile.txt"
        try "new file\n".write(to: directory.appendingPathComponent(specialName), atomically: true, encoding: .utf8)
        try "after\n".write(to: tracked, atomically: true, encoding: .utf8)

        let provider = GitProvider()
        let binding = try #require(await provider.detect(at: directory.appendingPathComponent("child", isDirectory: true).deletingLastPathComponent()))
        let changes = try await provider.status(in: binding)
        #expect(changes.contains { $0.path == specialName && $0.kind == .untracked })
        #expect(changes.contains { $0.path == "tracked file.txt" && $0.kind == .modified })
        let patch = try await provider.diff(in: binding, path: specialName, revision: nil)
        #expect(patch.text.contains("new file.txt") || patch.text.contains("new\\nfile.txt"))
        let history = try await provider.history(in: binding, limit: 10, reference: nil)
        #expect(history.first?.parents.isEmpty == true)
        let branches = try await provider.branches(in: binding)
        #expect(branches.contains { $0.kind == .local && $0.isCurrent })
    }

    @Test("根提交、合并提交和游离 HEAD 都可读取")
    func readsGraphBoundaries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try configuredRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try git(["add", "--", "base.txt"], in: directory)
        try git(["commit", "-qm", "root"], in: directory)
        try git(["checkout", "-qb", "feature"], in: directory)
        try "feature\n".write(to: directory.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try git(["add", "--", "feature.txt"], in: directory)
        try git(["commit", "-qm", "feature"], in: directory)
        try git(["checkout", "-"], in: directory)
        try "main\n".write(to: directory.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try git(["add", "--", "main.txt"], in: directory)
        try git(["commit", "-qm", "main"], in: directory)
        try git(["merge", "--no-ff", "feature", "-m", "merge feature"], in: directory)

        let provider = GitProvider()
        let binding = try #require(await provider.detect(at: directory))
        let beforeDetached = try await provider.history(in: binding, limit: 20, reference: nil)
        let root = try #require(beforeDetached.last(where: { $0.subject == "root" }))
        let rootFiles = try await provider.changedFiles(in: binding, revision: root.id)
        let rootPatch = try await provider.diff(in: binding, path: "base.txt", revision: root.id)
        #expect(rootFiles.contains { $0.path == "base.txt" })
        #expect(rootPatch.text.contains("base.txt"))
        let merge = try #require(beforeDetached.first(where: { $0.subject == "merge feature" }))
        #expect(merge.parents.count == 2)
        let mergeFiles = try await provider.changedFiles(in: binding, revision: merge.id)
        #expect(mergeFiles.contains { $0.path == "feature.txt" })

        try git(["checkout", "--detach"], in: directory)
        try "detached\n".write(to: directory.appendingPathComponent("detached.txt"), atomically: true, encoding: .utf8)
        try git(["add", "--", "detached.txt"], in: directory)
        try git(["commit", "-qm", "detached head"], in: directory)
        let detachedHistory = try await provider.history(in: binding, limit: 20, reference: nil)
        #expect(detachedHistory.contains { $0.subject == "detached head" })
    }

    @Test("空仓库暂存后继续编辑仍显示工作区差异")
    func readsUnbornStagedAndUnstagedDiff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try configuredRepository(at: directory)
        let file = directory.appendingPathComponent("draft.txt")
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "--", "draft.txt"], in: directory)
        try "worktree\n".write(to: file, atomically: true, encoding: .utf8)

        let provider = GitProvider()
        let binding = try #require(await provider.detect(at: directory))
        let patch = try await provider.diff(in: binding, path: "draft.txt", revision: nil)
        #expect(patch.text.contains("staged"))
        #expect(patch.text.contains("worktree"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func configuredRepository(at directory: URL) throws {
        try git(["init", "-q"], in: directory)
        try git(["config", "user.name", "RepHub Test"], in: directory)
        try git(["config", "user.email", "test@example.invalid"], in: directory)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.git(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    private enum FixtureError: Error { case git(String) }

    private func commitAndPush(_ content: String, to path: String, in directory: URL, remote: String = "origin", fixture: LocalRepositoryFixture) async throws {
        try content.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await success("git", ["add", "--", path], in: directory, fixture: fixture)
        try await success("git", ["commit", "-m", "fixture remote update"], in: directory, fixture: fixture)
        try await success("git", ["push", remote, "HEAD:main"], in: directory, fixture: fixture)
    }

    private func success(_ executable: String, _ arguments: [String], in directory: URL? = nil, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }

    private func configureAuthor(in directory: URL, fixture: LocalRepositoryFixture) async throws {
        try await success("git", ["config", "user.name", "RepHub Fixture"], in: directory, fixture: fixture)
        try await success("git", ["config", "user.email", "fixture@localhost"], in: directory, fixture: fixture)
    }

    private func expectSucceeded(_ result: RepositoryOperationResult) {
        guard case .succeeded = result.outcome else {
            Issue.record("预期操作成功，实际为：\(result.summary) / \(result.details)")
            return
        }
    }

    private func expectFailed(_ result: RepositoryOperationResult) {
        guard case .failed = result.outcome else {
            Issue.record("预期操作被拒绝，实际为：\(result.summary) / \(result.details)")
            return
        }
    }
}
