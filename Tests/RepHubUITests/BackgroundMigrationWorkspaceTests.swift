import Foundation
import Testing
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@Suite("工作台后台迁移状态")
@MainActor
struct BackgroundMigrationWorkspaceTests {
    @Test("收起迁移不取消任务，恢复不重置计划，结束后须显式清除标记")
    func hidingAndRestoringKeepsBackgroundMigrationState() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = BackgroundMigrationSource(delayNanoseconds: 250_000_000)
        let workspace = WorkspaceModel(service: RepositoryService(providers: [BackgroundWorkspaceProvider()]),
                                       migrationService: RepositoryMigrationService(sources: [source], targets: [BackgroundMigrationTarget()]))
        let migration = try #require(workspace.repositoryMigration)
        migration.sourceURL = "file:///fixture/source"
        migration.targetURL = "file:///fixture/target.git"
        migration.destinationParent = root
        migration.directoryName = "converted"
        migration.makePlan()
        try await waitUntil { !migration.isBusy && migration.plan != nil }
        migration.preparePreview()
        try await waitUntil { migration.stage == .converting }
        let destination = try #require(migration.destination)

        workspace.hideRepositoryMigration()
        #expect(workspace.hasBackgroundMigration)
        #expect(!workspace.showsRepositoryMigration)
        #expect(workspace.isOperating)
        #expect(!workspace.isInteractionLocked)
        #expect(workspace.isMigrationProtecting(destination.appendingPathComponent("child")))
        #expect(!workspace.isMigrationProtecting(root.appendingPathComponent("converted-copy")))

        workspace.showRepositoryMigration()
        #expect(workspace.showsRepositoryMigration)
        #expect(migration.sourceURL == "file:///fixture/source")
        #expect(migration.destination == destination)
        #expect(migration.isBusy)

        try await waitUntil { !migration.isBusy && migration.stage == .preview }
        #expect(workspace.hasBackgroundMigration)
        workspace.dismissRepositoryMigration()
        #expect(!workspace.hasBackgroundMigration)
        #expect(!workspace.showsRepositoryMigration)
    }

    @Test("后台迁移允许阅读及切换其他仓库，但锁住来源的父子和符号链接目录")
    func backgroundMigrationProtectsRelatedSourceRootsOnly() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let child = sourceRoot.appendingPathComponent("child", isDirectory: true)
        let siblingPrefix = root.appendingPathComponent("source-copy", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        let linked = root.appendingPathComponent("source-link", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: sourceRoot)

        let source = BackgroundWorkingCopySource(root: sourceRoot, delayNanoseconds: 300_000_000)
        let workspace = WorkspaceModel(service: RepositoryService(providers: [BackgroundWorkspaceProvider()]),
                                       workingCopyMigrationService: WorkingCopyMigrationService(source: source, target: BackgroundWorkingCopyTarget()))
        let migration = try #require(workspace.workingCopyMigration)
        migration.prefill(directory: sourceRoot)
        try await waitUntil { !migration.isBusy }
        migration.remoteURL = "file:///fixture/target.git"
        migration.makePlan()
        try await waitUntil { migration.stage == .planning }

        #expect(workspace.isOperating)
        #expect(!workspace.isInteractionLocked)
        #expect(workspace.isMigrationProtecting(sourceRoot))
        #expect(workspace.isMigrationProtecting(child))
        #expect(workspace.isMigrationProtecting(root))
        #expect(workspace.isMigrationProtecting(linked))
        #expect(!workspace.isMigrationProtecting(siblingPrefix))

        workspace.open(other)
        try await waitUntil { workspace.workspace?.directory == other.standardizedFileURL }
        #expect(!workspace.isInteractionLocked)
        try await waitUntil { !migration.isBusy }
    }

    @Test("后台迁移报错后仍保留入口，只有显式关闭才清除")
    func failedBackgroundMigrationRemainsDismissable() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = BackgroundMigrationSource(delayNanoseconds: 120_000_000, shouldFail: true)
        let workspace = WorkspaceModel(service: RepositoryService(providers: []),
                                       migrationService: RepositoryMigrationService(sources: [source], targets: [BackgroundMigrationTarget()]))
        let migration = try #require(workspace.repositoryMigration)
        migration.sourceURL = "file:///fixture/source"
        migration.targetURL = "file:///fixture/target.git"
        migration.destinationParent = root
        migration.directoryName = "failed"
        migration.makePlan()
        try await waitUntil { migration.isBusy }
        workspace.hideRepositoryMigration()
        try await waitUntil { !migration.isBusy && migration.errorMessage != nil }

        #expect(workspace.hasBackgroundMigration)
        #expect(!workspace.showsRepositoryMigration)
        workspace.dismissRepositoryMigration()
        #expect(!workspace.hasBackgroundMigration)
        #expect(migration.errorMessage == nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-background-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(timeout: UInt64 = 1_500_000_000, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition())
    }
}

private struct BackgroundWorkspaceProvider: VersionControlProvider {
    let id: ProviderID = .git
    let displayName = "后台迁移测试"
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: directory, currentBranch: "main", capabilities: [.status, .history])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
}

private struct BackgroundMigrationSource: RepositoryMigrationSourceProvider {
    let id: ProviderID = .svn
    let delayNanoseconds: UInt64
    var shouldFail = false
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if shouldFail { throw VersionControlError.executionFailed("fixture failure") }
        return MigrationSourcePlan(providerID: id, location: location, anchor: "r1", mode: mode, revisions: [backgroundRevision])
    }
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }
}

private struct BackgroundWorkingCopySource: RepositoryWorkingCopyMigrationSourceProvider {
    let id: ProviderID = .svn
    let root: URL
    let delayNanoseconds: UInt64
    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return MigrationSourcePlan(providerID: id, location: location, anchor: "r1", mode: mode, revisions: [backgroundRevision])
    }
    func inspectMigrationWorkingCopy(at directory: URL, requireClean: Bool) async throws -> MigrationWorkingCopyInfo {
        .init(directory: root, sourceURL: "file:///fixture/source", repositoryUUID: "fixture", baseRevision: "r1")
    }
    func planWorkingCopyHistory(from location: RemoteRepositoryLocation, mode: MigrationMode, through revision: String?, after previousRevision: String?, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return MigrationSourcePlan(providerID: id, location: location, anchor: "r1", mode: mode, revisions: [backgroundRevision])
    }
    func verifyWorkingCopyMigrationSource(_ location: RemoteRepositoryLocation, repositoryUUID: String, revision: String) async throws {}
    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }
}

private let backgroundRevision = MigrationRevision(id: "r1", author: "fixture", date: .distantPast, message: "fixture")

private struct BackgroundMigrationTarget: RepositoryMigrationTargetProvider {
    let id: ProviderID = .git
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws { try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true) }
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { try copyBackgroundTree(from: snapshot, to: directory); return String(repeating: "0", count: 40) }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws { try copyBackgroundTree(from: directory, to: destination) }
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
}

private func copyBackgroundTree(from source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for item in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
        try FileManager.default.removeItem(at: item)
    }
    for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
        try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
    }
}

private struct BackgroundWorkingCopyTarget: RepositoryWorkingCopyMigrationTargetProvider {
    let id: ProviderID = .git
    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}
    func initializeMigration(at directory: URL, branch: String) async throws {}
    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { String(repeating: "0", count: 40) }
    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {}
    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { .init(text: "") }
    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws {}
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws {}
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {}
    func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String { String(repeating: "0", count: 40) }
    func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {}
    func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult { .init(state: .notPublished, message: "") }
}
