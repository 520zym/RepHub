import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("迁移检查点恢复")
struct RepositoryMigrationResumeTests {
    @Test("一次预览只建立一个来源快照会话，并按修订顺序复用")
    func reusesOneSnapshotSessionInRevisionOrder() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let stats = SnapshotSessionStats()
        let source = ResumeSource(stats: stats)
        let plan = try await makePlan(root: root, source: source)
        let service = RepositoryMigrationService(sources: [source], targets: [ResumeTarget()])

        _ = try await service.prepare(plan, progress: { _ in })

        #expect(await stats.createdCount == 1)
        #expect(await stats.exportedRevisions == ["r1", "r2"])
    }

    @Test("新的服务实例可恢复不含历史范围选项的旧版检查点")
    func resumesVerifiedCheckpointInNewService() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await makePlan(root: root, source: ResumeSource())
        let interrupted = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget(failRevision: "r2")])
        await #expect(throws: Error.self) { try await interrupted.prepare(plan, progress: { _ in }) }
        let checkpoint = try #require(await interrupted.partialDirectory(for: plan.id))
            .appendingPathComponent("checkpoint.json")

        var stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        var storedPlan = try #require(stored["plan"] as? [String: Any])
        storedPlan.removeValue(forKey: "includeCopyHistory")
        stored["plan"] = storedPlan
        stored["version"] = 1
        stored.removeValue(forKey: "verifiedObjectTree")
        try JSONSerialization.data(withJSONObject: stored).write(to: checkpoint, options: .atomic)

        let resumed = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget()])
        let restored = try await resumed.resume(from: checkpoint)
        #expect(restored.id == plan.id)
        #expect(restored.source.includeCopyHistory)
        let preview = try await resumed.prepare(restored, progress: { _ in })
        #expect(preview.mappings.map(\.source.id) == ["r1", "r2"])
        #expect(FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent("second.txt").path))
    }

    @Test("伪造快照路径不能恢复")
    func refusesTraversalInCheckpoint() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await makePlan(root: root, source: ResumeSource())
        let interrupted = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget(failRevision: "r2")])
        await #expect(throws: Error.self) { try await interrupted.prepare(plan, progress: { _ in }) }
        let checkpoint = try #require(await interrupted.partialDirectory(for: plan.id))
            .appendingPathComponent("checkpoint.json")
        var contents = try String(contentsOf: checkpoint, encoding: .utf8)
        contents = contents.replacingOccurrences(of: "source-", with: "../source-", options: [], range: contents.range(of: "source-"))
        try contents.write(to: checkpoint, atomically: true, encoding: .utf8)

        let resumed = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget()])
        await #expect(throws: VersionControlError.self) { try await resumed.resume(from: checkpoint) }
    }

    @Test("移动到其他父目录的检查点不能恢复")
    func refusesMovedCheckpointDirectory() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await makePlan(root: root, source: ResumeSource())
        let interrupted = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget(failRevision: "r2")])
        await #expect(throws: Error.self) { try await interrupted.prepare(plan, progress: { _ in }) }
        let original = try #require(await interrupted.partialDirectory(for: plan.id))
        let otherParent = root.appendingPathComponent("relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: otherParent, withIntermediateDirectories: true)
        let relocated = otherParent.appendingPathComponent(original.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: original, to: relocated)

        let resumed = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget()])
        await #expect(throws: VersionControlError.self) {
            try await resumed.resume(from: relocated.appendingPathComponent("checkpoint.json"))
        }
    }

    @Test("首个提交尚未核对时恢复被拒绝")
    func refusesUnverifiedFirstCommit() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await makePlan(root: root, source: ResumeSource())
        let interrupted = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget(failExport: true)])
        await #expect(throws: Error.self) { try await interrupted.prepare(plan, progress: { _ in }) }
        let checkpoint = try #require(await interrupted.partialDirectory(for: plan.id))
            .appendingPathComponent("checkpoint.json")
        let resumed = RepositoryMigrationService(sources: [ResumeSource()], targets: [ResumeTarget()])
        await #expect(throws: VersionControlError.self) { try await resumed.resume(from: checkpoint) }
    }

    private func makePlan(root: URL, source: ResumeSource) async throws -> MigrationPlan {
        let service = RepositoryMigrationService(sources: [source], targets: [ResumeTarget()])
        return try await service.plan(sourceProviderID: source.id,
                                      location: RemoteRepositoryLocation(url: "https://example.test/svn/project"),
                                      mode: .history, targetProviderID: .git, remoteURL: "https://example.test/git/project.git",
                                      branch: "main", destination: root.appendingPathComponent("result"), progress: { _ in })
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct ResumeSource: RepositoryMigrationSourceProvider {
    let id = ProviderID(rawValue: "resume-source")
    let stats: SnapshotSessionStats?
    init(stats: SnapshotSessionStats? = nil) { self.stats = stats }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r2", mode: mode,
                            revisions: [
                                MigrationRevision(id: "r1", author: "a", date: .distantPast, message: "first"),
                                MigrationRevision(id: "r2", author: "a", date: .now, message: "second"),
                            ])
    }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await ResumeSnapshotSession(stats: stats).exportSnapshot(revision: revision, to: directory, progress: progress)
    }

    func makeMigrationSnapshotSession(plan: MigrationSourcePlan, in workspace: URL) async throws -> any RepositoryMigrationSnapshotSession {
        await stats?.created()
        return ResumeSnapshotSession(stats: stats)
    }
}

private struct ResumeSnapshotSession: RepositoryMigrationSnapshotSession {
    let stats: SnapshotSessionStats?

    func exportSnapshot(revision: MigrationRevision, to directory: URL,
                        progress: @escaping RepositoryOperationProgressHandler) async throws {
        await stats?.exported(revision.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = revision.id == "r1" ? "one\n" : "two\n"
        try content.write(to: directory.appendingPathComponent(revision.id == "r1" ? "first.txt" : "second.txt"), atomically: true, encoding: .utf8)
    }
}

private actor SnapshotSessionStats {
    private(set) var createdCount = 0
    private(set) var exportedRevisions: [String] = []
    func created() { createdCount += 1 }
    func exported(_ revision: String) { exportedRevisions.append(revision) }
}

private actor ResumeTarget: RepositoryMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    private let failRevision: String?
    private let failExport: Bool
    init(failRevision: String? = nil, failExport: Bool = false) { self.failRevision = failRevision; self.failExport = failExport }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        if revision.id == failRevision { throw VersionControlError.executionFailed("simulated interruption") }
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
            try FileManager.default.removeItem(at: item)
        }
        for item in try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
        }
        try Data(revision.id.utf8).write(to: directory.appendingPathComponent(".git/head"))
        return revision.id == "r1" ? String(repeating: "1", count: 40) : String(repeating: "2", count: 40)
    }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {
        if expectedTip == nil, FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/head").path) {
            throw VersionControlError.invalidRepository("unverified")
        }
    }
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        if failExport { throw VersionControlError.executionFailed("simulated export failure") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String,
                          progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        MigrationPublicationResult(state: .notPublished, message: "fixture")
    }
}
