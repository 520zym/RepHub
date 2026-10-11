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
    public init(_ message: String, fractionCompleted: Double? = nil, detail: String? = nil,
                records: [RepositoryProgressRecord] = []) {
        self.message = message
        self.fractionCompleted = fractionCompleted.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.detail = detail
        self.records = records
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
