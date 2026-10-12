import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 工作副本迁移")
struct GitWorkingCopyMigrationTests {
    @Test("首次接入只安装 Git 元数据，保留 SVN 与未跟踪文件")
    func initialMigrationDoesNotRewriteSVNWorkingCopy() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let workingCopy = fixture.svnReader
        let before = fixture.root.appendingPathComponent("empty-before", isDirectory: true)
        let after = fixture.root.appendingPathComponent("after", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("preview", isDirectory: true)
        let remote = fixture.root.appendingPathComponent("remotes/working-copy-target.git", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        try "initial fixture\n".write(to: after.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let untracked = workingCopy.appendingPathComponent("leave-me-alone.txt")
        try "local svn-side note\n".write(to: untracked, atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["init", "--bare", remote.path]), tool: "git")

        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        let initialTip = try await provider.inspectWorkingCopyMigrationTarget(at: workingCopy, branch: "main", previousMigrationTip: nil)
        #expect(initialTip == nil)
        try await provider.prepareWorkingCopyMigrationTarget(from: workingCopy, expectedTip: nil, to: preview, branch: "main")
        let revision = MigrationRevision(id: "r2", author: "svn", date: .now, message: "initial svn import")
        let tip = try await provider.appendWorkingCopyMigrationDelta(before: before, after: after, revision: revision, author: MigrationAuthor(name: "SVN User", email: "svn@example.test"), to: preview, progress: { _ in })
        let record = try JSONEncoder().encode(WorkingCopyMigrationRecord(sourceURL: "file:///fixture", repositoryUUID: "fixture", startRevision: "2", lastRevision: "2", remoteURL: "/tmp/empty.git", branch: "main", mappings: []))
        try await provider.applyWorkingCopyMigration(from: preview, to: workingCopy, expectedBeforeTip: nil, expectedTip: tip, branch: "main", record: record)

        #expect(FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent(".svn").path))
        #expect(try String(contentsOf: untracked, encoding: .utf8) == "local svn-side note\n")
        #expect(try String(contentsOf: workingCopy.appendingPathComponent("README.md"), encoding: .utf8) == "initial fixture\n")
        #expect(FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent(".git/rephub-svn-migration.json").path))
        let exclude = try String(contentsOf: workingCopy.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".svn/"))
        let configuredRemote = try requireSuccess(try await fixture.run(executable: "git", arguments: ["remote", "get-url", "origin"], directory: workingCopy), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredUpstream = try requireSuccess(try await fixture.run(executable: "git", arguments: ["config", "--get", "branch.main.merge"], directory: workingCopy), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(configuredRemote == "/tmp/empty.git")
        #expect(configuredUpstream == "refs/heads/main")
        let published = try await provider.publishWorkingCopyMigration(at: workingCopy, remoteURL: remote.path, branch: "main", expectedBeforeTip: nil, expectedTip: tip, progress: { _ in })
        #expect(published.state == .published)
    }

    @Test("补迁要求目标远端正好位于当前 Git 提交")
    func supplementRejectsRemoteThatDoesNotMatchExpectedTip() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        let localTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        var rejected = false
        do { try await provider.checkWorkingCopyMigrationRemote(remoteURL: fixture.gitRemote.path, branch: "main", expectedTip: String(repeating: "b", count: 40)) } catch { rejected = true }
        #expect(rejected)
        try await provider.checkWorkingCopyMigrationRemote(remoteURL: fixture.gitRemote.path, branch: "main", expectedTip: localTip)
    }

    @Test("补迁发布重试发现远端已到末端时不重复推送")
    func supplementPublishIsIdempotentAfterRemoteAlreadyHasTip() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let oldTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        try "supplement\n".write(to: fixture.gitReader.appendingPathComponent("supplement.txt"), atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["add", "supplement.txt"], directory: fixture.gitReader), tool: "git")
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "supplement"], directory: fixture.gitReader), tool: "git")
        let newTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        let first = try await provider.publishWorkingCopyMigration(at: fixture.gitReader, remoteURL: fixture.gitRemote.path, branch: "main", expectedBeforeTip: oldTip, expectedTip: newTip, progress: { _ in })
        #expect(first.state == .published)
        let second = try await provider.publishWorkingCopyMigration(at: fixture.gitReader, remoteURL: fixture.gitRemote.path, branch: "main", expectedBeforeTip: oldTip, expectedTip: newTip, progress: { _ in })
        #expect(second.state == .published)
        let remoteTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["--git-dir", fixture.gitRemote.path, "rev-parse", "refs/heads/main"]), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteTip == newTip)
    }

    @Test("补迁预览只携带已提交 Git 树，拒绝不安全本地配置")
    func supplementPreviewExcludesUntrackedFilesAndRejectsUnsafeConfig() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        let tip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        try "do not copy\n".write(to: fixture.gitReader.appendingPathComponent("untracked-only.txt"), atomically: true, encoding: .utf8)
        let preview = fixture.root.appendingPathComponent("committed-tree-preview", isDirectory: true)
        try await provider.prepareWorkingCopyMigrationTarget(from: fixture.gitReader, expectedTip: tip, to: preview, branch: "main")
        #expect(!FileManager.default.fileExists(atPath: preview.appendingPathComponent("untracked-only.txt").path))
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["config", "--local", "filter.unsafe.clean", "false"], directory: fixture.gitReader), tool: "git")
        var rejected = false
        do { _ = try await provider.inspectWorkingCopyMigrationTarget(at: fixture.gitReader, branch: "main", previousMigrationTip: tip) } catch { rejected = true }
        #expect(rejected)
    }

    @Test("迁移记录末端必须与实际 Git 来源标记一致")
    func verifiesLastMappingAgainstCommitTrailers() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let message = "import r4\n\nRepHub-SVN-URL: file:///svn/trunk\nRepHub-SVN-UUID: uuid-4\nRepHub-SVN-Revision: r4\nRepHub-SVN-Start: r1\nRepHub-SVN-End: r9\nRepHub-SVN-Cutover: r3"
        let messageFile = fixture.root.appendingPathComponent("migration-message.txt")
        let sourceURL = fixture.svnURL.absoluteString
        let fixtureMessage = message.replacingOccurrences(of: "file:///svn/trunk", with: sourceURL)
        try fixtureMessage.write(to: messageFile, atomically: true, encoding: .utf8)
        try "trailers\n".write(to: fixture.gitReader.appendingPathComponent("trailers.txt"), atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["add", "trailers.txt"], directory: fixture.gitReader), tool: "git")
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-F", messageFile.path], directory: fixture.gitReader), tool: "git")
        let tip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "HEAD"], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = MigrationRevision(id: "r4", author: "svn", date: .now, message: "import r4")
        let mapping = MigrationMapping(source: source, author: MigrationAuthor(name: "SVN", email: "svn@example.test"), targetCommit: tip)
        let record = WorkingCopyMigrationRecord(sourceURL: sourceURL, repositoryUUID: "uuid-4", startRevision: "r1", lastRevision: "r9", remoteURL: fixture.gitRemote.path, branch: "main", mappings: [mapping], cutoverRevision: "r3")
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.verifyWorkingCopyMigrationRecord(at: fixture.gitReader, record: record)
        let altered = WorkingCopyMigrationRecord(sourceURL: record.sourceURL, repositoryUUID: record.repositoryUUID, startRevision: record.startRevision, lastRevision: "r10", remoteURL: record.remoteURL, branch: record.branch, mappings: record.mappings, cutoverRevision: record.cutoverRevision)
        var rejected = false
        do { try await provider.verifyWorkingCopyMigrationRecord(at: fixture.gitReader, record: altered) } catch { rejected = true }
        #expect(rejected)
    }
}
