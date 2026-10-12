import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class RepositorySetupManagementModelTests: XCTestCase {
    func testSetupKeepsExactlyOneSelectedProviderAndUnknownDoesNotOpenWorkspace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ModelFixtureProvider(setupOutcome: .unknown, detectsRepository: false)
        let model = RepositorySetupModel(service: RepositoryService(providers: [provider]))
        model.prepare(directory: directory)
        try await waitUntil { !model.isLoadingOptions && model.options.count == 1 }
        XCTAssertEqual(model.selectedProviderID, .git)
        model.initialBranch = "main"
        model.initialize()
        try await waitUntil { !model.isExecuting && model.result != nil }
        XCTAssertEqual(model.result?.outcome, .unknown)
        XCTAssertEqual(model.password, "")
    }

    func testManagementCancellationAndLateContextDoNotRestoreOldState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ModelFixtureProvider(contextDelay: 180_000_000)
        let service = RepositoryService(providers: [provider])
        let workspace = try await service.open(directory: directory)
        let binding = try XCTUnwrap(workspace.bindings.first)
        let model = RepositoryManagementModel(service: service)
        model.prepare(in: workspace, binding: binding)
        model.cancel()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(model.context)
        XCTAssertFalse(model.isLoading)
    }

    func testLateStagedAndComparisonResultsDoNotCrossBindings() async throws {
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: firstDirectory); try? FileManager.default.removeItem(at: secondDirectory) }
        let provider = ModelFixtureProvider(stagedDelay: 160_000_000, comparisonDelay: 160_000_000)
        let service = RepositoryService(providers: [provider])
        let firstWorkspace = try await service.open(directory: firstDirectory)
        let secondWorkspace = try await service.open(directory: secondDirectory)
        let firstBinding = try XCTUnwrap(firstWorkspace.bindings.first)
        let secondBinding = try XCTUnwrap(secondWorkspace.bindings.first)
        let model = RepositoryManagementModel(service: service)

        model.prepare(in: firstWorkspace, binding: firstBinding)
        try await waitUntil { model.context != nil && !model.isLoading }
        model.loadStagedDiff(path: "Sources/App.swift")
        model.prepare(in: secondWorkspace, binding: secondBinding)
        try await waitUntil { model.context?.binding.id == secondBinding.id && !model.isLoading }
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertNil(model.stagedPatch)
        XCTAssertNil(model.stagedPath)

        model.compare(from: "one", to: "two")
        model.prepare(in: firstWorkspace, binding: firstBinding)
        try await waitUntil { model.context?.binding.id == firstBinding.id && !model.isLoading }
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertNil(model.comparison)
        XCTAssertNil(model.comparisonPatch)
    }

    func testSetupSuccessRetainsBackupResultUntilUserDismisses() async throws {
        let directory = try temporaryDirectory()
        let backup = directory.deletingLastPathComponent().appendingPathComponent("backup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ModelFixtureProvider(setupOutcome: .succeeded, setupBackup: backup, detectsRepository: false)
        let model = RepositorySetupModel(service: RepositoryService(providers: [provider]))
        model.prepare(directory: directory)
        try await waitUntil { !model.isLoadingOptions && model.selectedProviderID == .git }
        model.initialize()
        try await waitUntil { !model.isExecuting && model.result != nil }
        XCTAssertEqual(model.result?.outcome, .succeeded)
        XCTAssertEqual(model.result?.backupDirectory, backup)
        XCTAssertFalse(model.isBusy)
    }

    func testCancelledSetupConsumesReturnedUnknownResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writeGate = SetupWriteGate()
        let provider = ModelFixtureProvider(setupOutcome: .unknown, setupGate: writeGate, detectsRepository: false)
        let model = RepositorySetupModel(service: RepositoryService(providers: [provider]))
        model.prepare(directory: directory)
        try await waitUntil { !model.isLoadingOptions && model.selectedProviderID == .git }

        model.initialize()
        await writeGate.waitUntilStarted()
        model.cancel()
        await writeGate.release()
        try await waitUntil { !model.isExecuting && model.result != nil }

        XCTAssertEqual(model.result?.outcome, .unknown)
        XCTAssertFalse(model.isCancelling)
    }

    func testManagementWriteKeepsResultAndRefreshesSelectedBinding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RepositoryService(providers: [ModelFixtureProvider()])
        let workspace = try await service.open(directory: directory)
        let binding = try XCTUnwrap(workspace.bindings.first)
        let model = RepositoryManagementModel(service: service)
        model.prepare(in: workspace, binding: binding)
        try await waitUntil { model.context != nil && !model.isLoading }
        var delivered = false
        model.execute(.stage(paths: ["Sources/App.swift"])) { _ in delivered = true }
        try await waitUntil { !model.isExecuting && model.result != nil }
        XCTAssertTrue(delivered)
        XCTAssertEqual(model.result?.result.outcome, .succeeded)
        XCTAssertEqual(model.selectedBinding?.id, binding.id)
        XCTAssertEqual(model.workspace?.directory, directory)
    }

    func testCancelledManagementConsumesReturnedRepositoryResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RepositoryService(providers: [ModelFixtureProvider(managementDelay: 120_000_000)])
        let workspace = try await service.open(directory: directory)
        let binding = try XCTUnwrap(workspace.bindings.first)
        let model = RepositoryManagementModel(service: service)
        model.prepare(in: workspace, binding: binding)
        try await waitUntil { model.context != nil && !model.isLoading }

        model.execute(.stage(paths: ["Sources/App.swift"])) { _ in }
        try await waitUntil { model.progressMessage == "测试管理中" }
        model.cancel()
        try await waitUntil { !model.isExecuting && model.result != nil }

        XCTAssertEqual(model.result?.result.outcome, .succeeded)
        XCTAssertFalse(model.isCancelling)
    }

    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-ManagementModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "等待异步状态超时")
    }
}

