import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

/// 一个 App 进程可同时拥有多个工作区模型。这里刻意让它们共享服务和最近打开记录，
/// 以防未来把窗口状态错误地提升为 App 级单例。
@MainActor
final class MultiWindowWorkspaceTests: XCTestCase {
    func testWindowsKeepRepositoryHistorySelectionAndCommitDraftsIndependent() async throws {
        let firstDirectory = try makeDirectory(named: "first")
        let secondDirectory = try makeDirectory(named: "second")
        let defaults = try makeDefaults()
        let recent = RecentRepositoryStore(defaults: defaults)
        let provider = WindowFixtureProvider()
        let service = RepositoryService(providers: [provider])
        let first = WorkspaceModel(service: service, recentRepositories: recent)
        let second = WorkspaceModel(service: service, recentRepositories: recent)

        first.open(firstDirectory)
        second.open(secondDirectory)
        try await waitUntil {
            !first.isLoading && !second.isLoading
                && first.workspace?.directory == firstDirectory.standardizedFileURL
                && second.workspace?.directory == secondDirectory.standardizedFileURL
                && first.snapshot != nil && second.snapshot != nil
        }

        XCTAssertEqual(Set(recent.entries.map(\.path)), [
            firstDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
            secondDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
        ])
        XCTAssertNotEqual(first.selectedBindingID, second.selectedBindingID)
        XCTAssertNotEqual(first.selectedPath, second.selectedPath)

        first.setHistoryVisible(true)
        try await waitUntil { first.selectedRevisionID != nil && first.patch != nil }
        XCTAssertFalse(second.isHistoryVisible)
        XCTAssertNil(second.selectedRevisionID)

        let firstRevision = try XCTUnwrap(first.historyRevisions.last)
        first.selectRevision(firstRevision)
        try await waitUntil { first.selectedRevisionID == firstRevision.id }
        XCTAssertNil(second.selectedRevisionID)
        XCTAssertEqual(second.selectedPath, "Sources/\(secondDirectory.lastPathComponent).swift")

        first.prepareCommit(initialTargets: [], initialMessage: "窗口一草稿")
        second.prepareCommit(initialTargets: [], initialMessage: "窗口二草稿")
        try await waitUntil {
            first.repositoryCommit.phase == .ready && second.repositoryCommit.phase == .ready
        }
        let firstCommitBinding = try XCTUnwrap(first.repositoryCommit.selectedBindingID)
        let secondCommitBinding = try XCTUnwrap(second.repositoryCommit.selectedBindingID)
        first.repositoryCommit.setMessage("仅窗口一修改", for: firstCommitBinding)

        XCTAssertEqual(first.repositoryCommit.message(for: firstCommitBinding), "仅窗口一修改")
        XCTAssertEqual(second.repositoryCommit.message(for: secondCommitBinding), "窗口二草稿")

        first.closeWindow()
        XCTAssertNil(first.workspace)
        XCTAssertEqual(first.repositoryCommit.phase, .idle)
        XCTAssertEqual(second.workspace?.directory, secondDirectory.standardizedFileURL)
        XCTAssertEqual(second.repositoryCommit.message(for: secondCommitBinding), "窗口二草稿")
        XCTAssertEqual(recent.entries.count, 2, "关闭一个窗口不能清掉共享的最近打开记录")
    }

