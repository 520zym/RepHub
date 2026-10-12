import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("SVN 到 Git 仓库迁移集成")
struct RepositoryMigrationIntegrationTests {
    @Test("子目录的完整 SVN 历史先生成可核对预览，显式发布后才写入空 Git 远端")
    func migratesSubdirectoryHistoryWithPreviewBeforePublication() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedMigrationModule(in: fixture)

        let target = fixture.root.appendingPathComponent("remotes/migration-target.git", isDirectory: true)
        try await git(["init", "--bare", target.path], fixture: fixture)
        let destination = fixture.root.appendingPathComponent("svn-history-preview", isDirectory: true)
        let sourceURL = fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString
        let service = migrationService(for: fixture)

        // 现有 Git 引用必须在真正读取、导出 SVN 前被拒绝，且不能覆盖既有目标。
        await #expect(throws: VersionControlError.self) {
            try await service.plan(
                sourceProviderID: .svn, location: RemoteRepositoryLocation(url: sourceURL), mode: .history,
                targetProviderID: .git, remoteURL: fixture.gitRemote.absoluteURL.absoluteString, branch: "main",
                destination: fixture.root.appendingPathComponent("must-not-exist", isDirectory: true), progress: { _ in }
            )
        }

        let plan = try await service.plan(
            sourceProviderID: .svn, location: RemoteRepositoryLocation(url: sourceURL), mode: .history,
            targetProviderID: .git, remoteURL: target.absoluteURL.absoluteString, branch: "main",
            destination: destination, progress: { _ in }
        )
        #expect(plan.source.mode == .history)
        #expect(plan.source.revisions.count == 3)
        #expect(plan.source.revisions.map(\.message) == ["创建迁移模块", "删除旧文件并更新中文说明", "更新二进制内容"])
        #expect(plan.source.revisions.allSatisfy { plan.authors[$0.author] != nil })

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.canPublish)
        #expect(preview.mappings.count == plan.source.revisions.count)
        #expect(preview.mappings.map(\.source.id) == plan.source.revisions.map(\.id))
        #expect(FileManager.default.fileExists(atPath: preview.reportURL.path))
        #expect(preview.files.contains { $0.path == "文档/说明.md" && $0.state == .identical })
        #expect(preview.files.contains { $0.path == "保留但忽略.local" && $0.state == .identical })
        #expect(preview.files.contains { $0.path == "空目录" && $0.state == .omittedDirectory })
        #expect(!preview.files.contains { $0.path == "已删除.txt" })
        #expect(preview.warnings.contains { $0.contains("空目录") })

        let text = try await service.filePreview(preview, path: "文档/说明.md")
        #expect(!text.isBinary)
        #expect(text.sourceText == "第二版：中文文件仍可读取。\n")
        #expect(text.targetText == text.sourceText)
        let binary = try await service.filePreview(preview, path: "二进制数据.bin")
        #expect(binary.isBinary)
        let latestPatch = try await service.historyPatch(preview, commit: try #require(preview.mappings.last).targetCommit)
        #expect(latestPatch.text.contains("二进制数据.bin"))

        // prepare 只在独立目录生成 Git 对象；远端仍是空仓库。
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)
        #expect(try await svnStatus(fixture).isEmpty)

        let targetMessages = try await gitOutput(["log", "--reverse", "--format=%s"], in: preview.repository, fixture: fixture)
        #expect(targetMessages.split(separator: "\n").map(String.init) == plan.source.revisions.map(\.message))
        let targetAuthors = try await gitOutput(["log", "--reverse", "--format=%an <%ae>"], in: preview.repository, fixture: fixture)
        #expect(targetAuthors.split(separator: "\n").map(String.init) == preview.mappings.map { "\($0.author.name) <\($0.author.email)>" })
        let targetSeconds = try await gitOutput(["log", "--reverse", "--format=%at"], in: preview.repository, fixture: fixture)
            .split(separator: "\n").compactMap { Int64(String($0)) }
        #expect(targetSeconds.count == plan.source.revisions.count)
        for (actual, source) in zip(targetSeconds, plan.source.revisions) {
            #expect(abs(actual - Int64(source.date.timeIntervalSince1970)) <= 1)
        }

        let publication = try await service.publish(preview, progress: { _ in })
        #expect(publication.state == .published)
        #expect(try await remoteBranch(target, branch: "main", fixture: fixture) == preview.tip)
        #expect(try await svnStatus(fixture).isEmpty)
    }

    @Test("快照迁移只生成一个提交，预览被本地忽略文件改动后拒绝发布")
    func snapshotMigrationDoesNotReplayHistoryAndRejectsModifiedPreview() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedMigrationModule(in: fixture)

        let target = fixture.root.appendingPathComponent("remotes/snapshot-target.git", isDirectory: true)
        try await git(["init", "--bare", target.path], fixture: fixture)
        let service = migrationService(for: fixture)
        let plan = try await service.plan(
            sourceProviderID: .svn,
            location: RemoteRepositoryLocation(url: fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString),
            mode: .snapshot, targetProviderID: .git, remoteURL: target.absoluteURL.absoluteString, branch: "main",
            destination: fixture.root.appendingPathComponent("snapshot-preview", isDirectory: true), progress: { _ in }
        )
        #expect(plan.source.revisions.count == 1)

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.mappings.count == 1)
        #expect(try await gitOutput(["rev-list", "--count", "HEAD"], in: preview.repository, fixture: fixture)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)

        // .gitignore 会让 Git status 看不到该文件；服务仍必须扫描并拒绝发布旧预览。
        try Data("此文件不应发布\n".utf8).write(to: preview.repository.appendingPathComponent("本地篡改.local"))
        let porcelain = try await gitOutput(["status", "--porcelain=v1"], in: preview.repository, fixture: fixture)
        #expect(porcelain.isEmpty)
        await #expect(throws: VersionControlError.self) {
            try await service.publish(preview, progress: { _ in })
        }
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)
        #expect(try await svnStatus(fixture).isEmpty)
    }

    @Test("首次真实 Git 提交后核对失败，恢复时不会重复追加或发布未核对历史")
    func refusesResumeWhenFirstCommitWasNotVerified() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedMigrationModule(in: fixture)

        let target = fixture.root.appendingPathComponent("remotes/checkpoint-target.git", isDirectory: true)
        try await git(["init", "--bare", target.path], fixture: fixture)
        let guardedTarget = FailAfterFirstCommitTarget(base: GitMigrationTargetProvider(runner: fixture.runner))
        let service = RepositoryMigrationService(sources: [SVNProvider(runner: fixture.runner)], targets: [guardedTarget])
        let plan = try await service.plan(
            sourceProviderID: .svn,
            location: RemoteRepositoryLocation(url: fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString),
            mode: .history, targetProviderID: .git, remoteURL: target.absoluteURL.absoluteString, branch: "main",
            destination: fixture.root.appendingPathComponent("checkpoint-preview", isDirectory: true), progress: { _ in }
        )

        await #expect(throws: VersionControlError.self) {
            try await service.prepare(plan, progress: { _ in })
        }
        let partial = try #require(await service.partialDirectory(for: plan.id))
        let stagedRepository = partial.appendingPathComponent("repository", isDirectory: true)
        #expect(try await gitOutput(["rev-list", "--count", "HEAD"], in: stagedRepository, fixture: fixture)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)

        // 首次 append 已发生，但还没有映射检查点；恢复必须拒绝，而不是从零再 append 一遍。
        await #expect(throws: VersionControlError.self) {
            try await service.prepare(plan, progress: { _ in })
        }
        #expect(try await gitOutput(["rev-list", "--count", "HEAD"], in: stagedRepository, fixture: fixture)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)
        #expect(try await svnStatus(fixture).isEmpty)
    }

    private func migrationService(for fixture: LocalRepositoryFixture) -> RepositoryMigrationService {
        RepositoryMigrationService(
            sources: [SVNProvider(runner: fixture.runner)],
            targets: [GitMigrationTargetProvider(runner: fixture.runner)]
        )
    }

    private func seedMigrationModule(in fixture: LocalRepositoryFixture) async throws {
        let module = fixture.svnWriter.appendingPathComponent("迁移模块", isDirectory: true)
        let documents = module.appendingPathComponent("文档", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: module.appendingPathComponent("空目录", isDirectory: true), withIntermediateDirectories: true)
        try "第一版：中文文件。\n".write(to: documents.appendingPathComponent("说明.md"), atomically: true, encoding: .utf8)
        try "随后会删除。\n".write(to: module.appendingPathComponent("已删除.txt"), atomically: true, encoding: .utf8)
        try "已受 SVN 管理，但匹配忽略规则。\n".write(to: module.appendingPathComponent("保留但忽略.local"), atomically: true, encoding: .utf8)
        try "*.local\n".write(to: module.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 0, 0xFF, 0x7F]).write(to: module.appendingPathComponent("二进制数据.bin"))
        try await svn(["add", "迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["propset", "svn:ignore", "*.local", "迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("创建迁移模块", author: "迁移作者甲", fixture: fixture)

        try "第二版：中文文件仍可读取。\n".write(to: documents.appendingPathComponent("说明.md"), atomically: true, encoding: .utf8)
        try await svn(["delete", "已删除.txt"], in: module, fixture: fixture)
        try await svnCommit("删除旧文件并更新中文说明", author: "迁移作者乙", fixture: fixture)

        try Data([0, 9, 8, 0, 0xFE, 0x7E]).write(to: module.appendingPathComponent("二进制数据.bin"))
        try await svnCommit("更新二进制内容", author: "迁移作者甲", fixture: fixture)
    }

    private func requireTools() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil, ToolLocator.find("git") != nil else {
            throw FixtureError.toolUnavailable
        }
    }

    private func svnCommit(_ message: String, author: String, fixture: LocalRepositoryFixture) async throws {
        try await svn(["commit", "--username", author, "-m", message], in: fixture.svnWriter, fixture: fixture)
    }

    private func svn(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: arguments, directory: directory), tool: "svn")
    }

    private func git(_ arguments: [String], fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: arguments), tool: "git")
    }

    private func gitOutput(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: directory), tool: "git").output
    }

    private func remoteRefs(_ remote: URL, fixture: LocalRepositoryFixture) async throws -> [String] {
        let output = try await gitOutput(["ls-remote", "--refs", "--", remote.absoluteURL.absoluteString], in: fixture.root, fixture: fixture)
        return output.split(separator: "\n").map(String.init)
    }

    private func remoteBranch(_ remote: URL, branch: String, fixture: LocalRepositoryFixture) async throws -> String? {
        let refs = try await remoteRefs(remote, fixture: fixture)
        return refs.first { $0.hasSuffix("refs/heads/\(branch)") }?.split(separator: "\t").first.map(String.init)
    }

    private func svnStatus(_ fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "svn", arguments: ["status"], directory: fixture.svnWriter), tool: "svn")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum FixtureError: Error { case toolUnavailable }
}

