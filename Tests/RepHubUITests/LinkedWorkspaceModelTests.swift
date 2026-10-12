import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class LinkedWorkspaceModelTests: XCTestCase {
    func testAttachRecognizedDirectoryKeepsSelectionAndDeduplicates() async throws {
        let primary = try directory()
        let linked = try directory()
        let state = LinkedWorkspaceState()
        let model = WorkspaceModel(service: RepositoryService(providers: [LinkedWorkspaceProvider(state: state)]),
                                   workspaceLinks: WorkspaceLinkStore())

        model.open(primary)
        try await waitUntil { !model.isLoading && model.workspace?.directory == primary.standardizedFileURL }
        let originalBindingID = try XCTUnwrap(model.selectedBindingID)
        let originalPath = model.selectedPath

        model.attachDirectory(linked)
        try await waitUntil { !model.isLoading && model.workspace?.linkedDirectories == [linked.standardizedFileURL] }
        XCTAssertEqual(model.selectedBindingID, originalBindingID)
        XCTAssertEqual(model.selectedPath, originalPath)
        XCTAssertEqual(model.workspace?.bindings.count, 2)
        XCTAssertEqual(model.workspaceLinks.directories(for: primary), [linked.standardizedFileURL])

        let detectionsBeforeRepeat = await state.detectionCount()
        model.attachDirectory(linked)
        try await waitForDetection(after: detectionsBeforeRepeat, state: state)
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.workspace?.linkedDirectories, [linked.standardizedFileURL])
        XCTAssertEqual(model.workspaceLinks.directories(for: primary), [linked.standardizedFileURL])
    }

    func testAttachUnmanagedOrFailedDirectoryLeavesCurrentWorkspaceUntouched() async throws {
        let primary = try directory()
        let unmanaged = try directory()
        let failing = try directory()
        let state = LinkedWorkspaceState(unmanaged: [unmanaged.path], failures: [failing.path])
        let model = WorkspaceModel(service: RepositoryService(providers: [LinkedWorkspaceProvider(state: state)]),
                                   workspaceLinks: WorkspaceLinkStore())

        model.open(primary)
        try await waitUntil { !model.isLoading && model.workspace?.directory == primary.standardizedFileURL }
        let opened = try XCTUnwrap(model.workspace)
        let selectedBindingID = model.selectedBindingID
        let selectedPath = model.selectedPath

        let detectionsBeforeUnmanaged = await state.detectionCount()
        model.attachDirectory(unmanaged)
        try await waitForDetection(after: detectionsBeforeUnmanaged, state: state)
        try await waitUntil { !model.isLoading && model.errorMessage != nil }
        XCTAssertEqual(model.workspace?.id, opened.id)
        XCTAssertEqual(model.workspace?.linkedDirectories, [])
        XCTAssertEqual(model.selectedBindingID, selectedBindingID)
        XCTAssertEqual(model.selectedPath, selectedPath)

        let detectionsBeforeFailure = await state.detectionCount()
        model.attachDirectory(failing)
        try await waitForDetection(after: detectionsBeforeFailure, state: state)
        try await waitUntil { !model.isLoading && model.errorMessage != nil }
        XCTAssertEqual(model.workspace?.id, opened.id)
        XCTAssertEqual(model.workspace?.linkedDirectories, [])
        XCTAssertEqual(model.selectedBindingID, selectedBindingID)
        XCTAssertEqual(model.selectedPath, selectedPath)
    }

    func testRemovingSelectedLinkedBindingFallsBackToPrimary() async throws {
        let primary = try directory()
        let linked = try directory()
        let model = WorkspaceModel(service: RepositoryService(providers: [LinkedWorkspaceProvider(state: LinkedWorkspaceState())]),
                                   workspaceLinks: WorkspaceLinkStore())
        model.open(primary)
        try await waitUntil { !model.isLoading && model.workspace?.bindings.count == 1 }
        model.attachDirectory(linked)
        try await waitUntil { !model.isLoading && model.workspace?.bindings.count == 2 }
        let linkedBinding = try XCTUnwrap(model.workspace?.bindings.first { $0.root == linked.standardizedFileURL })

        model.selectBinding(linkedBinding)
        try await waitUntil { !model.isLoading && model.selectedBindingID == linkedBinding.id }
        model.removeLinkedDirectory(linked)
        try await waitUntil {
            !model.isLoading && model.workspace?.linkedDirectories.isEmpty == true
                && model.selectedBindingID == model.workspace?.bindings.first?.id
        }

        XCTAssertEqual(model.selectedBinding?.root, primary.standardizedFileURL)
        XCTAssertEqual(model.workspaceLinks.directories(for: primary), [])
        let remaining = try XCTUnwrap(model.workspace?.bindings.first)
        XCTAssertEqual(Set(model.snapshots.keys), Set([remaining.id]))
    }

    func testCloseKeepsRecentAndLinkedDirectoryPersistence() async throws {
        let primary = try directory()
        let linked = try directory()
        let recent = RecentRepositoryStore()
        let links = WorkspaceLinkStore()
        let model = WorkspaceModel(service: RepositoryService(providers: [LinkedWorkspaceProvider(state: LinkedWorkspaceState())]),
                                   recentRepositories: recent, workspaceLinks: links)
        model.open(primary)
        try await waitUntil { !model.isLoading && model.workspace != nil }
        model.attachDirectory(linked)
        try await waitUntil { !model.isLoading && model.workspace?.linkedDirectories == [linked.standardizedFileURL] }
        let recentBefore = recent.entries

        model.closeWorkspace()

        XCTAssertNil(model.workspace)
        XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertNil(model.selectedBindingID)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.patch)
        XCTAssertEqual(recent.entries, recentBefore)
        XCTAssertEqual(links.directories(for: primary), [linked.standardizedFileURL])
    }

    func testMonitoredRefreshRedetectsBranchAndLoadsSnapshotsForEveryLinkedBinding() async throws {
        let primary = try directory()
        let linked = try directory()
        let state = LinkedWorkspaceState()
        let model = WorkspaceModel(service: RepositoryService(providers: [LinkedWorkspaceProvider(state: state)]),
                                   workspaceLinks: WorkspaceLinkStore())
        model.open(primary)
        try await waitUntil { !model.isLoading && model.workspace != nil }
        model.attachDirectory(linked)
        try await waitUntil { !model.isLoading && model.workspace?.bindings.count == 2 }

        await state.setBranch("feature/refreshed", at: linked)
        model.refreshMonitoredChanges()
        try await waitUntil {
            !model.isLoading
                && model.workspace?.bindings.first(where: { $0.root == linked.standardizedFileURL })?.currentBranch == "feature/refreshed"
                && model.snapshots.count == 2
        }

        let linkedBinding = try XCTUnwrap(model.workspace?.bindings.first { $0.root == linked.standardizedFileURL })
        XCTAssertEqual(model.snapshots[linkedBinding.id]?.branches.first?.name, "feature/refreshed")
        let primaryBinding = try XCTUnwrap(model.workspace?.bindings.first { $0.root == primary.standardizedFileURL })
        XCTAssertNotNil(model.snapshots[primaryBinding.id])
    }

    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-linked-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value.standardizedFileURL
    }

    private func waitUntil(
        timeout: UInt64 = 1_500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待工作区状态更新超时")
    }

    private func waitForDetection(after count: Int, state: LinkedWorkspaceState) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        while (await state.detectionCount()) <= count && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let detected = await state.detectionCount()
        XCTAssertGreaterThan(detected, count, "等待关联目录检测开始超时")
    }
}

