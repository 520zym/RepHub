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

    @Test("复制改名祖先下的增量快照逐修订生成与标准 SVN 导出一致的 Git 树")
    func incrementalSnapshotsPreserveCopiedHistoryAndComplexTrees() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedCopiedMigrationModule(in: fixture)

        // 这是一份模拟用户工作副本。迁移只能读取远端，不能碰 wc.db 或任何已检出文件。
        let sourceBefore = try treeSignature(at: fixture.svnWriter, excludingMetadata: true)
        let databaseBefore = try Data(contentsOf: fixture.svnWriter.appendingPathComponent(".svn/wc.db"))

        let target = fixture.root.appendingPathComponent("remotes/copied-history-target.git", isDirectory: true)
        try await git(["init", "--bare", target.path], fixture: fixture)
        let service = migrationService(for: fixture)
        let sourceURL = fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString
        let destination = fixture.root.appendingPathComponent("copied-history-preview", isDirectory: true)
        let plan = try await service.plan(
            sourceProviderID: .svn, location: RemoteRepositoryLocation(url: sourceURL), mode: .history,
            targetProviderID: .git, remoteURL: target.absoluteURL.absoluteString, branch: "main",
            destination: destination, progress: { _ in }
        )

        // `迁移模块` 是从 `旧迁移模块` 复制而来；固定在当前 peg 上时，历史中的旧路径
        // 仍必须可解析。若会话把 rN 当作路径的 peg，会在复制点之前导出错误的目录。
        #expect(plan.source.revisions.map(\.message) == [
            "旧路径创建复杂文件", "旧路径更新二进制与文本", "复制旧路径为迁移模块",
            "新路径改名删除并更新", "新路径再次更新"
        ])
        #expect(plan.source.revisions.count == 5)

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.mappings.count == plan.source.revisions.count)
        #expect(try await remoteRefs(target, fixture: fixture).isEmpty)

        // 旧的逐修订 `svn export` 只作为测试 oracle。生产路径由 service 创建一个
        // snapshot session 后顺序导出；这里逐条对比最终 Git 对象树，覆盖二进制、链接、
        // 可执行位、svn:keywords/eol、删除以及复制后的目录改名。
        let source = SVNProvider(runner: fixture.runner)
        let gitTarget = GitMigrationTargetProvider(runner: fixture.runner)
        for (index, mapping) in preview.mappings.enumerated() {
            let oracle = fixture.root.appendingPathComponent("oracle-\(index)", isDirectory: true)
            let restored = fixture.root.appendingPathComponent("restored-\(index)", isDirectory: true)
            try await source.exportMigrationSnapshot(plan: plan.source, revision: mapping.source, to: oracle, progress: { _ in })
            try await gitTarget.exportMigrationTree(at: preview.repository, revision: mapping.targetCommit, to: restored)
            let expected = try treeSignature(at: oracle)
            let actual = try treeSignature(at: restored)
            try #require(!expected.isEmpty)
            #expect(actual == expected)
        }

        let finalExport = fixture.root.appendingPathComponent("final-git-export", isDirectory: true)
        try await gitTarget.exportMigrationTree(at: preview.repository, revision: preview.tip, to: finalExport)
        let finalTree = try treeSignature(at: finalExport)
        #expect(!finalTree.isEmpty)
        #expect(finalTree["d:目录"] != nil)
        #expect(finalTree["f:目录/新名.txt"] != nil)
        #expect(finalTree["f:目录/旧名.txt"] == nil)
        #expect(finalTree["f:待删除/旧文件.txt"] == nil)
        #expect(finalTree["l:脚本链接"] == "脚本.sh")
        #expect(finalTree["x:脚本.sh"] == "1")

        #expect(try treeSignature(at: fixture.svnWriter, excludingMetadata: true) == sourceBefore)
        #expect(try Data(contentsOf: fixture.svnWriter.appendingPathComponent(".svn/wc.db")) == databaseBefore)
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

    private func seedCopiedMigrationModule(in fixture: LocalRepositoryFixture) async throws {
        let oldModule = fixture.svnWriter.appendingPathComponent("旧迁移模块", isDirectory: true)
        let folder = oldModule.appendingPathComponent("目录", isDirectory: true)
        let deleted = oldModule.appendingPathComponent("待删除", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        try "第一版\r\n含有 $Id$ 关键字。\r\n".write(to: oldModule.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        try "旧名称\n".write(to: folder.appendingPathComponent("旧名.txt"), atomically: true, encoding: .utf8)
        try "随后删除\n".write(to: deleted.appendingPathComponent("旧文件.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho first\n".write(to: oldModule.appendingPathComponent("脚本.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldModule.appendingPathComponent("脚本.sh").path)
        try FileManager.default.createSymbolicLink(atPath: oldModule.appendingPathComponent("脚本链接").path, withDestinationPath: "脚本.sh")
        try Data([0, 1, 0, 0xFF, 0x7F]).write(to: oldModule.appendingPathComponent("资料.bin"))
        try await svn(["add", "旧迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["propset", "svn:eol-style", "LF", "旧迁移模块/说明.txt"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["propset", "svn:keywords", "Id", "旧迁移模块/说明.txt"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("旧路径创建复杂文件", author: "author-a", fixture: fixture)

        try "第二版\r\n含有 $Id$ 关键字。\r\n".write(to: oldModule.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        try Data([9, 8, 0, 0xFE, 0x7E]).write(to: oldModule.appendingPathComponent("资料.bin"))
        try await svnCommit("旧路径更新二进制与文本", author: "author-b", fixture: fixture)

        // SVN commit 后父目录仍可能保持旧 BASE。若此时 copy，copyfrom 会指向 r3，
        // 形成混合版本，历史计划理应只包含 r3、而不是本用例要覆盖的 r3-r4。
        // 先统一更新，使复制明确从包含第二次修改的 r4 创建。
        try await svn(["update"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["copy", "旧迁移模块", "迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("复制旧路径为迁移模块", author: "author-c", fixture: fixture)

        let newModule = fixture.svnWriter.appendingPathComponent("迁移模块", isDirectory: true)
        try await svn(["move", "目录/旧名.txt", "目录/新名.txt"], in: newModule, fixture: fixture)
        try await svn(["delete", "待删除"], in: newModule, fixture: fixture)
        try "第三版\n含有 $Id$ 关键字。\n".write(to: newModule.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        try await svnCommit("新路径改名删除并更新", author: "author-d", fixture: fixture)

        try "#!/bin/sh\necho final\n".write(to: newModule.appendingPathComponent("脚本.sh"), atomically: true, encoding: .utf8)
        try Data([42, 0, 42, 0xFF]).write(to: newModule.appendingPathComponent("资料.bin"))
        try await svnCommit("新路径再次更新", author: "author-e", fixture: fixture)
    }

    private func treeSignature(at root: URL, excludingMetadata: Bool = false) throws -> [String: String] {
        let manager = FileManager.default
        var result: [String: String] = [:]
        // 按文件名构造相对路径，避免 /var 与 /private/var 别名的字符串替换问题。
        // 不解析单个链接的目标；签名独立比较完整字节、可执行位和链接文字。
        func visit(_ directory: URL, prefix: String) throws {
            for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = item.lastPathComponent
                if excludingMetadata, prefix.isEmpty, name == ".svn" { continue }
                let relative = prefix + name
                let attributes = try manager.attributesOfItem(atPath: item.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink:
                    result["l:\(relative)"] = try manager.destinationOfSymbolicLink(atPath: item.path)
                case .typeDirectory:
                    result["d:\(relative)"] = ""
                    try visit(item, prefix: relative + "/")
                case .typeRegular:
                    result["f:\(relative)"] = try Data(contentsOf: item).base64EncodedString()
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    result["x:\(relative)"] = permissions & 0o111 == 0 ? "0" : "1"
                default:
                    throw VersionControlError.invalidData("测试树含未支持的文件：\(relative)")
                }
            }
        }
        try visit(root, prefix: "")
        return result
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