    func testClosingWindowInvalidatesLateOpenWithoutAffectingOtherWindow() async throws {
        let slowDirectory = try makeDirectory(named: "slow")
        let activeDirectory = try makeDirectory(named: "active")
        let state = WindowFixtureState(delayedDirectories: [slowDirectory.standardizedFileURL.path])
        let provider = WindowFixtureProvider(state: state)
        let service = RepositoryService(providers: [provider])
        let recent = RecentRepositoryStore(defaults: try makeDefaults())
        let closing = WorkspaceModel(service: service, recentRepositories: recent)
        let active = WorkspaceModel(service: service, recentRepositories: recent)

        closing.open(slowDirectory)
        try await waitUntil { await state.startedDetection(at: slowDirectory) }
        active.open(activeDirectory)
        try await waitUntil { !active.isLoading && active.workspace?.directory == activeDirectory.standardizedFileURL }

        closing.closeWindow()
        XCTAssertNil(closing.workspace)
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertNil(closing.workspace, "关闭窗口后的迟到读取不可重新打开该窗口")
        XCTAssertTrue(closing.snapshots.isEmpty)
        XCTAssertEqual(active.workspace?.directory, activeDirectory.standardizedFileURL)
        XCTAssertEqual(recent.entries.count, 1)
        XCTAssertEqual(recent.entries.first?.path, activeDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testBusyWindowRefusesCloseUntilItsOperationFinishes() async throws {
        let directory = try makeDirectory(named: "busy")
        let provider = WindowFixtureProvider(operationDelay: 350_000_000)
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.selectedBinding != nil }
        let binding = try XCTUnwrap(model.selectedBinding)

        model.performOperation(.update, on: binding)
        try await waitUntil { model.isOperating }
        model.closeWindow()
        XCTAssertEqual(model.workspace?.directory, directory.standardizedFileURL,
                       "写操作期间不能销毁对应窗口的工作区状态")

        model.cancelOperation()
        try await waitUntil { !model.isOperating }
        model.closeWindow()
        XCTAssertNil(model.workspace)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-multiwindow-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "rephub-multiwindow-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "MultiWindowWorkspaceTests", code: 1)
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func waitUntil(
        timeout: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !(await condition()) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = await condition()
        XCTAssertTrue(completed, "等待多窗口工作区状态更新超时")
    }
}

private actor WindowFixtureState {
    private let delayedDirectories: Set<String>
    private var startedDirectories: Set<String> = []

    init(delayedDirectories: Set<String> = []) {
        self.delayedDirectories = delayedDirectories
    }

    func detect(_ directory: URL) async {
        let path = directory.standardizedFileURL.path
        startedDirectories.insert(path)
        if delayedDirectories.contains(path) {
            // 模拟已发出的外部工具调用：即便窗口取消，结果仍会迟到返回。
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
                    continuation.resume()
                }
            }
        }
    }

    func startedDetection(at directory: URL) -> Bool {
        startedDirectories.contains(directory.standardizedFileURL.path)
    }
}

private struct WindowFixtureProvider: RepositoryOperationProvider, RepositoryCommitProvider {
    let id: ProviderID = .git
    let displayName = "多窗口 Git 测试适配器"
    let state: WindowFixtureState
    let operationDelay: UInt64

    init(state: WindowFixtureState = WindowFixtureState(), operationDelay: UInt64 = 0) {
        self.state = state
        self.operationDelay = operationDelay
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        await state.detect(directory)
        let root = directory.standardizedFileURL
        let name = root.lastPathComponent
        return RepositoryBinding(
            providerID: id,
            providerName: displayName,
            root: root,
            currentBranch: "branch-\(name)",
            remoteURL: "https://example.invalid/\(name).git",
            capabilities: [.status, .diff, .history, .branches, .commitGraph, .commit, .update]
        )
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [FileChange(path: "Sources/\(binding.root.lastPathComponent).swift", kind: .modified)]
    }

    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        let prefix = binding.root.lastPathComponent
        return [
            Revision(id: "\(prefix)-r2", author: "zym", date: .now, message: "\(prefix) newer"),
            Revision(id: "\(prefix)-r1", author: "zym", date: .distantPast, message: "\(prefix) older"),
        ]
    }

    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] {
        [BranchReference(name: binding.currentBranch, revisionID: "\(binding.root.lastPathComponent)-r2", kind: .local, isCurrent: true)]
    }

    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        [FileChange(path: "Sources/\(binding.root.lastPathComponent).swift", kind: .modified)]
    }

    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        RepositoryPatch(text: "\(binding.root.lastPathComponent):\(revision ?? "working"):\(path ?? "all")")
    }

    func perform(
        _ operation: RepositoryOperationKind,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        await progress(RepositoryOperationProgress("测试操作中…"))
        if operationDelay > 0 { try await Task.sleep(nanoseconds: operationDelay) }
        return RepositoryOperationResult(kind: operation, bindingID: binding.id, outcome: .succeeded, summary: "完成")
    }

    func prepareCommit(in binding: RepositoryBinding) async throws -> RepositoryCommitPreparation {
        let change = FileChange(path: "Sources/\(binding.root.lastPathComponent).swift", kind: .modified)
        return RepositoryCommitPreparation(
            binding: binding,
            baseRevision: "base-\(binding.root.lastPathComponent)",
            files: [RepositoryCommitFile(change: change, fingerprint: "window-fixture")]
        )
    }

    func commitDiff(in binding: RepositoryBinding, file: RepositoryCommitFile) async throws -> RepositoryPatch {
        RepositoryPatch(text: "commit:\(binding.root.lastPathComponent):\(file.id)")
    }

    func commit(
        _ request: RepositoryCommitRequest,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryCommitResult {
        RepositoryCommitResult(bindingID: binding.id, outcome: .succeeded, revisionID: "fixture", summary: "完成", committedFiles: request.files.map(\.change))
    }
}
