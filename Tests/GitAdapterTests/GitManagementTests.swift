import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 管理与比较")
struct GitManagementTests {
    @Test("初始化不覆盖已有 Git，暂存取消暂存精确保留未选索引")
    func initializesSafelyAndStagesExactPaths() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        let provider = GitProvider(runner: fixture.runner)
        await #expect(throws: VersionControlError.self) {
            try await provider.initialize(RepositorySetupRequest(providerID: .git, directory: fixture.gitReader), progress: { _ in })
        }
        try await configure(fixture)
        try "a\n".write(to: fixture.gitReader.appendingPathComponent("star*.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: fixture.gitReader.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let initial = try await provider.managementContext(in: binding)
        _ = try await provider.performManagement(.init(action: .stage(paths: ["star*.txt"]), stateToken: initial.stateToken), in: binding, progress: { _ in })
        let afterStage = try await provider.managementContext(in: binding)
        #expect(afterStage.changes.first(where: { $0.path == "star*.txt" })?.isStaged == true)
        _ = try await provider.performManagement(.init(action: .unstage(paths: ["star*.txt"]), stateToken: afterStage.stateToken), in: binding, progress: { _ in })
        let staged = try await fixture.run(executable: "git", arguments: ["diff", "--cached", "--name-only"], directory: fixture.gitReader)
        #expect(try requireSuccess(staged, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("过期令牌与脏工作区会拒绝管理操作")
    func rejectsStaleTokenAndDirtyBranchSwitch() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let context = try await provider.managementContext(in: binding)
        try "changed\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let stale = try await provider.performManagement(.init(action: .stage(paths: ["README.md"]), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(stale.outcome == .failed)
        let refreshed = try await provider.managementContext(in: binding)
        let switched = try await provider.performManagement(.init(action: .switchBranch(name: "main"), stateToken: refreshed.stateToken), in: binding, progress: { _ in })
        #expect(switched.outcome == .failed)
    }

    @Test("冲突合并由用户编辑解决后形成双父提交")
    func resolvesMergeAndPreservesParents() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try await success("git", ["checkout", "-b", "side"], in: fixture.gitReader, fixture: fixture)
        try "side\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success("git", ["commit", "-am", "side"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["checkout", "main"], in: fixture.gitReader, fixture: fixture)
        try "main\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success("git", ["commit", "-am", "main"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let before = try await provider.managementContext(in: binding)
        let merge = try await provider.performManagement(.init(action: .merge(reference: "side"), stateToken: before.stateToken), in: binding, progress: { _ in })
        #expect(merge.outcome == .conflicts)
        try "resolved\n".write(to: fixture.gitReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let resolving = try await provider.managementContext(in: binding)
        _ = try await provider.performManagement(.init(action: .markResolved(paths: ["README.md"]), stateToken: resolving.stateToken), in: binding, progress: { _ in })
        let ready = try await provider.managementContext(in: binding)
        #expect(ready.canFinishMerge)
        _ = try await provider.performManagement(.init(action: .finishMerge(message: "merge side"), stateToken: ready.stateToken), in: binding, progress: { _ in })
        let parents = try await fixture.run(executable: "git", arguments: ["show", "-s", "--format=%P", "HEAD"], directory: fixture.gitReader)
        #expect(try requireSuccess(parents, tool: "git").output.split(whereSeparator: \.isWhitespace).count == 2)
    }

    @Test("比较固定修订，包含重命名与删除")
    func comparesRenameAndDeletion() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try "a\n".write(to: fixture.gitReader.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "old.txt"], in: fixture.gitReader, fixture: fixture); try await success("git", ["commit", "-m", "old"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let from = try await oid("HEAD", fixture)
        try await success("git", ["mv", "old.txt", "new.txt"], in: fixture.gitReader, fixture: fixture); try await success("git", ["commit", "-m", "rename"], in: fixture.gitReader, fixture: fixture)
        let to = try await oid("HEAD", fixture)
        let comparison = try await provider.compare(in: binding, from: from, to: to)
        #expect(comparison.files.contains { $0.path == "new.txt" && $0.originalPath == "old.txt" })
        let patch = try await provider.comparisonDiff(in: binding, comparison: comparison, path: "new.txt")
        #expect(patch.text.contains("new.txt"))
        #expect(patch.text.contains("old.txt"))
        #expect(patch.text.contains("rename from") || patch.text.contains("similarity index"))
    }

    @Test("新分支可推送到已配置远端的不同目标名并设置上游")
    func pushesNewBranchWithExplicitUpstream() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try await success("git", ["checkout", "-b", "feature/local"], in: fixture.gitReader, fixture: fixture)
        try "feature\n".write(to: fixture.gitReader.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "feature.txt"], in: fixture.gitReader, fixture: fixture); try await success("git", ["commit", "-m", "feature"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let context = try await provider.managementContext(in: binding)
        let result = try await provider.performManagement(.init(action: .push(remote: "origin", branch: "review-target", setUpstream: true), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded)
        let upstream = try await fixture.run(executable: "git", arguments: ["rev-parse", "--abbrev-ref", "@{upstream}"], directory: fixture.gitReader)
        #expect(try requireSuccess(upstream, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/review-target")
    }

    @Test("远端 pushurl 是推送与复核的实际目标")
    func pushesToConfiguredPushURL() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        let pushRemote = fixture.root.appendingPathComponent("remotes/push-target.git", isDirectory: true)
        try await success("git", ["init", "--bare", pushRemote.path], in: fixture.root, fixture: fixture)
        try "pushurl\n".write(to: fixture.gitReader.appendingPathComponent("pushurl.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "pushurl.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "pushurl"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["remote", "set-url", "--push", "origin", pushRemote.path], in: fixture.gitReader, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let context = try await provider.managementContext(in: binding)
        let result = try await provider.performManagement(.init(action: .push(remote: "origin", branch: "pushurl-target", setUpstream: false), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded)

        let pushed = try await fixture.run(executable: "git", arguments: ["--git-dir", pushRemote.path, "rev-parse", "refs/heads/pushurl-target"], directory: fixture.root)
        let localHead = try await oid("HEAD", fixture)
        #expect(try requireSuccess(pushed, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines) == localHead)
        let original = try await fixture.run(executable: "git", arguments: ["--git-dir", fixture.gitRemote.path, "show-ref", "--verify", "--quiet", "refs/heads/pushurl-target"], directory: fixture.root)
        #expect(original.exitCode != 0)
    }

    @Test("非快进推送被明确拒绝，远端执行异常标记未知")
    func distinguishesRejectedAndUnknownPush() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try "remote\n".write(to: fixture.gitWriter.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "remote.txt"], in: fixture.gitWriter, fixture: fixture); try await success("git", ["commit", "-m", "remote"], in: fixture.gitWriter, fixture: fixture); try await success("git", ["push", "origin", "HEAD:main"], in: fixture.gitWriter, fixture: fixture)
        try "local\n".write(to: fixture.gitReader.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "local.txt"], in: fixture.gitReader, fixture: fixture); try await success("git", ["commit", "-m", "local"], in: fixture.gitReader, fixture: fixture)
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let rejectedContext = try await provider.managementContext(in: binding)
        let rejected = try await provider.performManagement(.init(action: .push(remote: "origin", branch: "main", setUpstream: false), stateToken: rejectedContext.stateToken), in: binding, progress: { _ in })
        #expect(rejected.outcome == .failed)
        let missingRemote = fixture.root.appendingPathComponent("remotes/missing-remote.git").absoluteString
        try await success("git", ["remote", "add", "broken", missingRemote], in: fixture.gitReader, fixture: fixture)
        let unknownContext = try await provider.managementContext(in: binding)
        let unknown = try await provider.performManagement(.init(action: .push(remote: "broken", branch: "other-target", setUpstream: false), stateToken: unknownContext.stateToken), in: binding, progress: { _ in })
        #expect(unknown.outcome == .unknown)
    }

    @Test("远端与身份只写入当前仓库并进入管理状态")
    func configuresLocalRemoteAndIdentity() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let first = try await provider.managementContext(in: binding)
        let remote = try await provider.performManagement(.init(action: .setRemote(name: "review", url: fixture.gitRemote.absoluteString), stateToken: first.stateToken), in: binding, progress: { _ in })
        #expect(remote.outcome == .succeeded)
        let second = try await provider.managementContext(in: binding)
        let identity = try await provider.performManagement(.init(action: .setIdentity(name: "Local User", email: "local@example.invalid"), stateToken: second.stateToken), in: binding, progress: { _ in })
        #expect(identity.outcome == .succeeded)
        let updated = try await provider.managementContext(in: binding)
        #expect(updated.authorName == "Local User")
        #expect(updated.authorEmail == "local@example.invalid")
        #expect(updated.remotes.contains(where: { $0.name == "review" }))
    }

    @Test("Unicode 分支可创建并切换，目录不能作为暂存范围")
    func supportsUnicodeBranchAndRejectsDirectoryStaging() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try FileManager.default.createDirectory(at: fixture.gitReader.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try "child\n".write(to: fixture.gitReader.appendingPathComponent("folder/child.txt"), atomically: true, encoding: .utf8)
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let first = try await provider.managementContext(in: binding)
        let rejected = try await provider.performManagement(.init(action: .stage(paths: ["folder"]), stateToken: first.stateToken), in: binding, progress: { _ in })
        #expect(rejected.outcome == .failed)
        let staged = try await fixture.run(executable: "git", arguments: ["diff", "--cached", "--name-only"], directory: fixture.gitReader)
        #expect(try requireSuccess(staged, tool: "git").data.isEmpty)
        let current = try await provider.managementContext(in: binding)
        let created = try await provider.performManagement(.init(action: .createBranch(name: "feature/修复", startPoint: "HEAD"), stateToken: current.stateToken), in: binding, progress: { _ in })
        #expect(created.outcome == .succeeded)
        let switchedContext = try await provider.managementContext(in: binding)
        let switched = try await provider.performManagement(.init(action: .switchBranch(name: "feature/修复"), stateToken: switchedContext.stateToken), in: binding, progress: { _ in })
        #expect(switched.outcome == .succeeded)
    }

    @Test("取消暂存重命名的新路径会完整恢复索引而保留工作树重命名")
    func unstagesStagedRenameSelectedByNewPath() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        try "before rename\n".write(to: fixture.gitReader.appendingPathComponent("tracked-old.txt"), atomically: true, encoding: .utf8)
        try await success("git", ["add", "tracked-old.txt"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["commit", "-m", "tracked file"], in: fixture.gitReader, fixture: fixture)
        try await success("git", ["mv", "tracked-old.txt", "tracked-new.txt"], in: fixture.gitReader, fixture: fixture)

        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let context = try await provider.managementContext(in: binding)
        #expect(context.changes.contains { $0.path == "tracked-new.txt" && $0.originalPath == "tracked-old.txt" && $0.isStaged })
        let result = try await provider.performManagement(.init(action: .unstage(paths: ["tracked-new.txt"]), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(result.outcome == .succeeded)

        let cached = try await fixture.run(executable: "git", arguments: ["diff", "--cached", "--name-only"], directory: fixture.gitReader)
        #expect(try requireSuccess(cached, tool: "git").data.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.gitReader.appendingPathComponent("tracked-new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.gitReader.appendingPathComponent("tracked-old.txt").path))
    }

    @Test("危险远端协议在写入前被拒绝")
    func rejectsExtProtocolBeforeExecution() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        let provider = GitProvider(runner: fixture.runner); let binding = try #require(await provider.detect(at: fixture.gitReader))
        let context = try await provider.managementContext(in: binding)
        let result = try await provider.performManagement(.init(action: .setRemote(name: "unsafe", url: "ext::echo should-not-run"), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(result.outcome == .failed)
        let remote = try await fixture.run(executable: "git", arguments: ["remote"], directory: fixture.gitReader)
        let names = try requireSuccess(remote, tool: "git").output.split(whereSeparator: \.isNewline).map(String.init)
        #expect(!names.contains("unsafe"))
    }

    @Test("insteadOf 改写为 ext 协议时在命令启动前被拒绝")
    func rejectsInsteadOfRedirectedExtProtocolBeforeExecution() async throws {
        let fixture = try await LocalRepositoryFixture.create(); defer { try? fixture.remove() }
        try await configure(fixture)
        let provider = GitProvider(runner: fixture.runner)
        let binding = try #require(await provider.detect(at: fixture.gitReader))
        let initial = try await provider.managementContext(in: binding)
        let configured = try await provider.performManagement(.init(action: .setRemote(name: "redirected", url: fixture.gitRemote.path), stateToken: initial.stateToken), in: binding, progress: { _ in })
        #expect(configured.outcome == .succeeded)
        let context = try await provider.managementContext(in: binding)
        let marker = fixture.root.appendingPathComponent("ext-helper-ran")
        try await success("git", ["config", "--local", "url.\"ext::touch \(marker.path) \".insteadOf", fixture.gitRemote.path], in: fixture.gitReader, fixture: fixture)

        let result = try await provider.performManagement(.init(action: .push(remote: "redirected", branch: "blocked", setUpstream: false), stateToken: context.stateToken), in: binding, progress: { _ in })
        #expect(result.outcome == .failed)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func configure(_ fixture: LocalRepositoryFixture) async throws { try await success("git", ["config", "user.name", "Fixture"], in: fixture.gitReader, fixture: fixture); try await success("git", ["config", "user.email", "fixture@example.invalid"], in: fixture.gitReader, fixture: fixture) }
    private func oid(_ ref: String, _ fixture: LocalRepositoryFixture) async throws -> String { try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", ref], directory: fixture.gitReader), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func success(_ tool: String, _ args: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws { _ = try requireSuccess(try await fixture.run(executable: tool, arguments: args, directory: directory), tool: tool) }
}
