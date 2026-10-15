import Foundation

public enum RepositoryOperationKind: String, CaseIterable, Sendable {
    case fetch, update

    public var title: String { self == .fetch ? "获取远端" : "更新工作区" }
    public var capability: RepositoryCapabilities { self == .fetch ? .fetch : .update }
}

public enum RepositoryOperationOutcome: Sendable {
    case succeeded, conflicts, failed, cancelled
}

/// 百分比仅代表工具当前阶段；没有总量的阶段使用不定进度。
public struct RepositoryOperationProgress: Sendable {
    public let message: String
    public let fractionCompleted: Double?
    public let detail: String?
    public let records: [RepositoryProgressRecord]
    /// 可量化的传输信息。`isEstimated` 为真时，它只表示适配器已观察到的本地写入或处理量，
    /// 绝不能当作网络层下载字节。
    public let transferStatistics: RepositoryTransferStatistics?
    public init(_ message: String, fractionCompleted: Double? = nil, detail: String? = nil,
                records: [RepositoryProgressRecord] = [],
                transferStatistics: RepositoryTransferStatistics? = nil) {
        self.message = message
        self.fractionCompleted = fractionCompleted.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.detail = detail
        self.records = records
        self.transferStatistics = transferStatistics
    }
}

/// 进度展示使用的传输统计。SVN CLI 不报告可信的网络字节时，适配器可报告本地写入估算，
/// 并必须将 `isEstimated` 设为真。
public struct RepositoryTransferStatistics: Sendable, Equatable {
    public let processedBytes: Int64
    public let elapsed: TimeInterval
    public let isEstimated: Bool

    public init(processedBytes: Int64, elapsed: TimeInterval, isEstimated: Bool) {
        self.processedBytes = max(0, processedBytes)
        self.elapsed = max(0, elapsed.isFinite ? elapsed : 0)
        self.isEstimated = isEstimated
    }

    public var bytesPerSecond: Double? {
        guard elapsed > 0 else { return nil }
        return Double(processedBytes) / elapsed
    }

    /// 仅供需使用整数格式化器的界面消费。异常浮点值不转为整数；有限但超过
    /// `Int64` 表示范围的速度饱和显示，避免 `Double -> Int64` 转换溢出。
    public var roundedBytesPerSecond: Int64? {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return nil }
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value.rounded())
    }
}

/// 来自适配器的可读记录，UI 无需理解 Git/SVN 输出。文件路径相对于获取目标。
public struct RepositoryProgressRecord: Identifiable, Sendable {
    public enum Kind: Sendable { case file, information }
    public let id: UUID
    public let kind: Kind
    public let message: String
    public let path: String?
    public init(kind: Kind, message: String, path: String? = nil) {
        self.id = UUID(); self.kind = kind; self.message = message; self.path = path
    }
}

public typealias RepositoryOperationProgressHandler = @Sendable (RepositoryOperationProgress) async -> Void

public struct RepositoryOperationResult: Sendable {
    public let kind: RepositoryOperationKind
    public let bindingID: String
    public let outcome: RepositoryOperationOutcome
    public let summary: String
    public let details: String
    public let changedFiles: [FileChange]

    public init(kind: RepositoryOperationKind, bindingID: String, outcome: RepositoryOperationOutcome,
                summary: String, details: String = "", changedFiles: [FileChange] = []) {
        self.kind = kind; self.bindingID = bindingID; self.outcome = outcome
        self.summary = summary; self.details = details; self.changedFiles = changedFiles
    }
}

/// 写操作独立于读取契约；仅具备相应能力的适配器实现，单次只操作一个绑定。
public protocol RepositoryOperationProvider: VersionControlProvider {
    func perform(_ operation: RepositoryOperationKind, in binding: RepositoryBinding,
                 progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryOperationResult
}
