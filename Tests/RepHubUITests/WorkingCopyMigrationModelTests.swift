import Foundation
import Testing
import RepHubUI
import RepositoryApplication
import VersionControlCore

@Suite("当前工作副本迁移界面状态")
@MainActor
struct WorkingCopyMigrationModelTests {
    @Test("只读预检立即展示活动状态并可取消")
    func planningProgressStartsBeforeSlowInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkingCopyMigrationModel(service: WorkingCopyMigrationService(
            source: PlanningWorkingSource(delaysInspection: true), target: EmptyWorkingTarget()))
        model.prefill(directory: root)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        model.remoteURL = "https://target.example.test/empty.git"
        model.makePlan()
        #expect(model.stage == .planning)
        #expect(model.transferProgress.isActive)
        #expect(!model.transferProgress.phase.isEmpty)
        #expect(model.transferProgress.startedAt != nil)
        model.cancel()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
        #expect(!model.transferProgress.isActive)
        #expect(model.stage == .form)
    }

    @Test("预检自动使用通讯录映射且手工编辑不会修改已保存资料")
    func planResolvesSavedAuthors() async throws {
        let suite = "RepHub.AuthorModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authors = MigrationAuthorDirectoryStore(defaults: defaults)
        try authors.save(authors: ["test-author": .init(name: "Test Author", email: "test-author@example.test")],
                         sourceURL: "https://source.example.test/svn/first")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkingCopyMigrationModel(service: WorkingCopyMigrationService(
            source: PlanningWorkingSource(), target: EmptyWorkingTarget()), authorDirectory: authors)
        model.prefill(directory: root)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        model.remoteURL = "https://target.example.test/empty.git"
        model.makePlan()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let plan = try #require(model.plan)
        #expect(model.stage == .prepared)
        #expect(plan.authors["test-author"]?.email == "test-author@example.test")
        model.updateAuthor("test-author", name: "Edited", email: "edited@example.test")
        #expect(model.plan?.id != plan.id)
        #expect(model.plan?.authors["test-author"]?.name == "Edited")
        let reloaded = MigrationAuthorDirectoryStore(defaults: defaults)
        let resolved = reloaded.resolve(authors: plan.authors, sourceURL: plan.source.location.url)
        #expect(resolved["test-author"]?.name == "Test Author")
    }

    @Test("迁移服务纳入工作区退出与操作保护")
    func participatesInWorkspaceGuard() async throws {
        let workspace = WorkspaceModel(service: RepositoryService(providers: []),
                                       workingCopyMigrationService: WorkingCopyMigrationService(source: EmptyWorkingSource(), target: EmptyWorkingTarget()))
        let model = try #require(workspace.workingCopyMigration)
        model.prefill(directory: FileManager.default.temporaryDirectory)
        #expect(workspace.isOperating)
        workspace.cancelOperation()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!workspace.isOperating)
    }

    @Test("转换失败后用新隔离作业重试并保留上次位置")
    func failedPreviewCanStartANewJob() async throws {
        let suite = "RepHub.AuthorRetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkingCopyMigrationService(source: PlanningWorkingSource(),
            target: EmptyWorkingTarget(rejectsPreparation: true))
        let model = WorkingCopyMigrationModel(service: service,
            authorDirectory: MigrationAuthorDirectoryStore(defaults: defaults))
        model.prefill(directory: root)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        model.remoteURL = "https://target.example.test/empty.git"
        model.makePlan()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let firstPlan = try #require(model.plan)
        model.preparePreview()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let firstFolder = try #require(model.preservedDirectory)
        defer { try? FileManager.default.removeItem(at: firstFolder) }
        #expect(model.stage == .prepared)
        #expect(model.plan?.id != firstPlan.id)
        #expect(model.plan?.authors == firstPlan.authors)
        #expect(firstFolder.lastPathComponent.contains(firstPlan.id.uuidString))
        model.preparePreview()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let secondFolder = try #require(model.preservedDirectory)
        defer { try? FileManager.default.removeItem(at: secondFolder) }
        #expect(secondFolder != firstFolder)
        #expect(model.errorMessage?.contains("fixture preparation failed") == true)
    }
}

private struct PlanningWorkingSource: RepositoryWorkingCopyMigrationSourceProvider {
    let id = ProviderID.svn
    var delaysInspection = false
    private var sourceURL: String { "https://source.example.test/svn/second" }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo {
        if delaysInspection { try await Task.sleep(for: .seconds(30)) }
        return .init(directory: directory, sourceURL: sourceURL, repositoryUUID: "test-uuid", baseRevision: "r1")
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws { }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await planMigration(from: location, mode: mode, progress: progress)
    }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        .init(providerID: .svn, location: location, anchor: "r1", mode: mode,
              revisions: [.init(id: "r1", author: "test-author", date: .now, message: "fixture")])
    }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws { }
}

private struct EmptyWorkingSource: RepositoryWorkingCopyMigrationSourceProvider {
    let id = ProviderID.svn
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws { }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo { throw VersionControlError.invalidRepository("fixture") }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan { throw VersionControlError.invalidRepository("fixture") }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan { throw VersionControlError.invalidRepository("fixture") }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws { }
}

private struct EmptyWorkingTarget: RepositoryWorkingCopyMigrationTargetProvider {
    let id = ProviderID.git
    var rejectsPreparation = false
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws { }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws { }
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {
        if rejectsPreparation { throw VersionControlError.executionFailed("fixture preparation failed") }
    }
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { "" }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws { }
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws { }
    func initializeMigration(at directory: URL, branch: String) async throws { }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { "" }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws { }
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws { }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
}
