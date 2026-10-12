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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-wc-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
}

private struct WorkingCopySourceFixture: RepositoryWorkingCopyMigrationSourceProvider {
    let id = ProviderID(rawValue: "working-copy-source-fixture")
    let root: URL
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan { try await planWorkingCopyHistory(from: location, mode: mode, through: "r9", after: nil, progress: progress) }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo { MigrationWorkingCopyInfo(directory: root, sourceURL: "https://example.test/svn/project", repositoryUUID: "uuid", baseRevision: "r9") }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r9", mode: mode, revisions: [MigrationRevision(id: "r9", author: "svn-user", date: .distantPast, message: "change")])
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws {}
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {}
}

private actor WorkingCopyTargetFixture: RepositoryWorkingCopyMigrationTargetProvider {
    nonisolated let id: ProviderID = .git
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws {}
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { String(repeating: "a", count: 40) }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {}
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { MigrationPublicationResult(state: .notPublished, message: "") }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws {}
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws {}
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {}
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { String(repeating: "a", count: 40) }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {}
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { MigrationPublicationResult(state: .notPublished, message: "") }
}
