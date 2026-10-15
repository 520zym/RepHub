import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("现有 SVN 工作副本迁入 Git 集成")
struct WorkingCopyMigrationIntegrationTests {
    @Test("初次原地迁移只在确认后安装 Git，补迁保留 Git 独立提交且不更新 SVN")
    func migratesWorkingCopyThenSupplementsWithoutUpdatingSVN() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = try await emptyGitRemote("working-copy-target.git", fixture: fixture)
        let service = service(for: fixture)

        // 把首次迁移固定到原工作副本统一后的 r3；未跟踪文件允许保留在原目录。
        try "r3 from svn\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await svn(["commit", "-m", "svn initial cutover"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["update"], in: fixture.svnReader, fixture: fixture)
        let preserved = fixture.svnReader.appendingPathComponent("本地未跟踪.txt")
        let preservedBytes = Data("保留此本地文件\n".utf8)
        try preservedBytes.write(to: preserved)
        let initialReadme = try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md"))
        let initialWCDB = try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db"))
        let initialRevision = try await svnRevision(fixture.svnReader, fixture: fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.svnReader.appendingPathComponent(".git").path))

        let initialPlan = try await service.plan(
            at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
            action: .initial, progress: { _ in }
        )
        let initialPreview = try await service.prepare(initialPlan, progress: { _ in })
        let stagingChildren = try FileManager.default.contentsOfDirectory(atPath: initialPreview.repository.deletingLastPathComponent().path)
        #expect(stagingChildren.filter { $0.hasPrefix("source-") }.count == 1)
        #expect(stagingChildren.filter { $0.hasPrefix("verified-") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.svnReader.appendingPathComponent(".git").path))
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md")) == initialReadme)
        #expect(try Data(contentsOf: preserved) == preservedBytes)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db")) == initialWCDB)
        let initialFile = try await service.filePreview(initialPreview, path: "README.md")
        #expect(initialFile.sourceText == "r3 from svn\n")
        _ = try await service.historyPatch(initialPreview, commit: try #require(initialPreview.mappings.last).targetCommit)

        let initialResult = try await service.applyAndPublish(initialPreview, progress: { _ in })
        #expect(initialResult.publication.state == .published)
        #expect(FileManager.default.fileExists(atPath: fixture.svnReader.appendingPathComponent(".git").path))
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md")) == initialReadme)
        #expect(try Data(contentsOf: preserved) == preservedBytes)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db")) == initialWCDB)
        #expect(try await svnRevision(fixture.svnReader, fixture: fixture) == initialRevision)
        let initialRecord = try #require(try await service.readRecord(at: fixture.svnReader))
        #expect(initialRecord.lastRevision == initialPlan.source.anchor)
        #expect(initialRecord.cutoverRevision == initialRevision)
        #expect(try await gitBindingExists(in: fixture.svnReader, fixture: fixture))
        #expect(try await svnBindingExists(in: fixture.svnReader, fixture: fixture))
        let initialRemoteLog = try await gitOutput(["--git-dir", target.path, "log", "-1", "--format=%B", "refs/heads/main"], in: fixture.root, fixture: fixture)
        #expect(initialRemoteLog.contains(initialRecord.sourceURL))
        #expect(initialRemoteLog.contains("RepHub-SVN-Revision:"))
        #expect(initialRemoteLog.contains("RepHub-SVN-Start: \(initialRecord.startRevision)"))

        // SVN 新提交来自另一个工作副本；原目录保持 r3，不调用 svn update。
        let secondWorkingCopy = fixture.root.appendingPathComponent("second-svn-working-copy", isDirectory: true)
        try await svn(["checkout", fixture.svnURL.absoluteURL.absoluteString, secondWorkingCopy.path], in: fixture.root, fixture: fixture)
        try "r4 from second working copy\n".write(to: secondWorkingCopy.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await svn(["commit", "-m", "svn supplement from second working copy"], in: secondWorkingCopy, fixture: fixture)

        // Git 也在同一期间前进；补迁预览必须以它为基线，而不能用 SVN 全树覆盖。
        try await configureGitIdentity(in: fixture.svnReader, fixture: fixture)
        try "independent git work\n".write(to: fixture.svnReader.appendingPathComponent("独立Git文件.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "独立Git文件.txt"], in: fixture.svnReader, fixture: fixture)
        try await git(["commit", "-m", "independent git commit"], in: fixture.svnReader, fixture: fixture)
        try await git(["push", target.absoluteURL.absoluteString, "HEAD:refs/heads/main"], in: fixture.svnReader, fixture: fixture)
        let beforeSupplementHead = try await gitHead(in: fixture.svnReader, fixture: fixture)
        let beforeSupplementWCDB = try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db"))
        #expect(try await svnRevision(fixture.svnReader, fixture: fixture) == initialRevision)

        let supplementPlan = try await service.plan(
            at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
            action: .supplement, progress: { _ in }
        )
        #expect(supplementPlan.source.revisions.count == 1)
        let supplementPreview = try await service.prepare(supplementPlan, progress: { _ in })
        #expect(try await gitHead(in: fixture.svnReader, fixture: fixture) == beforeSupplementHead)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db")) == beforeSupplementWCDB)
        #expect(FileManager.default.fileExists(atPath: supplementPreview.repository.appendingPathComponent("独立Git文件.txt").path))
        #expect(try String(contentsOf: supplementPreview.repository.appendingPathComponent("README.md"), encoding: .utf8) == "r4 from second working copy\n")

        let supplementResult = try await service.applyAndPublish(supplementPreview, progress: { _ in })
        #expect(supplementResult.publication.state == .published)
        let finalRecord = try #require(try await service.readRecord(at: fixture.svnReader))
        #expect(finalRecord.lastRevision == supplementPlan.source.anchor)
        #expect(finalRecord.mappings.count == initialRecord.mappings.count + 1)
        let finalLocalHead = try await gitHead(in: fixture.svnReader, fixture: fixture)
        let finalRemoteHead = try #require(await remoteBranch(target, branch: "main", fixture: fixture))
        #expect(finalLocalHead == finalRemoteHead)
        #expect(try await svnRevision(fixture.svnReader, fixture: fixture) == initialRevision)

        // 没有新的 SVN 修订时不能生成重复补迁提交。
        await #expect(throws: VersionControlError.self) {
            try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                   action: .supplement, progress: { _ in })
        }
    }

    @Test("初始 SVN 脏工作副本与补迁 Git 脏工作副本都会在预检阶段拒绝")
    func rejectsDirtyWorkingCopiesBeforeWritingMetadataOrRemote() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = try await emptyGitRemote("dirty-target.git", fixture: fixture)
        let service = service(for: fixture)

        try "local svn change\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        await #expect(throws: VersionControlError.self) {
            try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                   action: .initial, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.svnReader.appendingPathComponent(".git").path))
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)
        try await svn(["revert", "README.md"], in: fixture.svnReader, fixture: fixture)

        let initial = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                             action: .initial, progress: { _ in })
        let preview = try await service.prepare(initial, progress: { _ in })
        _ = try await service.applyAndPublish(preview, progress: { _ in })
        // 未跟踪且不冲突的文件可以保留；这里特意改已跟踪文件，验证补迁确实拒绝 Git 脏状态。
        try "uncommitted tracked git change\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        await #expect(throws: VersionControlError.self) {
            try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                   action: .supplement, progress: { _ in })
        }
        let dirtyRemoteHead = try await remoteBranch(target, branch: "main", fixture: fixture)
        let dirtyLocalHead = try await gitHead(in: fixture.svnReader, fixture: fixture)
        #expect(dirtyRemoteHead == dirtyLocalHead)
    }

    @Test("补迁预览冲突或远端在预览后推进时，不覆盖原 Git 或远端")
    func protectsOriginalAndRemoteFromConflictAndRace() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = try await emptyGitRemote("conflict-target.git", fixture: fixture)
        let service = service(for: fixture)
        let initial = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                             action: .initial, progress: { _ in })
        let initialPreview = try await service.prepare(initial, progress: { _ in })
        _ = try await service.applyAndPublish(initialPreview, progress: { _ in })
        try await configureGitIdentity(in: fixture.svnReader, fixture: fixture)

        // Git 和第二个 SVN 工作副本改同一行，准备补迁只能在隔离预览中失败。
        try "git conflicting line\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "README.md"], in: fixture.svnReader, fixture: fixture)
        try await git(["commit", "-m", "git conflicting commit"], in: fixture.svnReader, fixture: fixture)
        try await git(["push", target.absoluteURL.absoluteString, "HEAD:refs/heads/main"], in: fixture.svnReader, fixture: fixture)
        let beforeHead = try await gitHead(in: fixture.svnReader, fixture: fixture)
        let beforeWCDB = try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db"))
        let beforeRemote = try await remoteBranch(target, branch: "main", fixture: fixture)
        let second = fixture.root.appendingPathComponent("conflict-second", isDirectory: true)
        try await svn(["checkout", fixture.svnURL.absoluteURL.absoluteString, second.path], in: fixture.root, fixture: fixture)
        try "svn conflicting line\n".write(to: second.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await svn(["commit", "-m", "svn conflicting commit"], in: second, fixture: fixture)

        let conflictPlan = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                                  action: .supplement, progress: { _ in })
        await #expect(throws: VersionControlError.self) {
            try await service.prepare(conflictPlan, progress: { _ in })
        }
        #expect(try await gitHead(in: fixture.svnReader, fixture: fixture) == beforeHead)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db")) == beforeWCDB)
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == beforeRemote)
    }

    @Test("远端在补迁预览后推进时，确认发布拒绝覆盖该远端提交")
    func refusesToOverwriteRemoteAdvancedAfterSupplementPreview() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = try await emptyGitRemote("race-target.git", fixture: fixture)
        let service = service(for: fixture)
        let preserved = fixture.svnReader.appendingPathComponent("initial-untracked-note.txt")
        let preservedBytes = Data("this file stays outside both histories\n".utf8)
        try preservedBytes.write(to: preserved)
        let initial = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                             action: .initial, progress: { _ in })
        let initialPreview = try await service.prepare(initial, progress: { _ in })
        _ = try await service.applyAndPublish(initialPreview, progress: { _ in })

        let second = fixture.root.appendingPathComponent("race-second", isDirectory: true)
        try await svn(["checkout", fixture.svnURL.absoluteURL.absoluteString, second.path], in: fixture.root, fixture: fixture)
        try "svn new revision\n".write(to: second.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await svn(["commit", "-m", "svn revision for remote race"], in: second, fixture: fixture)
        let supplement = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                                action: .supplement, progress: { _ in })
        let preview = try await service.prepare(supplement, progress: { _ in })
        let beforeApplyHead = try await gitHead(in: fixture.svnReader, fixture: fixture)
        let beforeApplyReadme = try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md"))
        let beforeApplyWCDB = try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db"))

        let racer = fixture.root.appendingPathComponent("remote-racer", isDirectory: true)
        try await git(["clone", target.path, racer.path], in: fixture.root, fixture: fixture)
        try await git(["checkout", "-b", "main", "origin/main"], in: racer, fixture: fixture)
        try await configureGitIdentity(in: racer, fixture: fixture)
        try "remote wins the race\n".write(to: racer.appendingPathComponent("remote-race.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "remote-race.txt"], in: racer, fixture: fixture)
        try await git(["commit", "-m", "remote advanced after preview"], in: racer, fixture: fixture)
        try await git(["push", "origin", "HEAD:refs/heads/main"], in: racer, fixture: fixture)
        let remoteTip = try #require(await remoteBranch(target, branch: "main", fixture: fixture))
        #expect(remoteTip != preview.tip)

        await #expect(throws: VersionControlError.self) {
            try await service.applyAndPublish(preview, progress: { _ in })
        }
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == remoteTip)
        #expect(try await gitHead(in: fixture.svnReader, fixture: fixture) == beforeApplyHead)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md")) == beforeApplyReadme)
        #expect(try Data(contentsOf: fixture.svnReader.appendingPathComponent(".svn/wc.db")) == beforeApplyWCDB)
        #expect(try Data(contentsOf: preserved) == preservedBytes)
    }

    @Test("应用已真实完成但确认响应丢失时，初次与补迁重试不会重复生成提交")
    func retriesInitialAndSupplementAfterPostApplyFailureWithoutDuplicateCommits() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let target = try await emptyGitRemote("post-apply-failure-target.git", fixture: fixture)
        let faultTarget = FailOnceAfterWorkingCopyApplyTarget(base: GitMigrationTargetProvider(runner: fixture.runner))
        let service = WorkingCopyMigrationService(source: SVNProvider(runner: fixture.runner), target: faultTarget)

        let initialPlan = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                                 action: .initial, progress: { _ in })
        let initialPreview = try await service.prepare(initialPlan, progress: { _ in })
        await #expect(throws: VersionControlError.self) {
            try await service.applyAndPublish(initialPreview, progress: { _ in })
        }
        let initialCountAfterFailure = try await gitCommitCount(in: fixture.svnReader, fixture: fixture)
        #expect(initialCountAfterFailure == initialPreview.mappings.count)
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)

        let initialRetry = try await service.applyAndPublish(initialPreview, progress: { _ in })
        #expect(initialRetry.publication.state == .published)
        #expect(try await gitCommitCount(in: fixture.svnReader, fixture: fixture) == initialCountAfterFailure)
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == initialPreview.tip)

        let second = fixture.root.appendingPathComponent("post-apply-second-svn", isDirectory: true)
        try await svn(["checkout", fixture.svnURL.absoluteURL.absoluteString, second.path], in: fixture.root, fixture: fixture)
        try "supplement after response loss\n".write(to: second.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await svn(["commit", "-m", "svn supplement after post apply failure"], in: second, fixture: fixture)
        await faultTarget.failNextApply()
        let supplementPlan = try await service.plan(at: fixture.svnReader, remoteURL: target.absoluteURL.absoluteString, branch: "main", mode: .history,
                                                    action: .supplement, progress: { _ in })
        let supplementPreview = try await service.prepare(supplementPlan, progress: { _ in })
        await #expect(throws: VersionControlError.self) {
            try await service.applyAndPublish(supplementPreview, progress: { _ in })
        }
        let supplementCountAfterFailure = try await gitCommitCount(in: fixture.svnReader, fixture: fixture)
        #expect(supplementCountAfterFailure == supplementPreview.mappings.count)
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == initialPreview.tip)

        let supplementRetry = try await service.applyAndPublish(supplementPreview, progress: { _ in })
        #expect(supplementRetry.publication.state == .published)
        #expect(try await gitCommitCount(in: fixture.svnReader, fixture: fixture) == supplementCountAfterFailure)
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == supplementPreview.tip)
        let record = try #require(try await service.readRecord(at: fixture.svnReader))
        #expect(record.mappings.count == supplementPreview.mappings.count)
    }

    private func service(for fixture: LocalRepositoryFixture) -> WorkingCopyMigrationService {
        WorkingCopyMigrationService(source: SVNProvider(runner: fixture.runner), target: GitMigrationTargetProvider(runner: fixture.runner))
    }

    private func emptyGitRemote(_ name: String, fixture: LocalRepositoryFixture) async throws -> URL {
        let remote = fixture.root.appendingPathComponent("remotes/\(name)", isDirectory: true)
        try await git(["init", "--bare", remote.path], in: fixture.root, fixture: fixture)
        return remote
    }

    private func requireTools() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil, ToolLocator.find("git") != nil else { throw FixtureError.toolUnavailable }
    }

    private func configureGitIdentity(in directory: URL, fixture: LocalRepositoryFixture) async throws {
        try await git(["config", "user.name", "Working Copy Fixture"], in: directory, fixture: fixture)
        try await git(["config", "user.email", "working-copy-fixture@example.invalid"], in: directory, fixture: fixture)
    }

    private func svn(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: arguments, directory: directory), tool: "svn")
    }

    private func git(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: directory), tool: "git")
    }

    private func gitOutput(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: directory), tool: "git").output
    }

    private func gitHead(in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try await gitOutput(["rev-parse", "HEAD"], in: directory, fixture: fixture).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitCommitCount(in directory: URL, fixture: LocalRepositoryFixture) async throws -> Int {
        let value = try await gitOutput(["rev-list", "--count", "HEAD"], in: directory, fixture: fixture)
        guard let count = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FixtureError.invalidCommitCount
        }
        return count
    }

    private func remoteRefs(_ remote: URL, fixture: LocalRepositoryFixture) async throws -> [String] {
        let value = try await gitOutput(["ls-remote", "--refs", "--", remote.absoluteURL.absoluteString], in: fixture.root, fixture: fixture)
        return value.split(separator: "\n").map(String.init)
    }

    private func remoteBranch(_ remote: URL, branch: String, fixture: LocalRepositoryFixture) async throws -> String? {
        let refs = try await remoteRefs(remote, fixture: fixture)
        return refs.first { $0.hasSuffix("refs/heads/\(branch)") }?.split(separator: "\t").first.map(String.init)
    }

    private func svnRevision(_ directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        let revision = try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["info", "--show-item", "revision"], directory: directory), tool: "svn"
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "r\(revision)"
    }

    private func gitBindingExists(in directory: URL, fixture: LocalRepositoryFixture) async throws -> Bool {
        (try await gitOutput(["rev-parse", "--is-inside-work-tree"], in: directory, fixture: fixture))
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func svnBindingExists(in directory: URL, fixture: LocalRepositoryFixture) async throws -> Bool {
        (try await fixture.run(executable: "svn", arguments: ["info", "--show-item", "wc-root"], directory: directory)).exitCode == 0
    }

    private enum FixtureError: Error { case toolUnavailable, invalidCommitCount }
}

