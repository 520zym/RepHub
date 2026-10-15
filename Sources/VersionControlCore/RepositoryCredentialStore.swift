import Foundation

/// 远程仓库认证信息的安全存储边界。实现不得把密码写入 UserDefaults、日志或 URL。
public protocol RepositoryCredentialStore: Sendable {
    func password(forServer server: String, username: String) async throws -> String?
    func save(_ credentials: RepositoryCredentials, forServer server: String) async throws
    func remove(forServer server: String, username: String) async throws
}

/// 隔离测试和预览使用的内存凭据库。应用正式组装时应替换为钥匙串实现。
public actor MemoryRepositoryCredentialStore: RepositoryCredentialStore {
    private var values: [String: String] = [:]

    public init() {}

    public func password(forServer server: String, username: String) async throws -> String? {
        values[key(server: server, username: username)]
    }

    public func save(_ credentials: RepositoryCredentials, forServer server: String) async throws {
        values[key(server: server, username: credentials.username)] = credentials.password
    }

    public func remove(forServer server: String, username: String) async throws {
        values.removeValue(forKey: key(server: server, username: username))
    }

    private func key(server: String, username: String) -> String {
        server + "\u{0}" + username
    }
}
