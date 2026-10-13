import Foundation

/// 仅描述搁置内容；界面不能据此推断 Git/SVN 的内部实现。
public enum RepositoryShelfMode: String, Sendable, Codable, CaseIterable {
    case saveOnly
    case saveAndClean

    public var title: String { self == .saveOnly ? "只保存快照" : "保存并清理工作区" }
}

public struct RepositoryShelfFile: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case modified, untracked }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let byteCount: Int
    public init(path: String, kind: Kind, byteCount: Int = 0) {
        self.path = path; self.kind = kind; self.byteCount = byteCount
    }
}

public struct RepositoryShelfPreview: Sendable {
    public let binding: RepositoryBinding
    public let files: [RepositoryShelfFile]
    /// 适配器生成的状态令牌，只能原样用于创建前复核。
    public let stateToken: String
    public let warnings: [String]
    public init(binding: RepositoryBinding, files: [RepositoryShelfFile], stateToken: String,
                warnings: [String] = []) {
        self.binding = binding; self.files = files; self.stateToken = stateToken; self.warnings = warnings
    }
}

public struct RepositoryShelfRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let providerID: ProviderID
    public let name: String
    public let createdAt: Date
    public let files: [RepositoryShelfFile]
    /// Git 为 stash 提交；SVN 为本地受保护快照目录。仅由适配器解释。
    public let reference: String
    public init(id: String, providerID: ProviderID, name: String, createdAt: Date = .now,
                files: [RepositoryShelfFile], reference: String) {
        self.id = id; self.providerID = providerID; self.name = name; self.createdAt = createdAt
        self.files = files; self.reference = reference
    }
}

public struct RepositoryShelfRestoreResult: Sendable {
    public let record: RepositoryShelfRecord
    public let summary: String
    public init(record: RepositoryShelfRecord, summary: String) {
        self.record = record; self.summary = summary
    }
}

/// 写操作必须由 RepositoryService 串行编排，并在调用前重新识别绑定。
public protocol RepositoryShelfProvider: VersionControlProvider {
    func shelfPreview(in binding: RepositoryBinding, includeUntracked: Bool) async throws -> RepositoryShelfPreview
    func shelves(in binding: RepositoryBinding) async throws -> [RepositoryShelfRecord]
    func createShelf(in binding: RepositoryBinding, name: String, includeUntracked: Bool,
                     mode: RepositoryShelfMode, expectedStateToken: String) async throws -> RepositoryShelfRecord
    /// 恢复后记录仍应存在；只有用户随后明确删除时才调用 deleteShelf。
    func restoreShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws -> RepositoryShelfRestoreResult
    func deleteShelf(in binding: RepositoryBinding, record: RepositoryShelfRecord) async throws
}
