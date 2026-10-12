import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class WorkspaceMonitorTests: XCTestCase {
    func testFirstReadEstablishesBaselineThenChangedTokenMarksOnlyThatBindingPending() async throws {
        let state = MonitorState(tokens: ["git": "one"])
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0

        monitor.start(workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []), shouldPoll: { true })
        try await waitUntil { !monitor.isChecking && monitor.lastCheckedAt != nil }
        XCTAssertTrue(monitor.pendingBindingIDs.isEmpty, "首轮只能建立基线")

        await state.setToken("two", for: "git")
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.pendingBindingIDs == [binding.id] }

        monitor.acknowledge()
        XCTAssertTrue(monitor.pendingBindingIDs.isEmpty)
    }

    func testErrorsAreKeptPerBindingAndDoNotInventChanges() async throws {
        let state = MonitorState(tokens: ["git": "one", "svn": "one"])
        let git = MonitorProvider(id: .git, state: state)
        let svn = MonitorProvider(id: .svn, state: state)
        let gitBinding = makeBinding(id: "git", providerID: .git)
        let svnBinding = makeBinding(id: "svn", providerID: .svn)
        let bindings = [gitBinding, svnBinding]
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [git, svn]))
        monitor.intervalSeconds = 0
        monitor.start(workspace: Workspace(directory: temporaryDirectory(), bindings: bindings, issues: []), shouldPoll: { true })
        try await waitUntil { !monitor.isChecking && monitor.lastCheckedAt != nil }

        await state.setFailure("svn", message: "SVN 本地元数据不可读")
        await state.setToken("two", for: "git")
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.errorsByBindingID[svnBinding.id] != nil }

        let expectedError = "无法解析版本控制数据：SVN 本地元数据不可读"
        XCTAssertEqual(monitor.pendingBindingIDs, [gitBinding.id])
        XCTAssertEqual(monitor.errorsByBindingID[svnBinding.id], expectedError)
        XCTAssertTrue(monitor.errorMessage?.contains("\(svnBinding.id)：\(expectedError)") == true)
        XCTAssertNil(monitor.errorsByBindingID[gitBinding.id])
    }

    func testLockedOrInactivePollingSkipsWithoutReading() async throws {
        let state = MonitorState(tokens: ["git": "one"])
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0

        monitor.start(workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []), shouldPoll: { false })
        for _ in 0..<8 { await Task.yield() }
        monitor.checkNow()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.lastCheckedAt)
        let calls = await state.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testManualCheckCanRunWhileAutomaticPollingIsInactive() async throws {
        let state = MonitorState(tokens: ["git": "one"])
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0

        // 模拟应用在后台：自动轮询不允许，但用户明确点“立即检查”仍可建立基线。
        monitor.start(
            workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []),
            shouldPoll: { false },
            canCheckManually: { true }
        )
        try await waitUntil { !monitor.isChecking && monitor.lastCheckedAt != nil }
        let baselineCalls = await state.callCount()
        XCTAssertEqual(baselineCalls, 1)

        // 定时器走同一个入口，后台时不得绕过自动轮询保护。
        monitor.checkAutomatically()
        for _ in 0..<8 { await Task.yield() }
        let callsAfterAutomaticAttempt = await state.callCount()
        XCTAssertEqual(callsAfterAutomaticAttempt, 1)

        await state.setToken("two", for: "git")
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.pendingBindingIDs == [binding.id] }
    }

    func testBusyManualCheckWaitsForFirstBaselineInsteadOfDiscardingIt() async throws {
        let state = MonitorState(tokens: ["git": "one"])
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0
        let permission = MonitorPermission(isBusy: true)

        monitor.start(
            workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []),
            shouldPoll: { false },
            canCheckManually: { !permission.isBusy }
        )
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(monitor.lastCheckedAt)
        let callsWhileBusy = await state.callCount()
        XCTAssertEqual(callsWhileBusy, 0)

        // 忙碌期间的 token 不会被误当成已读；解除后第一次读取才成为基线。
        await state.setToken("two", for: "git")
        permission.isBusy = false
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.lastCheckedAt != nil }
        XCTAssertTrue(monitor.pendingBindingIDs.isEmpty)

        await state.setToken("three", for: "git")
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.pendingBindingIDs == [binding.id] }
    }

    func testStopDiscardsLateCheckResult() async throws {
        let state = MonitorState(tokens: ["git": "changed"], delayNanoseconds: 180_000_000)
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0

        monitor.start(workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []), shouldPoll: { true })
        try await waitForCalls(1, state: state)
        monitor.stop()
        try await Task.sleep(nanoseconds: 240_000_000)

        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.lastCheckedAt)
        XCTAssertTrue(monitor.pendingBindingIDs.isEmpty)
        XCTAssertNil(monitor.errorMessage)
    }

    func testProviderCancellationClearsCheckingStateAndAllowsRetry() async throws {
        let state = MonitorState(tokens: ["git": "one"], cancelledBindingIDs: ["git"])
        let provider = MonitorProvider(id: .git, state: state)
        let binding = makeBinding(id: "git", providerID: .git)
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: [provider]))
        monitor.intervalSeconds = 0

        monitor.start(workspace: Workspace(directory: temporaryDirectory(), bindings: [binding], issues: []), shouldPoll: { true })
        try await waitUntil { !monitor.isChecking }
        XCTAssertNil(monitor.lastCheckedAt)
        let firstCallCount = await state.callCount()
        XCTAssertEqual(firstCallCount, 1)

        await state.setCancelled(false, for: "git")
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking && monitor.lastCheckedAt != nil }

        let secondCallCount = await state.callCount()
        XCTAssertEqual(secondCallCount, 2)
        XCTAssertTrue(monitor.errorsByBindingID.isEmpty)
    }

    func testIntervalDefaultsToThirtyAndOnlyAllowsKnownValues() {
        let monitor = WorkspaceMonitor(service: RepositoryService(providers: []))
        XCTAssertEqual(monitor.intervalSeconds, 30)
        monitor.intervalSeconds = 15
        XCTAssertEqual(monitor.intervalSeconds, 15)
        monitor.intervalSeconds = 14
        XCTAssertEqual(monitor.intervalSeconds, 30)
        monitor.intervalSeconds = 0
        XCTAssertEqual(monitor.intervalSeconds, 0)
    }

    private func makeBinding(id: String, providerID: ProviderID) -> RepositoryBinding {
        RepositoryBinding(providerID: providerID, providerName: providerID == .svn ? "SVN" : "Git",
                          root: temporaryDirectory(), capabilities: [.status])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rephub-monitor-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitUntil(
        timeout: UInt64 = 1_500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待监控检查完成超时")
    }

    private func waitForCalls(_ expected: Int, state: MonitorState) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while (await state.callCount()) < expected && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let calls = await state.callCount()
        XCTAssertGreaterThanOrEqual(calls, expected, "等待本地状态读取开始超时")
    }
}

