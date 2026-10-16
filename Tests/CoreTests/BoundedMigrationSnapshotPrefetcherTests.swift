import Foundation
import Testing
@testable import RepositoryApplication
import VersionControlCore

@Suite("迁移快照有界并行预取")
struct BoundedMigrationSnapshotPrefetcherTests {
    @Test("最多三个独立会话并行，单个会话不会重入")
    func startsIndependentSessionsInParallelWithoutReenteringASession() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = PrefetchLedger()
        let revisions = makeRevisions(6)
        let prefetcher = BoundedMigrationSnapshotPrefetcherFixture.make(
            revisions: revisions, root: root, ledger: ledger,
            delays: ["r1": 180_000_000, "r2": 30_000_000, "r3": 60_000_000,
                     "r4": 20_000_000, "r5": 20_000_000, "r6": 20_000_000]
        )

        try await prefetcher.start()
        #expect(await ledger.waitUntil(activeAtLeast: 3))
        let initial = await prefetcher.diagnostics()
        #expect(initial.sessionCount == 3)
        #expect(initial.pendingCount == 3)
        #expect(initial.nextUnscheduledIndex == 3)

        for revision in revisions {
            let directory = try await prefetcher.consume(revision)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(revision.id).txt").path))
            await ledger.recordConsumed(revision.id)
        }
        await prefetcher.finish()

