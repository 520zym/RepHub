import Foundation

public enum RepositoryOperationKind: String, CaseIterable, Sendable {
    case fetch, update

    public var title: String { self == .fetch ? "获取远端" : "更新工作区" }
    public var capability: RepositoryCapabilities { self == .fetch ? .fetch : .update }
}

public enum RepositoryOperationOutcome: Sendable {
    case succeeded, conflicts, failed, cancelled
}

/// 操作阶段用于不确定时长的进度展示，不伪造百分比。
public struct RepositoryOperationProgress: Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
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
