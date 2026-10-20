import Foundation
import Testing
@testable import RepositoryApplication
import VersionControlCore

@Suite("迁移快照预取")
struct MigrationPrefetcherTests {
    @Test("仓库初迁预取与已核对提交重叠，但提交顺序和检查点保持串行")
    func repositoryInitialMigrationOverlapsOnlySourcePreparation() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = PipelineStats()
        let source = PipelineSource(stats: stats)
        let target = PipelineTarget(stats: stats)
        let revisions = pipelineRevisions
        let plan = MigrationPlan(
            source: MigrationSourcePlan(providerID: source.id, location: .init(url: "file:///fixture"), anchor: "r3", mode: .history, revisions: revisions),
            targetProviderID: .git, remoteURL: "file:///empty.git", branch: "main",
            destination: root.appendingPathComponent("result"),
            authors: ["fixture": MigrationAuthor(name: "fixture", email: "fixture@example.test")]
        )
        let service = RepositoryMigrationService(sources: [source], targets: [target], prefetchEnabled: true)

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.mappings.map(\.source.id) == ["r1", "r2", "r3"])
        #expect(await stats.maximumExports == 1)
        #expect(await stats.appended == ["r1", "r2", "r3"])
        #expect(await stats.didOverlap(source: "r2", target: "r1"))
    }

    @Test("工作副本初迁失败时取消预取且不接受未核对预览")
    func workingCopyInitialMigrationCancelsPrefetchAfterVerificationFailure() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try "r3".write(to: root.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        let stats = PipelineStats()
        let source = PipelineWorkingCopySource(root: root, stats: stats)
        let target = PipelineWorkingCopyTarget(stats: stats, failRevision: "r1")
        let service = WorkingCopyMigrationService(source: source, target: target, prefetchEnabled: true)
        let plan = try await service.plan(at: root, remoteURL: "file:///empty.git", branch: "main", mode: .history, action: .initial, progress: { _ in })

        await #expect(throws: Error.self) { try await service.prepare(plan, progress: { _ in }) }
        let folder = try #require(await service.partialDirectory(for: plan.id))
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: Error.self) { try await service.prepare(plan, progress: { _ in }) }
        #expect(try String(contentsOf: root.appendingPathComponent("state.txt"), encoding: .utf8) == "r3")
        #expect(await stats.appended == [])
        #expect(await stats.finishedExport("r2"))
        #expect(await stats.cancelledExport("r2"))
        // 当前工作副本最多并行三份快照，取消验证不要求调度恰好达到峰值。
        let maximumExports = await stats.maximumExports
        #expect((1...3).contains(maximumExports))
    }

    @Test("只保留一个下一修订并拒绝越序消费")
    func enforcesOnePageAndRevisionOrder() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = PrefetchStats()
        let session = DelayedSnapshotSession(stats: stats, delayNanoseconds: 20_000_000)
        let output = ProgressOutput()
        let mux = MigrationPrefetchProgressMux { update in await output.append(update) }
        let prefetcher = OnePageMigrationSnapshotPrefetcher(session: session, workspace: root, progress: mux)
        let r1 = revision("r1"), r2 = revision("r2")

        try await prefetcher.schedule(r1)
        await #expect(throws: VersionControlError.self) { try await prefetcher.schedule(r2) }
        await #expect(throws: VersionControlError.self) { _ = try await prefetcher.consume(r2) }

        let first = try #require(try await prefetcher.consume(r1))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("r1.txt").path))
        try await prefetcher.schedule(r2)
        let second = try #require(try await prefetcher.consume(r2))
        await prefetcher.finish()

        #expect(await stats.started == ["r1", "r2"])
        #expect(await stats.finished == ["r1", "r2"])
        #expect(await stats.maximumConcurrent == 1)
        // 消费后的快照归调用方所有，结束预取不能删除当前 Git 正在读取的目录。
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set([first.lastPathComponent, second.lastPathComponent]))
    }

    @Test("取消会等待预取退出，返回后不会再写入快照")
    func cancellationDrainsChildBeforeReturning() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = PrefetchStats()
        let session = DelayedSnapshotSession(stats: stats, delayNanoseconds: 300_000_000)
        let mux = MigrationPrefetchProgressMux { _ in }
        let prefetcher = OnePageMigrationSnapshotPrefetcher(session: session, workspace: root, progress: mux)
        try await prefetcher.schedule(revision("r1"))
        #expect(await stats.waitUntilStarted("r1"))

        await prefetcher.cancelAndDrain()
        #expect(await stats.finished == ["r1"])
        #expect(await stats.cancelled == ["r1"])
        let filesAtReturn = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == filesAtReturn)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("消费等待预取时取消会停止子任务并清理快照")
    func cancellingConsumerDrainsPendingSnapshot() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = PrefetchStats()
        let session = DelayedSnapshotSession(stats: stats, delayNanoseconds: 1_000_000_000)
        let mux = MigrationPrefetchProgressMux { _ in }
        let prefetcher = OnePageMigrationSnapshotPrefetcher(session: session, workspace: root, progress: mux)
        let r1 = revision("r1")

        try await prefetcher.schedule(r1)
        #expect(await stats.waitUntilStarted("r1"))
        let consumer = Task { try await prefetcher.consume(r1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        _ = try? await consumer.value

        #expect(await stats.finished == ["r1"])
        #expect(await stats.cancelled == ["r1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("后台进度只附注前台状态，不累计或复制前台记录")
    func backgroundProgressDoesNotAccumulateForegroundRecords() async throws {
        let collector = ProgressOutput()
        let mux = MigrationPrefetchProgressMux { update in await collector.append(update) }
        let fileRecord = RepositoryProgressRecord(kind: .file, message: "已写入", path: "A.swift")
        let foreground = RepositoryOperationProgress(
            "正在写入 Git 快照", detail: "前台", records: [fileRecord],
            migrationProgress: RepositoryMigrationProgress(completedRevisions: 1, totalRevisions: 3, currentRevision: "r2")
        )
        await mux.foreground(foreground)
        await mux.background(revision: revision("r3"), update: RepositoryOperationProgress("导出 SVN", detail: "下载中", records: [RepositoryProgressRecord(kind: .file, message: "后台", path: "B.swift")]))

        let updates = await collector.values
        #expect(updates.count == 2)
        #expect(updates[0].records.count == 1)
        #expect(updates[1].records.isEmpty)
        let records = updates.flatMap(\.records)
        let foregroundRecords = records.filter { $0.path == "A.swift" }
        let backgroundRecords = records.filter { $0.path == "B.swift" }
        #expect(foregroundRecords.count == 1)
        #expect(backgroundRecords.isEmpty)
        #expect(updates[1].migrationProgress == foreground.migrationProgress)
        #expect(updates[1].detail?.contains("同时后台预取 r3") == true)
    }

    private func revision(_ id: String) -> MigrationRevision {
        MigrationRevision(id: id, author: "fixture", date: .distantPast, message: id)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var pipelineRevisions: [MigrationRevision] {
        ["r1", "r2", "r3"].map { MigrationRevision(id: $0, author: "fixture", date: .distantPast, message: $0) }
    }
}

private struct DelayedSnapshotSession: RepositoryMigrationSnapshotSession {
    let stats: PrefetchStats
    let delayNanoseconds: UInt64

    func exportSnapshot(revision: MigrationRevision, to directory: URL,
                        progress: @escaping RepositoryOperationProgressHandler) async throws {
        await stats.recordStart(revision.id)
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(revision.id.utf8).write(to: directory.appendingPathComponent("\(revision.id).txt"))
            await progress(RepositoryOperationProgress("已导出", records: [RepositoryProgressRecord(kind: .file, message: "已导出", path: "\(revision.id).txt")]))
            await stats.recordFinish(revision.id, cancelled: false)
        } catch is CancellationError {
            await stats.recordFinish(revision.id, cancelled: true)
            throw CancellationError()
        } catch {
            await stats.recordFinish(revision.id, cancelled: Task.isCancelled)
            throw error
        }
    }
}

private actor PrefetchStats {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var cancelled: [String] = []
    private var active = 0
    private(set) var maximumConcurrent = 0

    func recordStart(_ revision: String) {
        started.append(revision); active += 1; maximumConcurrent = max(maximumConcurrent, active)
    }

    func recordFinish(_ revision: String, cancelled wasCancelled: Bool) {
        finished.append(revision); active -= 1
        if wasCancelled { cancelled.append(revision) }
    }

    func waitUntilStarted(_ revision: String) async -> Bool {
        for _ in 0 ..< 100 {
            if started.contains(revision) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return started.contains(revision)
    }
}

private actor ProgressOutput {
    private(set) var values: [RepositoryOperationProgress] = []
    func append(_ value: RepositoryOperationProgress) { values.append(value) }
}

private actor PipelineStats {
    private var exportStarts: [String: ContinuousClock.Instant] = [:]
    private var exportFinishes: [String: ContinuousClock.Instant] = [:]
    private var appendStarts: [String: ContinuousClock.Instant] = [:]
    private var appendFinishes: [String: ContinuousClock.Instant] = [:]
    private(set) var appended: [String] = []
    private(set) var maximumExports = 0
    private var activeExports = 0
    private var cancelled: Set<String> = []

    func exportStarted(_ revision: String) {
        activeExports += 1; maximumExports = max(maximumExports, activeExports)
        exportStarts[revision] = .now
    }
    func exportFinished(_ revision: String, cancelled: Bool) {
        activeExports -= 1; exportFinishes[revision] = .now
        if cancelled { self.cancelled.insert(revision) }
    }
    func appendStarted(_ revision: String) { appendStarts[revision] = .now }
    func appendFinished(_ revision: String) { appendFinishes[revision] = .now; appended.append(revision) }
    func didOverlap(source: String, target: String) -> Bool {
        guard let sourceStart = exportStarts[source], let sourceFinish = exportFinishes[source],
              let targetStart = appendStarts[target], let targetFinish = appendFinishes[target] else { return false }
        return sourceStart < targetFinish && sourceFinish > targetStart
    }
    func finishedExport(_ revision: String) -> Bool { exportFinishes[revision] != nil }
    func cancelledExport(_ revision: String) -> Bool { cancelled.contains(revision) }
}

private struct PipelineSource: RepositoryMigrationSourceProvider {
    let id = ProviderID(rawValue: "pipeline-source")
    let stats: PipelineStats
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r3", mode: mode, revisions: pipelineFixtureRevisions)
    }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await PipelineSnapshotSession(stats: stats).exportSnapshot(revision: revision, to: directory, progress: progress)
    }
    func makeMigrationSnapshotSession(plan: MigrationSourcePlan, in workspace: URL) async throws -> any RepositoryMigrationSnapshotSession {
        PipelineSnapshotSession(stats: stats)
    }
}