        #expect(await ledger.maximumActive >= 3)
        #expect(await ledger.maximumActivePerSession <= 1)
        #expect(Set(await ledger.started) == Set(revisions.map(\.id)))
    }

    @Test("乱序完成仍只能按迁移计划消费，未消费快照保持上界")
    func completionOrderDoesNotChangeConsumptionOrderOrBoundBufferedSnapshots() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = PrefetchLedger()
        let revisions = makeRevisions(5)
        let prefetcher = BoundedMigrationSnapshotPrefetcher(
            revisions: revisions, workspace: root, maxConcurrentSessions: 3,
            progress: MigrationPrefetchProgressMux { _ in },
            sessionFactory: { workspace in
                let sessionID = await ledger.allocateSession()
                return ControlledSnapshotSession(id: sessionID, ledger: ledger,
                                                 delays: ["r1": 250_000_000, "r2": 20_000_000, "r3": 40_000_000])
            }
        )

        try await prefetcher.start()
        #expect(await ledger.waitUntil(finished: ["r2", "r3"]))
        let beforeFirst = await prefetcher.diagnostics()
        #expect(beforeFirst.pendingCount == 3)
        #expect(beforeFirst.nextUnscheduledIndex == 3)
        await #expect(throws: VersionControlError.self) { _ = try await prefetcher.consume(revisions[1]) }

        let first = try await prefetcher.consume(revisions[0])
        #expect(FileManager.default.fileExists(atPath: first.path))
        await ledger.recordConsumed(revisions[0].id)
        let afterFirst = await prefetcher.diagnostics()
        #expect(afterFirst.pendingCount <= 3)
        #expect(afterFirst.nextUnscheduledIndex == 4)

        _ = try await prefetcher.consume(revisions[1]); await ledger.recordConsumed(revisions[1].id)
        _ = try await prefetcher.consume(revisions[2]); await ledger.recordConsumed(revisions[2].id)
        _ = try await prefetcher.consume(revisions[3]); await ledger.recordConsumed(revisions[3].id)
        _ = try await prefetcher.consume(revisions[4]); await ledger.recordConsumed(revisions[4].id)
        #expect(await ledger.consumedByCaller == revisions.map(\.id))
        await prefetcher.finish()
    }

    @Test("取消会等待所有活动会话结束并仅清理尚未消费的快照")
    func cancellationDrainsEveryActiveSessionBeforeCleaningUnconsumedSnapshots() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = PrefetchLedger()
        let revisions = makeRevisions(4)
        let prefetcher = BoundedMigrationSnapshotPrefetcher(
            revisions: revisions, workspace: root, maxConcurrentSessions: 3,
            progress: MigrationPrefetchProgressMux { _ in },
            sessionFactory: { _ in
                let sessionID = await ledger.allocateSession()
                return ControlledSnapshotSession(id: sessionID, ledger: ledger,
                                                 delays: ["r1": 10_000_000, "r2": 1_000_000_000, "r3": 1_000_000_000])
            }
        )
        try await prefetcher.start()
        #expect(await ledger.waitUntil(finished: ["r1"]))
        let consumed = try await prefetcher.consume(revisions[0])

        await prefetcher.cancelAndDrain()
        #expect(await ledger.activeCount == 0)
        #expect(await ledger.cancelled.contains("r2"))
        #expect(await ledger.cancelled.contains("r3"))
        #expect(FileManager.default.fileExists(atPath: consumed.path))
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(leftovers.map { $0.resolvingSymlinksInPath().standardizedFileURL.path } ==
                [consumed.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    @Test("未来修订失败不会污染当前已完成快照，调用方持有的目录不会被 finish 删除")
    func futureFailureDoesNotInvalidateAlreadyConsumedSnapshot() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = PrefetchLedger()
        let revisions = makeRevisions(4)
        let prefetcher = BoundedMigrationSnapshotPrefetcher(
            revisions: revisions, workspace: root, maxConcurrentSessions: 3,
            progress: MigrationPrefetchProgressMux { _ in },
            sessionFactory: { _ in
                let sessionID = await ledger.allocateSession()
                return ControlledSnapshotSession(id: sessionID, ledger: ledger,
                                                 delays: ["r1": 10_000_000, "r2": 10_000_000, "r3": 10_000_000, "r4": 10_000_000],
                                                 failing: ["r4"])
            }
        )

        try await prefetcher.start()
        let first = try await prefetcher.consume(revisions[0])
        #expect(FileManager.default.fileExists(atPath: first.path))
        _ = try await prefetcher.consume(revisions[1])
        _ = try await prefetcher.consume(revisions[2])
        #expect(await ledger.waitUntil(finished: ["r4"]))
        await #expect(throws: Error.self) { _ = try await prefetcher.consume(revisions[3]) }

        await prefetcher.finish()
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("r1.txt").path))
    }

    private func makeRevisions(_ count: Int) -> [MigrationRevision] {
        (1 ... count).map { number in
            MigrationRevision(id: "r\(number)", author: "fixture", date: .distantPast, message: "r\(number)")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-bounded-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum BoundedMigrationSnapshotPrefetcherFixture {
    static func make(revisions: [MigrationRevision], root: URL, ledger: PrefetchLedger,
                     delays: [String: UInt64]) -> BoundedMigrationSnapshotPrefetcher {
        BoundedMigrationSnapshotPrefetcher(
            revisions: revisions, workspace: root, maxConcurrentSessions: 3,
            progress: MigrationPrefetchProgressMux { _ in },
            sessionFactory: { _ in
                let sessionID = await ledger.allocateSession()
                return ControlledSnapshotSession(id: sessionID, ledger: ledger, delays: delays)
            }
        )
    }
}

private struct ControlledSnapshotSession: RepositoryMigrationSnapshotSession {
    let id: Int
    let ledger: PrefetchLedger
    let delays: [String: UInt64]
    let failing: Set<String>

    init(id: Int, ledger: PrefetchLedger, delays: [String: UInt64], failing: Set<String> = []) {
        self.id = id; self.ledger = ledger; self.delays = delays; self.failing = failing
    }

    func exportSnapshot(revision: MigrationRevision, to directory: URL,
                        progress: @escaping RepositoryOperationProgressHandler) async throws {
        await ledger.recordStart(revision.id, session: id)
        do {
            try await Task.sleep(nanoseconds: delays[revision.id] ?? 10_000_000)
            try Task.checkCancellation()
            if failing.contains(revision.id) { throw FixtureError.expectedFailure(revision.id) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(revision.id.utf8).write(to: directory.appendingPathComponent("\(revision.id).txt"))
            await ledger.recordFinish(revision.id, session: id, cancelled: false)
        } catch is CancellationError {
            await ledger.recordFinish(revision.id, session: id, cancelled: true)
            throw CancellationError()
        } catch {
            await ledger.recordFinish(revision.id, session: id, cancelled: Task.isCancelled)
            throw error
        }
    }

    private enum FixtureError: Error { case expectedFailure(String) }
}

private actor PrefetchLedger {
    private var nextSessionID = 0
    private var active = 0
    private var activePerSession: [Int: Int] = [:]
    private(set) var maximumActive = 0
    private(set) var maximumActivePerSession = 0
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var cancelled: Set<String> = []
    private(set) var consumedByCaller: [String] = []

    func allocateSession() -> Int { defer { nextSessionID += 1 }; return nextSessionID }
    func recordStart(_ revision: String, session: Int) {
        started.append(revision); active += 1
        activePerSession[session, default: 0] += 1
        maximumActive = max(maximumActive, active)
        maximumActivePerSession = max(maximumActivePerSession, activePerSession[session, default: 0])
    }
    func recordFinish(_ revision: String, session: Int, cancelled wasCancelled: Bool) {
        finished.append(revision); active -= 1; activePerSession[session, default: 0] -= 1
        if wasCancelled { cancelled.insert(revision) }
    }
    func recordConsumed(_ revision: String) { consumedByCaller.append(revision) }
    var activeCount: Int { active }
    func waitUntil(activeAtLeast expected: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if active >= expected { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return active >= expected
    }
    func waitUntil(finished expected: [String]) async -> Bool {
        let expected = Set(expected)
        for _ in 0 ..< 150 {
            if expected.isSubset(of: Set(finished)) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return expected.isSubset(of: Set(finished))
    }
}
