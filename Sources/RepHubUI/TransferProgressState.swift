import Foundation
import Observation
import VersionControlCore

/// 面向界面的传输进度缓存。适配器只提交结构化进度，绝不在此解析 Git/SVN 文本输出。
@MainActor
@Observable
public final class TransferProgressState {
    public private(set) var phase = ""
    public private(set) var detail: String?
    /// 仅表示当前阶段；切换阶段时会清空，避免把上一阶段的百分比误认为总进度。
    public private(set) var fractionCompleted: Double?
    /// `isEstimated` 为真时仅表示适配器观测到的本地处理量，界面必须明确标注估算口径。
    public private(set) var transferStatistics: RepositoryTransferStatistics?
    public private(set) var records: [RepositoryProgressRecord] = []
    /// 适配器发来的记录累计数。它包括目录和信息记录，不能作为“已下载文件数”。
    public private(set) var totalRecordCount = 0
    public private(set) var startedAt: Date?
    public private(set) var lastActivityAt: Date?
    public private(set) var isActive = false

    public static let retainedRecordLimit = 250

    public init() {}

    public func begin(_ phase: String) {
        self.phase = phase
        detail = nil
        fractionCompleted = nil
        transferStatistics = nil
        records = []
        totalRecordCount = 0
        let now = Date()
        startedAt = now
        lastActivityAt = now
        isActive = true
    }

    public func consume(_ progress: RepositoryOperationProgress) {
        let nextPhase = progress.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nextPhase.isEmpty, nextPhase != phase {
            phase = nextPhase
            fractionCompleted = nil
        }
        if let fraction = progress.fractionCompleted {
            fractionCompleted = fraction
        }
        if let transferStatistics = progress.transferStatistics {
            self.transferStatistics = transferStatistics
        }
        detail = progress.detail
        append(progress.records)
        lastActivityAt = Date()
    }

    public func finish(_ finalPhase: String? = nil) {
        if let finalPhase, !finalPhase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = finalPhase
        }
        fractionCompleted = nil
        transferStatistics = nil
        isActive = false
        lastActivityAt = Date()
    }

    public func clear() {
        phase = ""
        detail = nil
        fractionCompleted = nil
        transferStatistics = nil
        records = []
        totalRecordCount = 0
        startedAt = nil
        lastActivityAt = nil
        isActive = false
    }

    private func append(_ incoming: [RepositoryProgressRecord]) {
        guard !incoming.isEmpty else { return }
        totalRecordCount += incoming.count
        records.append(contentsOf: incoming)
        let overflow = records.count - Self.retainedRecordLimit
        if overflow > 0 { records.removeFirst(overflow) }
    }
}
