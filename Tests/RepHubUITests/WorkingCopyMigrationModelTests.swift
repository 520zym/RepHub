import Foundation
import Testing
import RepHubUI
import RepositoryApplication
import VersionControlCore

@Suite("当前工作副本迁移界面状态")
@MainActor
struct WorkingCopyMigrationModelTests {
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
    func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws { }
    func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? { nil }
    func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws { }
    func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws { }
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