/// 将真实 Git 应用完成后的响应丢失建模为一次失败。用于验证服务在记录写入边界可安全重试。
private actor FailOnceAfterWorkingCopyApplyTarget: RepositoryWorkingCopyMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    private let base: GitMigrationTargetProvider
    private var failNext = true

    init(base: GitMigrationTargetProvider) { self.base = base }

    func failNextApply() { failNext = true }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws { try await base.checkMigrationTarget(remoteURL: remoteURL, branch: branch) }
    func initializeMigration(at directory: URL, branch: String) async throws { try await base.initializeMigration(at: directory, branch: branch) }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        try await base.appendMigrationSnapshot(from: snapshot, revision: revision, author: author, to: directory, progress: progress)
    }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws { try await base.verifyMigration(at: directory, expectedTip: expectedTip, branch: branch) }
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws { try await base.verifyMigrationCheckpoint(at: directory, expectedTip: expectedTip, branch: branch) }
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws { try await base.exportMigrationTree(at: directory, revision: revision, to: destination) }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { try await base.migrationPatch(at: directory, revision: revision) }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        try await base.publishMigration(at: directory, remoteURL: remoteURL, branch: branch, expectedTip: expectedTip, progress: progress)
    }
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws { try await base.verifyWorkingCopyMigrationRecord(at: directory, record: record) }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? {
        try await base.inspectWorkingCopyMigrationTarget(at: directory, branch: branch, previousMigrationTip: previousMigrationTip)
    }
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws { try await base.checkWorkingCopyMigrationRemote(remoteURL: remoteURL, branch: branch, expectedTip: expectedTip) }
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {
        try await base.prepareWorkingCopyMigrationTarget(from: directory, expectedTip: expectedTip, to: preview, branch: branch)
    }
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        try await base.appendWorkingCopyMigrationDelta(before: before, after: after, revision: revision, author: author, to: preview, progress: progress)
    }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {
        let shouldFail = failNext
        failNext = false
        try await base.applyWorkingCopyMigration(from: preview, to: directory, expectedBeforeTip: expectedBeforeTip, expectedTip: expectedTip, branch: branch, record: record)
        if shouldFail { throw VersionControlError.executionFailed("模拟：Git 已完成应用，但确认响应在返回前丢失。") }
    }
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        try await base.publishWorkingCopyMigration(at: directory, remoteURL: remoteURL, branch: branch, expectedBeforeTip: expectedBeforeTip, expectedTip: expectedTip, progress: progress)
    }
}