private struct PipelineWorkingCopySource: RepositoryWorkingCopyMigrationSourceProvider {
    let id = ProviderID(rawValue: "pipeline-wc-source")
    let root: URL
    let stats: PipelineStats
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await planWorkingCopyHistory(from: location, mode: mode, through: "r3", after: nil, progress: progress)
    }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo {
        MigrationWorkingCopyInfo(directory: root, sourceURL: "file:///fixture", repositoryUUID: "fixture", baseRevision: "r3")
    }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r3", mode: mode, revisions: pipelineFixtureRevisions)
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws {}
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await PipelineSnapshotSession(stats: stats).exportSnapshot(revision: revision, to: directory, progress: progress)
    }
    func makeMigrationSnapshotSession(plan: MigrationSourcePlan, in workspace: URL, seedWorkingCopy: URL?) async throws -> any RepositoryMigrationSnapshotSession {
        PipelineSnapshotSession(stats: stats)
    }
}

private struct PipelineSnapshotSession: RepositoryMigrationSnapshotSession {
    let stats: PipelineStats
    func exportSnapshot(revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        await stats.exportStarted(revision.id)
        do {
            try await Task.sleep(nanoseconds: revision.id == "r2" ? 500_000_000 : 20_000_000)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try revision.id.write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
            await stats.exportFinished(revision.id, cancelled: false)
        } catch is CancellationError {
            await stats.exportFinished(revision.id, cancelled: true)
            throw CancellationError()
        } catch {
            await stats.exportFinished(revision.id, cancelled: Task.isCancelled)
            throw error
        }
    }
}

