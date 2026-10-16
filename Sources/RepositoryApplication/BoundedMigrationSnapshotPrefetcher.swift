import Foundation
import VersionControlCore

/// 当前工作副本初迁专用的有界快照预取器。
///
/// 每个 lane 持有一份完全隔离的来源会话和 source-cache；同一 lane 按计划顺序
/// 导出 `lane, lane + laneCount, ...`，不同 lane 才允许并发。调用方仍必须按原计划
/// 顺序 `consume`，因此 Git 提交、对象核对和检查点写入不会越序。
struct BoundedMigrationSnapshotPrefetchDiagnostics: Sendable, Equatable {
    let sessionCount: Int
    let pendingCount: Int
    let nextUnscheduledIndex: Int
    let nextExpectedIndex: Int
}

actor BoundedMigrationSnapshotPrefetcher {
    typealias SessionFactory = @Sendable (URL) async throws -> any RepositoryMigrationSnapshotSession

    private struct Completed: Sendable {
        let directory: URL
        let session: any RepositoryMigrationSnapshotSession
    }

    private struct Pending: Sendable {
        let index: Int
        let revision: MigrationRevision
        let lane: Int
        let directory: URL
        let task: Task<Completed, Error>
    }

    private struct Lane: Sendable {
        let cache: URL
        var session: (any RepositoryMigrationSnapshotSession)?
    }

    private let revisions: [MigrationRevision]
    private let workspace: URL
    private let maxConcurrentSessions: Int
    private let progress: MigrationPrefetchProgressMux
    private let sessionFactory: SessionFactory
    private var lanes: [Lane] = []
    private var pending: [Int: Pending] = [:]
    private var nextUnscheduledIndex = 0
    private var nextExpectedIndex = 0
    private var started = false

    init(revisions: [MigrationRevision], workspace: URL, maxConcurrentSessions: Int = 3,
         progress: MigrationPrefetchProgressMux, sessionFactory: @escaping SessionFactory) {
        self.revisions = revisions
        self.workspace = workspace
        self.maxConcurrentSessions = max(1, maxConcurrentSessions)
        self.progress = progress
        self.sessionFactory = sessionFactory
    }

    /// 只启动容量范围内的首批任务；不会为整个历史创建无界任务或来源缓存。
    func start() throws {
        try Task.checkCancellation()
        guard !started else { return }
        started = true
        let count = min(maxConcurrentSessions, revisions.count)
        for _ in 0..<count {
            let cache = workspace.appendingPathComponent("source-cache-\(UUID().uuidString)", isDirectory: true)
            lanes.append(Lane(cache: cache, session: nil))
        }
        for lane in lanes.indices {
            try scheduleNext(on: lane)
        }
    }

    /// 以固定计划顺序取得下一份快照。返回目录的生命周期交给调用方，预取器只清理
    /// 尚未消费的目录和自己的 source-cache。
    func consume(_ revision: MigrationRevision) async throws -> URL {
        guard started else {
            throw VersionControlError.invalidData("迁移快照预取尚未启动。")
        }
        guard nextExpectedIndex < revisions.count, revisions[nextExpectedIndex] == revision else {
            throw VersionControlError.invalidData("迁移快照预取修订顺序不一致。")
        }
        guard let candidate = pending[nextExpectedIndex] else {
            throw VersionControlError.invalidData("迁移快照预取缺少当前修订。")
        }
        do {
            let completed = try await withTaskCancellationHandler(operation: {
                try await candidate.task.value
            }, onCancel: {
                candidate.task.cancel()
            })
            guard completed.directory == candidate.directory else {
                throw VersionControlError.invalidData("迁移快照预取返回了非预定目录。")
            }
            pending.removeValue(forKey: candidate.index)
            lanes[candidate.lane].session = completed.session
            nextExpectedIndex += 1
            // 当前 lane 的 SVN 会话已完成当前修订，才允许排入该 lane 的下一条，保证
            // switch/export 在单一来源树上严格递增；此时其他 lane 的快照仍可并行。
            try scheduleNext(on: candidate.lane)
            return completed.directory
        } catch {
            pending.removeValue(forKey: candidate.index)
            try? FileManager.default.removeItem(at: candidate.directory)
            throw error
        }
    }

    /// 取消所有未消费任务，并等待它们停止后再删除各自目录和来源缓存。
    func cancelAndDrain() async {
        let tasks = Array(pending.values)
        for item in tasks { item.task.cancel() }
        for item in tasks {
            _ = try? await item.task.value
            try? FileManager.default.removeItem(at: item.directory)
        }
        pending.removeAll()
        for lane in lanes {
            try? FileManager.default.removeItem(at: lane.cache)
        }
        lanes.removeAll()
    }

    func finish() async {
        await cancelAndDrain()
    }

    func diagnostics() -> BoundedMigrationSnapshotPrefetchDiagnostics {
        BoundedMigrationSnapshotPrefetchDiagnostics(sessionCount: lanes.count,
                                                    pendingCount: pending.count,
                                                    nextUnscheduledIndex: nextUnscheduledIndex,
                                                    nextExpectedIndex: nextExpectedIndex)
    }

    private func scheduleNext(on laneIndex: Int) throws {
        try Task.checkCancellation()
        guard nextUnscheduledIndex < revisions.count else { return }
        guard lanes.indices.contains(laneIndex) else {
            throw VersionControlError.invalidData("迁移快照预取 lane 不存在。")
        }
        let index = nextUnscheduledIndex
        // 首批为 0...N-1；此后只由刚消费的 lane 填补，保证 N 间隔轮转。
        guard index % lanes.count == laneIndex else {
            throw VersionControlError.invalidData("迁移快照预取 lane 调度顺序不一致。")
        }
        let revision = revisions[index]
        let directory = workspace.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let cache = lanes[laneIndex].cache
        let existingSession = lanes[laneIndex].session
        let factory = sessionFactory
        let progress = self.progress
        let task = Task<Completed, Error> {
            try Task.checkCancellation()
            let session: any RepositoryMigrationSnapshotSession
            if let existingSession {
                session = existingSession
            } else {
                session = try await factory(cache)
            }
            try Task.checkCancellation()
            try await session.exportSnapshot(revision: revision, to: directory) { update in
                await progress.background(revision: revision, update: update)
            }
            return Completed(directory: directory, session: session)
        }
        pending[index] = Pending(index: index, revision: revision, lane: laneIndex, directory: directory, task: task)
        nextUnscheduledIndex += 1
    }
}