private struct ModelFixtureProvider: RepositorySetupProvider, RepositoryManagementProvider, RepositoryComparisonProvider {
    let id: ProviderID = .git
    let setupOutcome: RepositoryManagementOutcome
    let setupGate: SetupWriteGate?
    let contextDelay: UInt64
    let managementDelay: UInt64
    let stagedDelay: UInt64
    let comparisonDelay: UInt64
    let setupBackup: URL?
    let detectsRepository: Bool
    var displayName: String { "Git 测试" }
    var setupOption: RepositorySetupOption { .init(providerID: .git, title: "Git", requiresRemote: false) }

    init(setupOutcome: RepositoryManagementOutcome = .succeeded, setupGate: SetupWriteGate? = nil, contextDelay: UInt64 = 0,
         managementDelay: UInt64 = 0, stagedDelay: UInt64 = 0, comparisonDelay: UInt64 = 0,
         setupBackup: URL? = nil, detectsRepository: Bool = true) {
        self.setupOutcome = setupOutcome
        self.setupGate = setupGate
        self.contextDelay = contextDelay
        self.managementDelay = managementDelay
        self.stagedDelay = stagedDelay
        self.comparisonDelay = comparisonDelay
        self.setupBackup = setupBackup
        self.detectsRepository = detectsRepository
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        guard detectsRepository else { return nil }
        return RepositoryBinding(providerID: .git, providerName: displayName, root: directory, currentBranch: "main",
                                 capabilities: [.status, .diff, .history, .staging, .branchManagement, .push, .conflictResolution, .revisionComparison])
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { .init(text: "") }
    func initialize(_ request: RepositorySetupRequest, progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositorySetupResult {
        if let setupGate { await setupGate.enterWriteStage() }
        return .init(outcome: setupOutcome, directory: request.directory, summary: "测试初始化", backupDirectory: setupBackup)
    }
    func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        if contextDelay > 0 { await uncancellableDelay(contextDelay) }
        return .init(binding: binding, stateToken: "state")
    }
    func performManagement(_ request: RepositoryManagementRequest, in binding: RepositoryBinding, progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryManagementResult {
        await progress(.init("测试管理中"))
        if managementDelay > 0 { await uncancellableDelay(managementDelay) }
        return .init(outcome: .succeeded, summary: "测试管理")
    }
    func stagedDiff(in binding: RepositoryBinding, path: String) async throws -> RepositoryPatch {
        if stagedDelay > 0 { await uncancellableDelay(stagedDelay) }
        return .init(text: "staged:\(binding.root.lastPathComponent):\(path)")
    }
    func compare(in binding: RepositoryBinding, from: String, to: String) async throws -> RepositoryComparison {
        if comparisonDelay > 0 { await uncancellableDelay(comparisonDelay) }
        return .init(fromRevision: from, toRevision: to, files: [FileChange(path: "Sources/App.swift", kind: .modified)])
    }
    func comparisonDiff(in binding: RepositoryBinding, comparison: RepositoryComparison, path: String) async throws -> RepositoryPatch { .init(text: "comparison") }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] { [] }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch { .init(text: "") }
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus { .init(summary: "") }
    private func uncancellableDelay(_ delay: UInt64) async { await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { continuation.resume() } } }
}

private actor SetupWriteGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterWriteStage() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
