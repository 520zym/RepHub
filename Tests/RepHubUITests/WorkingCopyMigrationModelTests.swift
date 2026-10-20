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

    @Test("转换失败后保留同一隔离作业，以便断点续跑")
    func failedPreviewRetainsTheSameJobForResume() async throws {
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
        #expect(model.plan?.id == firstPlan.id)
        #expect(model.plan?.authors == firstPlan.authors)
        #expect(firstFolder.lastPathComponent.contains(firstPlan.id.uuidString))
        model.preparePreview()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let secondFolder = try #require(model.preservedDirectory)
        defer { try? FileManager.default.removeItem(at: secondFolder) }
        #expect(secondFolder == firstFolder)
        #expect(model.errorMessage?.contains("fixture preparation failed") == true)
    }

    @Test("选择检查点后直接恢复预览，并只自动补入当前 BASE 内的新提交", arguments: [false, true])
    func completedCheckpointResumesDirectlyToPreview(hasNewRevision: Bool) async throws {
        let suite = "RepHub.DirectResumeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigrationResumeStore(defaults: defaults, legacyWorkingCopyRoot: root)
        let source = PlanningWorkingSource()
        let target = EmptyWorkingTarget()
        let original = WorkingCopyMigrationService(source: source, target: target, resumeStore: store)
        let plan = try await original.plan(at: root, remoteURL: "https://target.example.test/empty.git",
                                          branch: "main", mode: .history, action: .initial, progress: { _ in })
        let preview = try await original.prepare(plan, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.repository.deletingLastPathComponent()) }
        let record = try #require(store.records(kind: .workingCopy).first)
        let model = WorkingCopyMigrationModel(
            service: WorkingCopyMigrationService(source: PlanningWorkingSource(baseRevision: hasNewRevision ? "r2" : "r1"), target: target, resumeStore: store),
            authorDirectory: MigrationAuthorDirectoryStore(defaults: defaults), resumeStore: store)

        model.resume(from: record)
        for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        #expect(model.errorMessage == nil)
        #expect(model.stage == .preview)
        #expect(model.plan?.id == plan.id)
        #expect(model.preview?.mappings.first?.targetCommit == preview.mappings.first?.targetCommit)
        #expect(model.preview?.mappings.map(\.source.id) == (hasNewRevision ? ["r1", "r2"] : ["r1"]))
        #expect(await target.appendCapture.count == (hasNewRevision ? 2 : 1))
        #expect(model.plan?.source.anchor == (hasNewRevision ? "r2" : "r1"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }

    @Test("首次迁移默认不追溯复制前历史，修改范围会废弃旧计划")
    func initialHistoryScopeDefaultsToCurrentCopyAndInvalidatesPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PlanningWorkingSource()
        let model = WorkingCopyMigrationModel(service: WorkingCopyMigrationService(source: source, target: EmptyWorkingTarget()))
        model.prefill(directory: root)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.includeCopyHistory)

        model.remoteURL = "https://target.example.test/empty.git"
        model.makePlan()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.plan?.source.includeCopyHistory == false)
        let initialScope = await source.scopeCapture.last
        #expect(initialScope == false)

        model.includeCopyHistory = true
        model.invalidatePlan()
        #expect(model.plan == nil)
        #expect(model.stage == .form)
    }

    @Test("快照方式不会无意请求复制前历史")
    func snapshotDoesNotRequestCopyHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PlanningWorkingSource()
        let model = WorkingCopyMigrationModel(service: WorkingCopyMigrationService(source: source, target: EmptyWorkingTarget()))
        model.prefill(directory: root)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        model.remoteURL = "https://target.example.test/empty.git"
        model.mode = .snapshot
        model.includeCopyHistory = true
        model.makePlan()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        let snapshotScope = await source.scopeCapture.last
        #expect(snapshotScope == false)
        #expect(model.plan?.source.includeCopyHistory == false)
    }
}

private actor CopyHistoryScopeCapture {
    private(set) var last: Bool?
    func record(_ value: Bool) { last = value }
}

private struct PlanningWorkingSource: RepositoryWorkingCopyMigrationSourceProvider {
    let id = ProviderID.svn
    var delaysInspection = false
    var baseRevision = "r1"
    let scopeCapture = CopyHistoryScopeCapture()
    private var sourceURL: String { "https://source.example.test/svn/second" }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo {
        if delaysInspection { try await Task.sleep(for: .seconds(30)) }
        return .init(directory: directory, sourceURL: sourceURL, repositoryUUID: "test-uuid", baseRevision: baseRevision)
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws { }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await planMigration(from: location, mode: mode, progress: progress)
    }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, includeCopyHistory: Bool, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        await scopeCapture.record(includeCopyHistory)
        let anchor = revision ?? baseRevision
        let candidates = [MigrationRevision(id: "r1", author: "test-author", date: .now, message: "fixture"),
                          MigrationRevision(id: "r2", author: "test-author", date: .now, message: "later fixture")]
        return .init(providerID: .svn, location: location, anchor: anchor, mode: mode,
                     includeCopyHistory: includeCopyHistory,
                     revisions: candidates.filter { candidate in candidate.id <= anchor && (previousRevision.map { candidate.id > $0 } ?? true) })
    }
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        .init(providerID: .svn, location: location, anchor: "r1", mode: mode,
              revisions: [.init(id: "r1", author: "test-author", date: .now, message: "fixture")])
    }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
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
    let appendCapture = WorkingTargetAppendCapture()
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws { }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws { }
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {
        if rejectsPreparation { throw VersionControlError.executionFailed("fixture preparation failed") }
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    }
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { "" }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws { }
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
    func checkMigrationTarget(remoteURL: String, branch: String) async throws { }
    func initializeMigration(at directory: URL, branch: String) async throws { }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        await appendCapture.append()
        return String(repeating: revision.id == "r1" ? "a" : "b", count: 40)
    }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws { }
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
}

private actor WorkingTargetAppendCapture {
    private(set) var count = 0
    func append() { count += 1 }
}
