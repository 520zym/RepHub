import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class RepositoryCommitModelTests: XCTestCase {
    func testSelectionAndMessagesRemainIndependentPerTarget() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let service = RepositoryService(providers: [git, svn])
        let workspace = fixtureWorkspace()
        let model = RepositoryCommitModel(service: service)

        model.prepare(in: workspace, initialTargets: Set(workspace.bindings.map(\.id)), initialMessage: "初始说明")
        try await waitUntil { model.phase == .ready }

        let gitPreparation = try XCTUnwrap(model.preparations.first { $0.binding.providerID == .git })
        let svnPreparation = try XCTUnwrap(model.preparations.first { $0.binding.providerID == .svn })
        model.setMessage("Git 单独说明", for: gitPreparation.binding.id)
        model.clearSelection(in: svnPreparation)

        XCTAssertEqual(model.message(for: gitPreparation.binding.id), "Git 单独说明")
        XCTAssertEqual(model.message(for: svnPreparation.binding.id), "初始说明")
        XCTAssertTrue(model.selectedFiles(for: svnPreparation.binding.id).isEmpty)
        XCTAssertFalse(model.selectedFiles(for: gitPreparation.binding.id).isEmpty)
        XCTAssertTrue(model.canCommit)
    }

    func testEmptySelectionDisablesCommit() async throws {
        let provider = CommitFixtureProvider(id: .git)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))
        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }

        let preparation = try XCTUnwrap(model.selectedPreparation)
        model.clearSelection(in: preparation)
        XCTAssertFalse(model.canCommit)
    }

    func testSwitchingTargetInvalidatesPreviousPreview() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [git.binding, svn.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))
        model.prepare(in: workspace, initialTargets: [git.binding.id, svn.binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }
        let preparation = try XCTUnwrap(model.preparations.first { $0.binding.providerID == .git })
        let file = try XCTUnwrap(preparation.files.first)
        model.selectFileForPreview(file, in: preparation)
        model.selectBinding(svn.binding.id)
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.patch)
        XCTAssertFalse(model.isLoadingPreview)
    }

    func testFinishedResultDoesNotSubmitAgain() async throws {
        let provider = CommitFixtureProvider(id: .git)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let service = RepositoryService(providers: [provider])
        let model = RepositoryCommitModel(service: service)
        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交一次")
        try await waitUntil { model.phase == .ready }

        let completed = expectation(description: "完成")
        model.commit(in: workspace) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        let firstCount = await provider.log.commitCount()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(model.phase, .finished)

        let repeated = expectation(description: "不应再次提交")
        repeated.isInverted = true
        model.commit(in: workspace) { _ in repeated.fulfill() }
        await fulfillment(of: [repeated], timeout: 0.15)
        let finalCount = await provider.log.commitCount()
        XCTAssertEqual(finalCount, 1)
    }

    func testResetClearsResultsAndProgressState() async throws {
        let provider = CommitFixtureProvider(id: .git)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))
        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }
        let done = expectation(description: "完成")
        model.commit(in: workspace) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.preparations.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedBindingID)
    }

    private func fixtureWorkspace() -> Workspace {
        let git = CommitFixtureProvider(id: .git).binding
        let svn = CommitFixtureProvider(id: .svn).binding
        return Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [git, svn], issues: [])
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "等待提交状态超时")
    }
}

private struct CommitFixtureProvider: RepositoryCommitProvider {
    let id: ProviderID
    let log = CommitFixtureLog()
    var displayName: String { id == .git ? "Git" : "Subversion" }
    var binding: RepositoryBinding {
        RepositoryBinding(providerID: id, providerName: displayName, root: URL(fileURLWithPath: "/tmp/commit-ui"),
                          currentBranch: id == .git ? "main" : "", remoteURL: nil,
                          capabilities: [.status, .diff, .history, .commit])
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? { binding }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [FileChange(path: "Sources/App.swift", kind: .modified), FileChange(path: "README.md", kind: .modified)]
    }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "diff") }
    func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        RepositoryCommitPreparation(binding: binding, baseRevision: id == .git ? "git-base" : "svn-base", files: [
            RepositoryCommitFile(change: FileChange(path: "Sources/App.swift", kind: .modified), fingerprint: "one"),
            RepositoryCommitFile(change: FileChange(path: "README.md", kind: .modified), fingerprint: "two", restriction: id == .svn ? "需要先解决冲突" : nil)
        ])
    }
    func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch { RepositoryPatch(text: "diff -- \(file.change.path)") }
    func commit(_ request: RepositoryCommitRequest, in binding: RepositoryBinding, progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryCommitResult {
        await log.recordCommit()
        await progress(RepositoryOperationProgress("正在提交…", fractionCompleted: 0.5))
        return RepositoryCommitResult(bindingID: binding.id, outcome: .succeeded, revisionID: id == .git ? "abc123" : "r42", summary: "提交完成", committedFiles: request.files.map(\.change))
    }
}

private actor CommitFixtureLog {
    private var count = 0
    func recordCommit() { count += 1 }
    func commitCount() -> Int { count }
}
