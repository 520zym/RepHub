import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("SVN 工作副本迁移编排")
struct WorkingCopyMigrationServiceTests {
    @Test("首次迁移固定工作副本基线并生成明确作者占位")
    func plansInitialMigration() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = WorkingCopySourceFixture(root: root)
        let service = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let plan = try await service.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                          mode: .history, action: .initial, progress: { _ in })
        #expect(plan.workingCopy.baseRevision == "r9")
        #expect(plan.source.anchor == "r9")
        #expect(plan.authors["svn-user"]?.email.hasSuffix("@authors.invalid") == true)
    }

    @Test("只读预检会报告可辨识的阶段进度")
    func reportsPlanningStages() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = WorkingCopySourceFixture(root: root)
        let service = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let collector = ProgressCollector()

        _ = try await service.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                   mode: .history, action: .initial) { update in
            await collector.append(update)
        }

        let messages = await collector.messages
        #expect(messages.contains("正在读取当前工作副本迁移记录…"))
        #expect(messages.contains("正在核对 SVN 工作副本状态…"))
        #expect(messages.contains("正在确认目标 Git 仓库状态…"))
        #expect(messages.contains(where: { $0.hasPrefix("只读预检完成，已读取 1 条 SVN 修订") }))
    }

    @Test("首次预览把已核对工作副本作为只读会话基线，并保留来源子阶段")
    func initialPreviewSeedsSessionAndKeepsSourcePhase() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = WorkingCopySessionStats()
        let source = WorkingCopySourceFixture(root: root, sessionStats: stats)
        let service = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let plan = try await service.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                          mode: .history, action: .initial, progress: { _ in })
        let collector = ProgressCollector()

        _ = try await service.prepare(plan) { update in await collector.append(update) }

        #expect(await stats.seedPath == root.standardizedFileURL.path)
        let messages = await collector.messages
        #expect(messages.contains("首次检出 SVN 快照… · r9"))
        #expect(messages.contains("本地整理 SVN 快照… · r9"))
    }

    @Test("新版工作副本迁移检查点可在新服务实例中恢复同一固定计划")
    func resumesDurableInitialCheckpoint() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = WorkingCopySourceFixture(root: root)
        let first = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let plan = try await first.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                         mode: .history, action: .initial, progress: { _ in })
        _ = try await first.prepare(plan, progress: { _ in })
        let folder = try #require(await first.partialDirectory(for: plan.id))
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = folder.appendingPathComponent("checkpoint.json")
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))

        let restoredService = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        // macOS 的 temporaryDirectory 通常报告 /var，而底层对象实际位于 /private/var。
        // 两个等价绝对路径都应通过容器校验，不能因解析真实路径而误判为移动过检查点。
        let checkpointAlias = checkpoint.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + checkpoint.path)
            : checkpoint
        let restored = try await restoredService.resume(from: checkpointAlias)
        #expect(restored.id == plan.id)
        #expect(restored.source.revisions == plan.source.revisions)
        let preview = try await restoredService.prepare(restored, progress: { _ in })
        #expect(preview.mappings.map(\.source.id) == ["r9"])
    }

    @Test("目录历史早于固定 BASE 时仍可预览并从检查点恢复")
    func allowsHistoryEndingBeforeFixedAnchorAndResumesCheckpoint() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // SVN 修订号属于整个仓库。这个目录在 r8 后未再修改，但工作副本 BASE 已固定在 r9。
        let revisions = [MigrationRevision(id: "r8", author: "svn-user", date: .distantPast, message: "last directory change")]
        let source = WorkingCopySourceFixture(root: root, revisions: revisions)
        let first = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let plan = try await first.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                         mode: .history, action: .initial, progress: { _ in })

        #expect(plan.workingCopy.baseRevision == "r9")
        #expect(plan.source.anchor == "r9")
        #expect(plan.source.revisions.map(\.id) == ["r8"])

        let preview = try await first.prepare(plan, progress: { _ in })
        #expect(preview.mappings.map(\.source.id) == ["r8"])
        let folder = try #require(await first.partialDirectory(for: plan.id))
        defer { try? FileManager.default.removeItem(at: folder) }

        let restoredService = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let restored = try await restoredService.resume(from: folder.appendingPathComponent("checkpoint.json"))
        let restoredPreview = try await restoredService.prepare(restored, progress: { _ in })
        #expect(restoredPreview.mappings.map(\.source.id) == ["r8"])
    }

    @Test("目录历史不能超过固定 BASE")
    func rejectsHistoryAfterFixedAnchor() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let revisions = [MigrationRevision(id: "r10", author: "svn-user", date: .distantPast, message: "after base")]
        let source = WorkingCopySourceFixture(root: root, revisions: revisions)
        let service = WorkingCopyMigrationService(source: source, target: WorkingCopyTargetFixture())
        let plan = try await service.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                          mode: .history, action: .initial, progress: { _ in })

        await #expect(throws: VersionControlError.self) {
            try await service.prepare(plan, progress: { _ in })
        }
    }

    @Test("初迁失败后只从检查点后的修订继续，不重复已核对提交")
    func retriesInitialMigrationFromVerifiedCheckpoint() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let revisions = [
            MigrationRevision(id: "r8", author: "svn-user", date: .distantPast, message: "first"),
            MigrationRevision(id: "r9", author: "svn-user", date: .now, message: "second")
        ]
        let source = WorkingCopySourceFixture(root: root, revisions: revisions)
        let target = WorkingCopyTargetFixture(failingRevision: "r9")
        let service = WorkingCopyMigrationService(source: source, target: target)
        let plan = try await service.plan(at: root, remoteURL: "https://example.test/project.git", branch: "main",
                                         mode: .history, action: .initial, progress: { _ in })
        await #expect(throws: Error.self) { try await service.prepare(plan, progress: { _ in }) }
        let folder = try #require(await service.partialDirectory(for: plan.id))
        defer { try? FileManager.default.removeItem(at: folder) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(WorkingCopyCheckpointProbe.self,
                                            from: Data(contentsOf: folder.appendingPathComponent("checkpoint.json")))
        #expect(checkpoint.mappings.map(\.source.id) == ["r8"])

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.mappings.map(\.source.id) == ["r8", "r9"])
        #expect(await target.appendedRevisions == ["r8", "r9", "r9"])
    }

    @Test("迁移记录中的地址凭据和重复映射被拒绝")
    func rejectsUnsafeRecord() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r1", author: "a", date: .distantPast, message: "m")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        let record = WorkingCopyMigrationRecord(sourceURL: "https://user:password@example.test/svn", repositoryUUID: "u", startRevision: "r1", lastRevision: "r1", remoteURL: "https://example.test/git", branch: "main", mappings: [mapping])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))
        let service = WorkingCopyMigrationService(source: WorkingCopySourceFixture(root: root), target: WorkingCopyTargetFixture())
        await #expect(throws: VersionControlError.self) { try await service.readRecord(at: root) }
    }

    @Test("ISO-8601 日期编码的迁移记录可被读回")
    func readsISO8601Record() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r9", author: "a", date: .now, message: "m")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        let record = WorkingCopyMigrationRecord(sourceURL: "https://example.test/svn", repositoryUUID: "u", startRevision: "r9", lastRevision: "r10", remoteURL: "https://example.test/git", branch: "main", mappings: [mapping], cutoverRevision: "r9")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))
        let service = WorkingCopyMigrationService(source: WorkingCopySourceFixture(root: root), target: WorkingCopyTargetFixture())
        let restored = try #require(await service.readRecord(at: root))
        #expect(restored.mappings[0].source.id == "r9")
        #expect(restored.cutoverRevision == "r9")
    }

    @Test("记录首条映射必须与历史起点一致")
    func rejectsRecordWithMismatchedStartMapping() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r2", author: "a", date: .now, message: "m")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        let record = WorkingCopyMigrationRecord(sourceURL: "https://example.test/svn", repositoryUUID: "u", startRevision: "r1", lastRevision: "r2", remoteURL: "https://example.test/git", branch: "main", mappings: [mapping], cutoverRevision: "r1")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))
        let service = WorkingCopyMigrationService(source: WorkingCopySourceFixture(root: root), target: WorkingCopyTargetFixture())
        await #expect(throws: VersionControlError.self) { try await service.readRecord(at: root) }
    }

    @Test("只读检查只报告源 SVN 的最新修订，不计算或虚构提交数量")
    func reportsSourceUpdateFromMigrationRecord() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r9", author: "a", date: .now, message: "m")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        let record = WorkingCopyMigrationRecord(sourceURL: "https://example.test/svn/project", repositoryUUID: "uuid",
                                                startRevision: "r9", lastRevision: "r9", remoteURL: "https://example.test/git",
                                                branch: "main", mappings: [mapping], cutoverRevision: "r9")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))

        let service = WorkingCopyMigrationService(
            source: WorkingCopySourceFixture(root: root, latestRevision: "r12"),
            target: WorkingCopyTargetFixture()
        )
        let result = try await service.checkForSourceUpdates(at: root)
        guard case let .update(update) = result else { Issue.record("expected source update"); return }
        #expect(update.migratedRevision == "r9")
        #expect(update.latestRevision == "r12")
    }

    @Test("全仓库截止版本晚于目录末端时，目录历史停在末端仍为最新")
    func reportsCurrentWhenLatestMatchesLastImportedDirectoryRevision() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r9", author: "a", date: .now, message: "last directory change")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        // r10 是迁移时固定的全仓库 BASE；所选目录的最后一次变更仍是 r9。
        let record = WorkingCopyMigrationRecord(sourceURL: "https://example.test/svn/project", repositoryUUID: "uuid",
                                                startRevision: "r9", lastRevision: "r10", remoteURL: "https://example.test/git",
                                                branch: "main", mappings: [mapping], cutoverRevision: "r10")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))

        let service = WorkingCopyMigrationService(
            source: WorkingCopySourceFixture(root: root, latestRevision: "r9"),
            target: WorkingCopyTargetFixture()
        )
        let result = try await service.checkForSourceUpdates(at: root)
        guard case let .current(migratedRevision, _) = result else { Issue.record("expected current source history"); return }
        #expect(migratedRevision == "r10")
    }

    @Test("源端修订倒退不会被误报为已同步")
    func rejectsSourceHistoryBehindMigratedRevision() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let revision = MigrationRevision(id: "r9", author: "a", date: .now, message: "m")
        let mapping = MigrationMapping(source: revision, author: MigrationAuthor(name: "a", email: "a@example.test"), targetCommit: String(repeating: "a", count: 40))
        let record = WorkingCopyMigrationRecord(sourceURL: "https://example.test/svn/project", repositoryUUID: "uuid",
                                                startRevision: "r9", lastRevision: "r9", remoteURL: "https://example.test/git",
                                                branch: "main", mappings: [mapping], cutoverRevision: "r9")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: git.appendingPathComponent("rephub-svn-migration.json"))
        let service = WorkingCopyMigrationService(
            source: WorkingCopySourceFixture(root: root, latestRevision: "r8"),
            target: WorkingCopyTargetFixture()
        )
        await #expect(throws: VersionControlError.self) { try await service.checkForSourceUpdates(at: root) }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-wc-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
}

