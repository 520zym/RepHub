import Foundation

public enum RepositoryIgnoreScope: String, CaseIterable, Sendable, Hashable {
    case currentDirectory
    case repository
    public var title: String { self == .currentDirectory ? "当前文件夹" : "整个仓库" }
}

public struct RepositoryIgnoreCandidate: Hashable, Sendable {
    public let path: String
    public let fingerprint: String
    public let defaultRule: String
    public let scopes: Set<RepositoryIgnoreScope>
    public init(path: String, fingerprint: String, defaultRule: String, scopes: Set<RepositoryIgnoreScope>) {
        self.path = path; self.fingerprint = fingerprint; self.defaultRule = defaultRule; self.scopes = scopes
    }
}

public struct RepositoryIgnorePreparation: Sendable {
    public let binding: RepositoryBinding
    public let candidates: [RepositoryIgnoreCandidate]
    public let notice: String
    public init(binding: RepositoryBinding, candidates: [RepositoryIgnoreCandidate], notice: String) {
        self.binding = binding; self.candidates = candidates; self.notice = notice
    }
}

public struct RepositoryIgnoreRequest: Sendable {
    public let bindingID: String
    public let candidate: RepositoryIgnoreCandidate
    public let rule: String
    public let scope: RepositoryIgnoreScope
    public let previewToken: String?
    public init(bindingID: String, candidate: RepositoryIgnoreCandidate, rule: String, scope: RepositoryIgnoreScope,
                previewToken: String? = nil) {
        self.bindingID = bindingID; self.candidate = candidate; self.rule = rule; self.scope = scope
        self.previewToken = previewToken
    }
}

public struct RepositoryIgnorePreview: Sendable {
    public let targetDescription: String
    public let before: String
    public let after: String
    public let stateToken: String
    public init(targetDescription: String, before: String, after: String, stateToken: String) {
        self.targetDescription = targetDescription; self.before = before; self.after = after
        self.stateToken = stateToken
    }
}

public struct RepositoryIgnoreResult: Sendable {
    public let summary: String
    public let details: String
    public init(summary: String, details: String = "") { self.summary = summary; self.details = details }
}

public protocol RepositoryIgnoreProvider: VersionControlProvider {
    func prepareIgnore(in binding: RepositoryBinding) async throws -> RepositoryIgnorePreparation
    func previewIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding) async throws -> RepositoryIgnorePreview
    func applyIgnore(_ request: RepositoryIgnoreRequest, in binding: RepositoryBinding,
                     progress: @escaping RepositoryOperationProgressHandler) async throws -> RepositoryIgnoreResult
}
