import Foundation
import VersionControlCore

/// 把来源会话保持为严格串行，同时只预取下一份快照。该类型不持有任何 Git 状态，
/// 因此 Git 对象写入仍由调用方按修订顺序执行。
actor OnePageMigrationSnapshotPrefetcher {
    private struct Pending {
        let revision: MigrationRevision
        let directory: URL
        let task: Task<Void, Error>
    }

    private let session: any RepositoryMigrationSnapshotSession
    private let workspace: URL
    private let progress: MigrationPrefetchProgressMux
    private var pending: Pending?

    init(session: any RepositoryMigrationSnapshotSession, workspace: URL,
         progress: MigrationPrefetchProgressMux) {
        self.session = session
        self.workspace = workspace
        self.progress = progress
    }

    /// 只允许保留一个下一修订；调用方在当前快照已取得后调用。
    func schedule(_ revision: MigrationRevision) throws {
        try Task.checkCancellation()
        guard pending == nil else { throw VersionControlError.invalidData("迁移快照预取队列已满。") }
        let directory = workspace.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let session = self.session
        let progress = self.progress
        let task = Task {
            try Task.checkCancellation()
            try await session.exportSnapshot(revision: revision, to: directory) { update in
                await progress.background(revision: revision, update: update)
            }
        }
        pending = Pending(revision: revision, directory: directory, task: task)
    }

    /// 只接受预定的下一修订，避免 SVN 会话被越序消费。
    func consume(_ revision: MigrationRevision) async throws -> URL? {
        guard let pending else { return nil }
        guard pending.revision == revision else {
            throw VersionControlError.invalidData("迁移快照预取修订顺序不一致。")
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await pending.task.value
            }, onCancel: {
                pending.task.cancel()
            })
            clearPending(ifMatches: pending)
            return pending.directory
        } catch {
            if clearPending(ifMatches: pending) {
                try? FileManager.default.removeItem(at: pending.directory)
            }
            throw error
        }
    }

    /// 取消后必须等待 source session 停止，调用方才可清理来源缓存。
    func cancelAndDrain() async {
        guard let pending else { return }
        pending.task.cancel()
        _ = try? await pending.task.value
        if clearPending(ifMatches: pending) {
            try? FileManager.default.removeItem(at: pending.directory)
        }
    }

    func finish() async {
        await cancelAndDrain()
    }

    @discardableResult
    private func clearPending(ifMatches candidate: Pending) -> Bool {
        guard let pending,
              pending.revision == candidate.revision,
              pending.directory == candidate.directory else { return false }
        self.pending = nil
        return true
    }
}

/// 后台预取不能抢占前台阶段、传输速度或完成修订数。它只把自身状态附加到最近一次
/// 前台进度的 detail，主消息和迁移进度仍完全来自当前 Git/核对步骤。
actor MigrationPrefetchProgressMux {
    private let output: RepositoryOperationProgressHandler
    private var foregroundUpdate: RepositoryOperationProgress?

    init(output: @escaping RepositoryOperationProgressHandler) {
        self.output = output
    }

    func foreground(_ update: RepositoryOperationProgress) async {
        foregroundUpdate = update
        await output(update)
    }

    func background(revision: MigrationRevision, update: RepositoryOperationProgress) async {
        guard let foregroundUpdate else { return }
        let text = "同时后台预取 \(revision.id)：\(update.detail ?? update.message)"
        let detail = [foregroundUpdate.detail, text].compactMap { $0 }.joined(separator: " · ")
        await output(RepositoryOperationProgress(
            foregroundUpdate.message,
            fractionCompleted: foregroundUpdate.fractionCompleted,
            detail: detail,
            // 后台文件记录不进入前台的传输清单，避免重复附加上一轮前台记录，
            // 也不让“后台预取”被误认为当前写入完成。
            records: [],
            transferStatistics: foregroundUpdate.transferStatistics,
            migrationProgress: foregroundUpdate.migrationProgress
        ))
    }
}
