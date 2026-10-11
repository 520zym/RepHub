import Foundation
import Testing
import GitAdapter

@Suite("GitProvider")
struct GitProviderTests {
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
}
