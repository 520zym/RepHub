import Foundation
import Testing
import RepHubUI
import RepositoryApplication

@Suite("迁移界面状态")
@MainActor
struct RepositoryMigrationModelTests {
    @Test("迁移预检保留退出取消保护但不阻断工作区阅读")
    func migrationParticipatesInWorkspaceOperationGuard() async throws {
        let workspace = WorkspaceModel(service: RepositoryService(providers: []),
                                       migrationService: RepositoryMigrationService(sources: [], targets: []))
        let model = try #require(workspace.repositoryMigration)
        model.sourceURL = "https://example.test/trunk"
        model.targetURL = "https://example.test/empty.git"
        model.destinationParent = FileManager.default.temporaryDirectory
        model.directoryName = "migration-guard-\(UUID().uuidString)"
        model.makePlan()
        #expect(workspace.isOperating)
        #expect(!workspace.isInteractionLocked)
        workspace.cancelOperation()
        #expect(model.isCancelling)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!workspace.isOperating)
    }

    @Test("修改来源地址不会沿用旧仓库的选定子目录")
    func changedSourceClearsOldSelection() {
        let model = RepositoryMigrationModel(service: RepositoryMigrationService(sources: [], targets: []))
        model.prefillSource(url: "https://example.test/old/trunk")
        model.sourceURL = "https://example.test/new"
        model.sourceURLChanged()
        #expect(model.selectedSourceURL == nil)
        #expect(model.sourceLocation.url == "https://example.test/new")
    }

    @Test("关闭迁移窗口清除会话凭据和旧选择")
    func dismissClearsCredentials() {
        let model = RepositoryMigrationModel(service: RepositoryMigrationService(sources: [], targets: []))
        model.username = "temporary-user"; model.password = "temporary-test-secret"
        model.prefillSource(url: "https://example.test/trunk")
        model.dismiss()
        #expect(model.password.isEmpty)
        #expect(model.username.isEmpty)
        #expect(model.selectedSourceURL == nil)
        #expect(model.stage == .form)
    }

    @Test("预检失败回到填写状态，不冒充已经生成计划")
    func failedPlanStaysInForm() async throws {
        let model = RepositoryMigrationModel(service: RepositoryMigrationService(sources: [], targets: []))
        model.sourceURL = "https://example.test/trunk"
        model.targetURL = "https://example.test/empty.git"
        model.destinationParent = FileManager.default.temporaryDirectory
        model.directoryName = "migration-ui-test-\(UUID().uuidString)"
        model.makePlan()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
        #expect(model.stage == .form)
        #expect(model.plan == nil)
        #expect(model.errorMessage != nil)
    }
}