@MainActor
private final class MonitorPermission {
    var isBusy: Bool

    init(isBusy: Bool) {
        self.isBusy = isBusy
    }
}

private actor MonitorState {
    private var tokens: [String: String]
    private var failures: [String: String] = [:]
    private var cancelledBindingIDs: Set<String>
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(tokens: [String: String], delayNanoseconds: UInt64 = 0, cancelledBindingIDs: Set<String> = []) {
        self.tokens = tokens
        self.delayNanoseconds = delayNanoseconds
        self.cancelledBindingIDs = cancelledBindingIDs
    }

    func context(for binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        calls += 1
        if delayNanoseconds > 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delayNanoseconds))) {
                    continuation.resume()
                }
            }
        }
        let fixtureID = binding.providerID.rawValue
        if cancelledBindingIDs.contains(fixtureID) { throw CancellationError() }
        if let failure = failures[fixtureID] { throw VersionControlError.invalidData(failure) }
        return RepositoryManagementContext(binding: binding, stateToken: tokens[fixtureID] ?? "missing")
    }

    func setToken(_ token: String, for bindingID: String) { tokens[bindingID] = token }
    func setFailure(_ bindingID: String, message: String) { failures[bindingID] = message }
    func setCancelled(_ cancelled: Bool, for bindingID: String) {
        if cancelled { cancelledBindingIDs.insert(bindingID) }
        else { cancelledBindingIDs.remove(bindingID) }
    }
    func callCount() -> Int { calls }
}

private struct MonitorProvider: RepositoryManagementProvider {
    let id: ProviderID
    let state: MonitorState
    var displayName: String { id == .svn ? "SVN 测试" : "Git 测试" }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(
            providerID: id,
            providerName: id == .svn ? "SVN 测试" : "Git 测试",
            root: directory,
            capabilities: [.status]
        )
    }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func managementContext(in binding: RepositoryBinding) async throws -> RepositoryManagementContext {
        try await state.context(for: binding)
    }
    func performManagement(_ request: RepositoryManagementRequest, in binding: RepositoryBinding,
                           progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryManagementResult {
        RepositoryManagementResult(outcome: .succeeded, summary: "未使用")
    }
}
