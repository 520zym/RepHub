import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testOpenAutomaticallySelectsReadableSourceFileAndLoadsWorkingDiff() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.selectedPath == "Sources/App.swift" && model.patch?.text == "working:Sources/App.swift" }

        XCTAssertEqual(model.selectedBinding?.providerID, .git)
        XCTAssertNil(model.selectedRevisionID)
        XCTAssertEqual(model.patch?.text, "working:Sources/App.swift")
        let diffs = await provider.log.diffRequests()
        XCTAssertTrue(diffs.contains { $0.path == "Sources/App.swift" && $0.revision == nil })
    }

    func testSelectingHistoryRevisionLoadsItsPreferredFileWithSameRevision() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot?.revisions.first != nil }
        let revision = try XCTUnwrap(model.snapshot?.revisions.first)

        model.selectRevision(revision)
        try await waitUntil { model.selectedRevisionID == revision.id && model.patch?.text == "revision:\(revision.id):Sources/Revision.swift" }

        XCTAssertEqual(model.selectedPath, "Sources/Revision.swift")
        XCTAssertEqual(model.revisionFiles.map(\.path), ["README.md", "Sources/Revision.swift"])
        let changedFiles = await provider.log.changedFileRequests()
        let diffs = await provider.log.diffRequests()
        XCTAssertTrue(changedFiles.contains(revision.id))
        XCTAssertTrue(diffs.contains { $0.path == "Sources/Revision.swift" && $0.revision == revision.id })
    }

    func testLateDiffResponseCannotOverwriteNewerSelection() async throws {
        let provider = WorkspaceFixtureProvider(delays: ["Sources/Old.swift": 180_000_000, "Sources/New.swift": 20_000_000])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.selectChange(FileChange(path: "Sources/Old.swift", kind: .modified))
        try await waitForDiffStart("Sources/Old.swift", log: provider.log)
        model.selectChange(FileChange(path: "Sources/New.swift", kind: .modified))

        try await waitUntil { model.selectedPath == "Sources/New.swift" && model.patch?.text == "working:Sources/New.swift" }
        try await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertEqual(model.selectedPath, "Sources/New.swift")
        XCTAssertEqual(model.patch?.text, "working:Sources/New.swift")
    }

    func testRefreshKeepsHistoryReferenceAndReloadsSelectedRevision() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        let reference = "feature/demo"

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot?.revisions.first != nil }
        model.selectHistoryReference(reference)
        try await waitUntil {
            model.historyReference == reference
                && model.selectedRevisionID == "a1b2c3d4"
                && model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift"
        }

        model.refresh()
        try await waitUntil {
            model.historyReference == reference
                && model.selectedRevisionID == "a1b2c3d4"
                && model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift"
        }

        let references = await provider.log.historyReferences()
        let revisions = await provider.log.changedFileRequests()
        XCTAssertGreaterThanOrEqual(references.filter { $0 == reference }.count, 2)
        XCTAssertGreaterThanOrEqual(revisions.filter { $0 == "a1b2c3d4" }.count, 2)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-ui-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(
        timeout: UInt64 = 1_500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待 WorkspaceModel 完成异步读取超时")
    }

    private func waitForDiffStart(_ path: String, log: WorkspaceInvocationLog) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await log.didStartDiff(path)) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await log.didStartDiff(path)
        XCTAssertTrue(started, "等待迟到响应开始超时")
    }
}

private struct WorkspaceFixtureProvider: VersionControlProvider {
    struct DiffRequest: Sendable {
        let path: String?
        let revision: String?
    }

    let id: ProviderID = .git
    let displayName = "Git 测试适配器"
    let log: WorkspaceInvocationLog
    let delays: [String: UInt64]

    init(delays: [String: UInt64] = [:], log: WorkspaceInvocationLog = WorkspaceInvocationLog()) {
        self.delays = delays
        self.log = log
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(
            providerID: .git,
            providerName: displayName,
            root: directory,
            currentBranch: "main",
            capabilities: [.status, .diff, .history, .branches, .commitGraph]
        )
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [
            FileChange(path: "scratch.swift", kind: .untracked),
            FileChange(path: "README.md", kind: .modified),
            FileChange(path: "Sources/App.swift", kind: .modified),
            FileChange(path: "Sources/Old.swift", kind: .modified),
            FileChange(path: "Sources/New.swift", kind: .modified),
        ]
    }

    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        await log.recordHistory(reference)
        return [Revision(id: "a1b2c3d4", author: "zym", date: .distantPast, message: "feat: 历史读取")]
    }

    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }

    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        await log.recordChangedFiles(revision)
        return [
            FileChange(path: "README.md", kind: .modified),
            FileChange(path: "Sources/Revision.swift", kind: .modified),
        ]
    }

    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        await log.recordDiffStart(path: path, revision: revision)
        if let path, let delay = delays[path] {
            // 不观察任务取消，模拟外部读取已发出后迟到返回。
            await uncancellableDelay(nanoseconds: delay)
        }
        await log.recordDiff(path: path, revision: revision)
        let label = revision.map { "revision:\($0)" } ?? "working"
        return RepositoryPatch(text: "\(label):\(path ?? "all")")
    }

    private func uncancellableDelay(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }
}

private actor WorkspaceInvocationLog {
    private var changedFiles: [String] = []
    private var diffs: [WorkspaceFixtureProvider.DiffRequest] = []
    private var startedDiffs: [WorkspaceFixtureProvider.DiffRequest] = []
    private var history: [String?] = []

    func recordChangedFiles(_ revision: String) { changedFiles.append(revision) }
    func recordHistory(_ reference: String?) { history.append(reference) }
    func recordDiffStart(path: String?, revision: String?) { startedDiffs.append(.init(path: path, revision: revision)) }
    func recordDiff(path: String?, revision: String?) { diffs.append(.init(path: path, revision: revision)) }
    func changedFileRequests() -> [String] { changedFiles }
    func historyReferences() -> [String?] { history }
    func didStartDiff(_ path: String) -> Bool { startedDiffs.contains { $0.path == path } }
    func diffRequests() -> [WorkspaceFixtureProvider.DiffRequest] { diffs }
}
