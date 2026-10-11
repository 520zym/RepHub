import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("工作区更新编排")
struct RepositoryOperationTests {
    @Test("只执行所选目标，完成后读取全部绑定并脱敏记录")
    func performsOneTargetAndRefreshesAll() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = OperationFixtureProvider(id: .git, root: root)
        let svn = OperationFixtureProvider(id: .svn, root: root)
        let service = RepositoryService(providers: [git, svn])
        let workspace = try await service.open(directory: root)
        let binding = try #require(workspace.bindings.first { $0.providerID == .git })
        let response = try await service.perform(.update, bindingID: binding.id, in: workspace, progress: { _ in })
        #expect(response.result.outcome == .succeeded)
        #expect(await git.operationCount == 1)
        #expect(await svn.operationCount == 0)
        #expect(response.snapshots.count == 2)
        #expect(await git.statusCount == 1)
        #expect(await svn.statusCount == 1)
        #expect(!response.result.details.contains("secret"))
        #expect(!response.result.details.contains("private-token"))
    }

    @Test("操作中拒绝第二次写入，取消后仍刷新所有来源")
    func serializesWritesAndRefreshesAfterCancellation() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = OperationFixtureProvider(id: .git, root: root, waitsForCancellation: true)
        let svn = OperationFixtureProvider(id: .svn, root: root)
        let service = RepositoryService(providers: [git, svn])
        let workspace = try await service.open(directory: root)
        let binding = try #require(workspace.bindings.first { $0.providerID == .git })
        let other = try #require(workspace.bindings.first { $0.providerID == .svn })
        let task = Task { try await service.perform(.update, bindingID: binding.id, in: workspace, progress: { _ in }) }
        await git.waitForOperation()
        do {
            _ = try await service.perform(.update, bindingID: other.id, in: workspace, progress: { _ in })
            Issue.record("不应允许并行写入共享工作区")
        } catch VersionControlError.unsupported {}
        task.cancel()
        let response = try await task.value
        #expect(response.result.outcome == .cancelled)
        #expect(response.snapshots.count == 2)
        #expect(await svn.operationCount == 0)
        #expect(await git.statusCount == 1)
        #expect(await svn.statusCount == 1)
        #expect(!(await git.refreshedWhileCancelled))
    }

    @Test("操作前检测分支改变会停止写入，失败后仍核对状态")
    func rejectsStaleBinding() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = OperationFixtureProvider(id: .git, root: root)
        let service = RepositoryService(providers: [git])
        let workspace = try await service.open(directory: root)
        await git.changeBranch()
        let binding = try #require(workspace.bindings.first)
        let response = try await service.perform(.update, bindingID: binding.id, in: workspace, progress: { _ in })
        #expect(response.result.outcome == .failed)
        #expect(response.result.details.contains("分支或远端已经改变"))
        #expect(await git.operationCount == 0)
        #expect(response.workspace.bindings.first?.currentBranch == "changed")
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-operation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor OperationFixtureProvider: RepositoryOperationProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName = "隔离测试"
    let root: URL
    let waitsForCancellation: Bool
    var currentBranch = "main"
    var operationCount = 0
    var statusCount = 0
    var refreshedWhileCancelled = false
    var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: ProviderID, root: URL, waitsForCancellation: Bool = false) {
        self.id = id; self.root = root; self.waitsForCancellation = waitsForCancellation
    }

    func waitForOperation() async {
        if operationCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func changeBranch() { currentBranch = "changed" }
    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: root, currentBranch: currentBranch, capabilities: [.status, .history, .update])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        statusCount += 1
        refreshedWhileCancelled = refreshedWhileCancelled || Task.isCancelled
        return [FileChange(path: "sample.txt", kind: .modified)]
    }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func perform(_ operation: RepositoryOperationKind, in binding: RepositoryBinding,
                 progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryOperationResult {
        operationCount += 1
        let waiters = startWaiters; startWaiters = []
        waiters.forEach { $0.resume() }
        if waitsForCancellation { try await Task.sleep(for: .seconds(30)) }
        return RepositoryOperationResult(kind: operation, bindingID: binding.id, outcome: .succeeded,
            summary: "完成", details: "https://user:secret@example.invalid/repository?token=private-token")
    }
}
