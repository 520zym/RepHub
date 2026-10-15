import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class RepositoryCommitModelTests: XCTestCase {
    func testSingleTargetIsAutomaticAndPreservesExplicitFileScope() async throws {
        for id in [ProviderID.git, .svn] {
            let provider = CommitFixtureProvider(id: id)
            let workspace = Workspace(directory: provider.binding.root, bindings: [provider.binding], issues: [])
            let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))
            model.prepare(in: workspace, initialTargets: [], initialMessage: "单目标提交",
                          initialPathsByBinding: [provider.binding.id: ["Sources/App.swift"]])
            try await waitUntil { model.phase == .ready }

            let preparation = try XCTUnwrap(model.selectedPreparation)
            XCTAssertEqual(model.enabledBindingIDs, [provider.binding.id])
            XCTAssertEqual(model.selectedFiles(for: provider.binding.id), ["Sources/App.swift"])
            model.setBindingEnabled(false, for: preparation)
            XCTAssertEqual(model.enabledBindingIDs, [provider.binding.id])
            XCTAssertTrue(model.canCommit)

            model.clearSelection(in: preparation)
            XCTAssertFalse(model.canCommit)
        }
    }

    func testSingleBlockedTargetIsNotEnabledAutomatically() async throws {
        let provider = CommitFixtureProvider(id: .svn, blockingReason: "请先解决冲突")
        let workspace = Workspace(directory: provider.binding.root, bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))
        model.prepare(in: workspace, initialTargets: [], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedPreparation?.blockingReason, "请先解决冲突")
        XCTAssertTrue(model.enabledBindingIDs.isEmpty)
        XCTAssertFalse(model.canCommit)
    }

    func testMultipleTargetsStillRequireExplicitSelection() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))
        model.prepare(in: fixtureWorkspace(), initialTargets: [git.binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.enabledBindingIDs, [git.binding.id])
        let preparation = try XCTUnwrap(model.selectedPreparation)
        model.setBindingEnabled(false, for: preparation)
        XCTAssertTrue(model.enabledBindingIDs.isEmpty)
        XCTAssertFalse(model.canCommit)
    }

    func testMissingCommitAdapterDoesNotAutoEnableAnUnselectedTarget() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitReadOnlyFixtureProvider()
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))
        model.prepare(in: fixtureWorkspace(), initialTargets: [CommitFixtureProvider(id: .svn).binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.preparations.count, 1)
        XCTAssertTrue(model.allowsTargetSelection)
        XCTAssertTrue(model.enabledBindingIDs.isEmpty)
        XCTAssertFalse(model.canCommit)
        model.setBindingEnabled(true, for: try XCTUnwrap(model.selectedPreparation))
        XCTAssertEqual(model.enabledBindingIDs, [git.binding.id])
    }

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

    func testInitialMessagesRestoreDraftsPerTarget() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [git.binding, svn.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))

        model.prepare(in: workspace, initialTargets: [git.binding.id, svn.binding.id], initialMessage: "统一草稿",
                      initialMessages: [git.binding.id: "Git 草稿", svn.binding.id: "SVN 草稿"])
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.message(for: git.binding.id), "Git 草稿")
        XCTAssertEqual(model.message(for: svn.binding.id), "SVN 草稿")
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

    func testNilInitialPathsKeepsAllEligibleFilesSelected() async throws {
        let provider = CommitFixtureProvider(id: .git)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))

        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交")
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedFiles(for: provider.binding.id), ["Sources/App.swift", "README.md"])
    }

    func testExplicitEmptyPathsDoNotFallBackToAllFiles() async throws {
        let provider = CommitFixtureProvider(id: .git)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))

        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交",
                      initialPathsByBinding: [provider.binding.id: []])
        try await waitUntil { model.phase == .ready }

        XCTAssertTrue(model.selectedFiles(for: provider.binding.id).isEmpty)
        XCTAssertFalse(model.canCommit)
    }

    func testExplicitPathsStayIsolatedPerBinding() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [git.binding, svn.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))

        model.prepare(in: workspace, initialTargets: [git.binding.id, svn.binding.id], initialMessage: "提交",
                      initialPathsByBinding: [git.binding.id: ["Sources/App.swift"]])
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedFiles(for: git.binding.id), ["Sources/App.swift"])
        XCTAssertTrue(model.selectedFiles(for: svn.binding.id).isEmpty)
    }

    func testPreparedTargetDefaultsToFirstTargetWithSelectedFiles() async throws {
        let git = CommitFixtureProvider(id: .git)
        let svn = CommitFixtureProvider(id: .svn)
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [git.binding, svn.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [git, svn]))

        model.prepare(in: workspace, initialTargets: [git.binding.id, svn.binding.id], initialMessage: "提交",
                      initialPathsByBinding: [
                        git.binding.id: [],
                        svn.binding.id: ["Sources/App.swift"]
                      ])
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedBindingID, svn.binding.id)
    }

    func testUntrackedDirectoryPathIncludesPreparedDescendantsWithoutTrailingSlash() async throws {
        let provider = CommitFixtureProvider(id: .svn, files: [
            RepositoryCommitFile(change: .init(path: "docs", kind: .untracked), fingerprint: "directory", isDirectory: true),
            RepositoryCommitFile(change: .init(path: "docs/guide/intro.md", kind: .untracked), fingerprint: "one"),
            RepositoryCommitFile(change: .init(path: "docs/guide/images/logo.png", kind: .untracked), fingerprint: "two"),
            RepositoryCommitFile(change: .init(path: "docs-old/notes.md", kind: .untracked), fingerprint: "three"),
            RepositoryCommitFile(change: .init(path: "docs/blocked.md", kind: .untracked), fingerprint: "four", restriction: "受限")
        ])
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))

        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交",
                      initialPathsByBinding: [provider.binding.id: ["docs"]])
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedFiles(for: provider.binding.id), ["docs", "docs/guide/intro.md", "docs/guide/images/logo.png"])
    }

    func testTrackedDirectoryPathDoesNotImplicitlyIncludeDescendants() async throws {
        let provider = CommitFixtureProvider(id: .svn, files: [
            RepositoryCommitFile(change: .init(path: "docs", kind: .modified), fingerprint: "directory", isDirectory: true),
            RepositoryCommitFile(change: .init(path: "docs/guide.md", kind: .modified), fingerprint: "child")
        ])
        let workspace = Workspace(directory: URL(fileURLWithPath: "/tmp/commit-ui"), bindings: [provider.binding], issues: [])
        let model = RepositoryCommitModel(service: RepositoryService(providers: [provider]))

        model.prepare(in: workspace, initialTargets: [provider.binding.id], initialMessage: "提交",
                      initialPathsByBinding: [provider.binding.id: ["docs"]])
        try await waitUntil { model.phase == .ready }

        XCTAssertEqual(model.selectedFiles(for: provider.binding.id), ["docs"])
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
    let files: [RepositoryCommitFile]
    let blockingReason: String?
    let log = CommitFixtureLog()
    init(id: ProviderID, files: [RepositoryCommitFile] = [
        RepositoryCommitFile(change: FileChange(path: "Sources/App.swift", kind: .modified), fingerprint: "one"),
        RepositoryCommitFile(change: FileChange(path: "README.md", kind: .modified), fingerprint: "two")
    ], blockingReason: String? = nil) {
        self.id = id
        self.files = files
        self.blockingReason = blockingReason
    }
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
        let preparedFiles = files.map { file in
            guard id == .svn, file.change.path == "README.md" else { return file }
            return RepositoryCommitFile(change: file.change, fingerprint: file.fingerprint, restriction: "需要先解决冲突", isDirectory: file.isDirectory)
        }
        return RepositoryCommitPreparation(binding: binding, baseRevision: id == .git ? "git-base" : "svn-base", files: preparedFiles, blockingReason: blockingReason)
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

/// 模拟声明了提交能力、但未实现提交适配接口的扩展来源。
private struct CommitReadOnlyFixtureProvider: VersionControlProvider {
    let id = ProviderID.svn
    let displayName = "Subversion"
    func detect(at directory: URL) async throws -> RepositoryBinding? { CommitFixtureProvider(id: id).binding }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
}