/// 模拟 Git 已写入提交、但导出核对树时崩溃。该故障窗口曾导致恢复操作错误地再次追加首个提交。
private actor FailAfterFirstCommitTarget: RepositoryMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    private let base: GitMigrationTargetProvider
    private var shouldFailExport = true

    init(base: GitMigrationTargetProvider) { self.base = base }

    func checkMigrationTarget(remoteURL: String, branch: String) async throws {
        try await base.checkMigrationTarget(remoteURL: remoteURL, branch: branch)
    }

    func initializeMigration(at directory: URL, branch: String) async throws {
        try await base.initializeMigration(at: directory, branch: branch)
    }

    func appendMigrationSnapshot(
        from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> String {
        try await base.appendMigrationSnapshot(from: snapshot, revision: revision, author: author, to: directory, progress: progress)
    }

    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {
        try await base.verifyMigration(at: directory, expectedTip: expectedTip, branch: branch)
    }

    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {
        try await base.verifyMigrationCheckpoint(at: directory, expectedTip: expectedTip, branch: branch)
    }

    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        if shouldFailExport {
            shouldFailExport = false
            throw VersionControlError.executionFailed("模拟：首个真实 Git 提交后，导出核对树失败。")
        }
        try await base.exportMigrationTree(at: directory, revision: revision, to: destination)
    }

    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch {
        try await base.migrationPatch(at: directory, revision: revision)
    }

    func publishMigration(
        at directory: URL, remoteURL: String, branch: String, expectedTip: String,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationPublicationResult {
        try await base.publishMigration(at: directory, remoteURL: remoteURL, branch: branch, expectedTip: expectedTip, progress: progress)
    }
}
