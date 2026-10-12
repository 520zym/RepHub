import Foundation

/// 读取能力契约；更新等写能力通过 RepositoryOperationProvider 单独提供。
public protocol VersionControlProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// 未发现本工具元数据返回 nil；工具缺失、权限或元数据错误必须抛错。
    func detect(at directory: URL) async throws -> RepositoryBinding?
    func status(in binding: RepositoryBinding) async throws -> [FileChange]
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision]
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference]
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange]
    /// revision == nil 时比较当前工作区；否则比较该修订与父版本。
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch
}

public extension VersionControlProvider {
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
}