private actor ProgressCollector {
    private(set) var messages: [String] = []
    func append(_ update: RepositoryOperationProgress) { messages.append(update.message) }
}

private struct WorkingCopyCheckpointProbe: Decodable {
    let mappings: [MigrationMapping]
}

private struct WorkingCopySourceFixture: RepositoryWorkingCopyMigrationSourceProvider, VersionControlProvider {
    let id = ProviderID(rawValue: "working-copy-source-fixture")
    let root: URL
    var latestRevision: String? = nil
    var sessionStats: WorkingCopySessionStats? = nil
    var revisions: [MigrationRevision] = [MigrationRevision(id: "r9", author: "svn-user", date: .distantPast, message: "change")]
    var displayName: String { "SVN fixture" }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan { try await planWorkingCopyHistory(from: location, mode: mode, through: "r9", after: nil, progress: progress) }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo { MigrationWorkingCopyInfo(directory: root, sourceURL: "https://example.test/svn/project", repositoryUUID: "uuid", baseRevision: "r9") }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r9", mode: mode, revisions: revisions)
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws {}
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {}
    func makeMigrationSnapshotSession(plan: MigrationSourcePlan, in workspace: URL,
                                      seedWorkingCopy: URL?) async throws -> any RepositoryMigrationSnapshotSession {
        await sessionStats?.recordSeed(seedWorkingCopy)
        return WorkingCopySnapshotSession(stats: sessionStats)
    }
    func detect(at directory: URL) async throws -> RepositoryBinding? { nil }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        latestRevision.map { [Revision(id: $0, author: "a", date: .now, message: "latest")] } ?? []
    }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
}

