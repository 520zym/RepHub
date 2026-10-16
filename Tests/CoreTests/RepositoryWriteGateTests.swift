import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("跨窗口仓库写门禁")
struct RepositoryWriteGateTests {
    @Test("共享门禁会拒绝另一服务的写入，取消后可继续")
    func rejectsSecondServiceAndReleasesAfterCancellation() async throws {
        let firstRoot = try makeDirectory()
        let secondRoot = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let gate = RepositoryWriteGate()
        let firstProvider = GateOperationProvider(root: firstRoot, blocks: true)
        let secondProvider = GateOperationProvider(root: secondRoot)
        let first = RepositoryService(providers: [firstProvider], writeGate: gate)
        let second = RepositoryService(providers: [secondProvider], writeGate: gate)
        let firstWorkspace = try await first.open(directory: firstRoot)
        let secondWorkspace = try await second.open(directory: secondRoot)
        let firstBinding = try #require(firstWorkspace.bindings.first)
        let secondBinding = try #require(secondWorkspace.bindings.first)

        let active = Task {
            try await first.perform(.update, bindingID: firstBinding.id, in: firstWorkspace, progress: { _ in })
        }
        await firstProvider.waitUntilStarted()

        await #expect(throws: VersionControlError.self) {
            try await second.perform(.update, bindingID: secondBinding.id, in: secondWorkspace, progress: { _ in })
        }

        active.cancel()
        _ = try await active.value
        _ = try await second.perform(.update, bindingID: secondBinding.id, in: secondWorkspace, progress: { _ in })
        #expect(await secondProvider.operationCount == 1)
    }

    @Test("抛错和取消都会释放门禁")
    func releasesAfterErrorAndCancellation() async throws {
        let gate = RepositoryWriteGate()
        await #expect(throws: GateFailure.self) {
            try await gate.withExclusiveAccess { throw GateFailure.failed }
        }
        let afterError = try await gate.withExclusiveAccess { 7 }
        #expect(afterError == 7)

        let started = GateStartSignal()
        let active = Task {
            try await gate.withExclusiveAccess {
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                return ()
            }
        }
        await started.wait()
        active.cancel()
        await #expect(throws: CancellationError.self) { _ = try await active.value }
        let afterCancellation = try await gate.withExclusiveAccess { "available" }
        #expect(afterCancellation == "available")
    }

    @Test("已取消任务不会进入写闭包")
    func cancelledTaskDoesNotEnterOperation() async throws {
        let gate = RepositoryWriteGate()
        let called = GateStartSignal()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.withExclusiveAccess {
                await called.markStarted()
                return ()
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await called.hasStarted == false)
    }

    @Test("最终迁移目录落盘受共享门禁保护")
    func migrationPrepareDoesNotMoveFinalDirectoryWhileGateIsHeld() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("final", isDirectory: true)
        let gate = RepositoryWriteGate()
        let source = GateMigrationSource()
        let target = GateMigrationTarget()
        let service = RepositoryMigrationService(sources: [source], targets: [target], writeGate: gate)
        let revision = MigrationRevision(id: "r1", author: "source", date: .now, message: "initial")
        let plan = MigrationPlan(
            source: MigrationSourcePlan(providerID: source.id,
                                        location: RemoteRepositoryLocation(url: "https://example.test/source"),
                                        anchor: "r1", mode: .history, revisions: [revision]),
            targetProviderID: .git, remoteURL: "https://example.test/target.git", branch: "main",
            destination: destination, authors: ["source": MigrationAuthor(name: "Source", email: "source@example.test")]
        )

        let started = GateStartSignal()
        let holder = Task {
            try await gate.withExclusiveAccess {
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                return ()
            }
        }
        await started.wait()
        await #expect(throws: VersionControlError.self) {
            try await service.prepare(plan, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        holder.cancel()
        await #expect(throws: CancellationError.self) { _ = try await holder.value }
        _ = try await service.prepare(plan, progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-write-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum GateFailure: Error { case failed }

private actor GateStartSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }

    func wait() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var hasStarted: Bool { started }
}

private actor GateOperationProvider: RepositoryOperationProvider {
    nonisolated let id: ProviderID = .git
    nonisolated let displayName = "门禁测试"
    let root: URL
    let blocks: Bool
    private(set) var operationCount = 0
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL, blocks: Bool = false) {
        self.root = root
        self.blocks = blocks
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: root, currentBranch: "main",
                          capabilities: [.status, .history, .update])
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }

    func perform(_ operation: RepositoryOperationKind, in binding: RepositoryBinding,
                 progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryOperationResult {
        operationCount += 1
        started = true
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
        if blocks { try await Task.sleep(for: .seconds(30)) }
        return RepositoryOperationResult(kind: operation, bindingID: binding.id, outcome: .succeeded,
                                         summary: "完成", details: "")
    }
}

private struct GateMigrationSource: RepositoryMigrationSourceProvider {
    let id = ProviderID(rawValue: "gate-source")

    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        MigrationSourcePlan(providerID: id, location: location, anchor: "r1", mode: mode,
                            revisions: [MigrationRevision(id: "r1", author: "source", date: .now, message: "initial")])
    }

    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("value\n".utf8).write(to: directory.appendingPathComponent("sample.txt"))
    }
}

private actor GateMigrationTarget: RepositoryMigrationTargetProvider {
    nonisolated let id: ProviderID = .git

    func checkMigrationTarget(remoteURL: String, branch: String) async throws {}

    func initializeMigration(at directory: URL, branch: String) async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    func appendMigrationSnapshot(from snapshot: URL, revision: MigrationRevision, author: MigrationAuthor, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where item.lastPathComponent != ".git" {
            try FileManager.default.removeItem(at: item)
        }
        for item in try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
        }
        return String(repeating: "1", count: 40)
    }

    func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {}
    func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {}

    func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where item.lastPathComponent != ".git" {
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch { RepositoryPatch(text: "") }

    func publishMigration(at directory: URL, remoteURL: String, branch: String, expectedTip: String,
                          progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        MigrationPublicationResult(state: .notPublished, message: "fixture")
    }
}