private actor LinkedWorkspaceState {
    private var unmanaged: Set<String>
    private var failures: Set<String>
    private var branches: [String: String] = [:]
    private var detections = 0

    init(unmanaged: Set<String> = [], failures: Set<String> = []) {
        self.unmanaged = unmanaged
        self.failures = failures
    }

    func binding(at directory: URL) throws -> RepositoryBinding? {
        detections += 1
        let normalized = directory.standardizedFileURL
        if failures.contains(normalized.path) { throw VersionControlError.toolUnavailable("关联目录检测失败") }
        if unmanaged.contains(normalized.path) { return nil }
        let branch = branches[normalized.path] ?? "main"
        return RepositoryBinding(providerID: .git, providerName: "关联测试 Git", root: normalized,
                                 currentBranch: branch, remoteURL: "https://example.invalid/\(normalized.lastPathComponent).git",
                                 capabilities: [.status, .diff, .history, .branches, .commitGraph])
    }

    func branch(at directory: URL) -> String {
        branches[directory.standardizedFileURL.path] ?? "main"
    }

    func setBranch(_ branch: String, at directory: URL) {
        branches[directory.standardizedFileURL.path] = branch
    }

    func detectionCount() -> Int { detections }
}

private struct LinkedWorkspaceProvider: VersionControlProvider {
    let id: ProviderID = .git
    let displayName = "关联测试 Git"
    let state: LinkedWorkspaceState

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        try await state.binding(at: directory)
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [FileChange(path: "Sources/\(binding.root.lastPathComponent).swift", kind: .modified)]
    }

    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        [Revision(id: "\(binding.root.lastPathComponent)-r1", author: "zym", date: .distantPast,
                  message: "关联工作区快照")]
    }

    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] {
        let name = await state.branch(at: binding.root)
        return [BranchReference(name: name, revisionID: "\(binding.root.lastPathComponent)-r1", kind: .local, isCurrent: true)]
    }

    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }

    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        RepositoryPatch(text: "\(binding.root.lastPathComponent):\(path ?? "all")")
    }
}