private struct WorkingCopySnapshotSession: RepositoryMigrationSnapshotSession {
    let stats: WorkingCopySessionStats?
    func exportSnapshot(revision: MigrationRevision, to directory: URL,
                        progress: @escaping RepositoryOperationProgressHandler) async throws {
        await progress(RepositoryOperationProgress("首次检出 SVN 快照…"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await progress(RepositoryOperationProgress("本地整理 SVN 快照…"))
    }
}

private actor WorkingCopySessionStats {
    private(set) var seedPath: String?
    func recordSeed(_ seed: URL?) { seedPath = seed?.standardizedFileURL.path }
}

private actor WorkingCopyTargetFixture: RepositoryWorkingCopyMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    private let failingRevision: String?
    private var failed = false
    private(set) var appendedRevisions: [String] = []
    init(failingRevision: String? = nil) { self.failingRevision = failingRevision }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws {}
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        appendedRevisions.append(revision.id)
        if revision.id == failingRevision, !failed { failed = true; throw VersionControlError.executionFailed("fixture failure") }
        return String(repeating: revision.id == "r8" ? "a" : "b", count: 40)
    }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { MigrationPublicationResult(state: .notPublished, message: "") }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws {}
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws {}
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    }
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { String(repeating: "a", count: 40) }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {}
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { MigrationPublicationResult(state: .notPublished, message: "") }
}