private actor PipelineTarget: RepositoryVerifiedMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    let stats: PipelineStats
    init(stats: PipelineStats) { self.stats = stats }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws { try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true) }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { fatalError("verified fixture only") }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws { try copyFixtureTree(from: directory, to: destination) }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "fixture") }
    func makeVerifiedMigrationSession(at repository: URL) async throws -> any RepositoryVerifiedMigrationSession { PipelineVerifiedSession(repository: repository, stats: stats) }
}

private actor PipelineWorkingCopyTarget: RepositoryWorkingCopyMigrationTargetProvider, RepositoryVerifiedMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    let stats: PipelineStats
    let failRevision: String?
    init(stats: PipelineStats, failRevision: String? = nil) { self.stats = stats; self.failRevision = failRevision }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws { try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true) }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { fatalError("verified fixture only") }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws { try copyFixtureTree(from: directory, to: destination) }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "fixture") }
    func makeVerifiedMigrationSession(at repository: URL) async throws -> any RepositoryVerifiedMigrationSession { PipelineVerifiedSession(repository: repository, stats: stats, failRevision: failRevision) }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws {}
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws {}
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws { try await initializeMigration(at: preview, branch: branch) }
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { fatalError("verified fixture only") }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {}
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "fixture") }
}

private actor PipelineVerifiedSession: RepositoryVerifiedMigrationSession {
    let repository: URL
    let stats: PipelineStats
    let failRevision: String?
    init(repository: URL, stats: PipelineStats, failRevision: String? = nil) { self.repository = repository; self.stats = stats; self.failRevision = failRevision }
    func appendVerifiedSnapshot(from snapshot: URL, files: [MigrationFileEntry], revision: MigrationRevision, author: MigrationAuthor, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        await stats.appendStarted(revision.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        if revision.id == failRevision { throw VersionControlError.executionFailed("fixture verification failed") }
        try copyFixtureTree(from: snapshot, to: repository)
        await stats.appendFinished(revision.id)
        return String(repeating: String(revision.id.dropFirst()), count: 40).prefix(40).description
    }
}

private let pipelineFixtureRevisions = ["r1", "r2", "r3"].map { MigrationRevision(id: $0, author: "fixture", date: .distantPast, message: $0) }

private func copyFixtureTree(from source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for item in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" { try FileManager.default.removeItem(at: item) }
    for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
        try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
    }
}
