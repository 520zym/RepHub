import Foundation
import Security
import VersionControlCore

/// 将 SVN 密码保存在当前 macOS 用户的钥匙串中。
///
/// 服务端地址和用户名仅用于定位对应条目；密码只存入 `kSecValueData`，不会写入
/// UserDefaults、钥匙串标签或命令行参数。
public actor KeychainRepositoryCredentialStore: RepositoryCredentialStore {
    public static let defaultService = "com.zym.RepHub.repository.credentials"

    private let service: String
    private let client: KeychainRepositoryCredentialStoreClient

    public init(service: String = KeychainRepositoryCredentialStore.defaultService) {
        self.service = service
        self.client = .live
    }

    /// 仅用于适配器测试，避免测试访问用户真实钥匙串。
    init(service: String, client: KeychainRepositoryCredentialStoreClient) {
        self.service = service
        self.client = client
    }

    public func password(forServer server: String, username: String) async throws -> String? {
        let item = try makeItem(server: server, username: username)
        let result = client.read(item)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw keychainError(result.status, action: "读取")
        }
        guard let data = result.data, let password = String(data: data, encoding: .utf8) else {
            throw VersionControlError.executionFailed("无法读取 SVN 凭据：钥匙串中的密码数据无效。")
        }
        return password
    }

    public func save(_ credentials: RepositoryCredentials, forServer server: String) async throws {
        let item = try makeItem(server: server, username: credentials.username)
        guard !credentials.password.isEmpty else {
            throw VersionControlError.invalidData("SVN 密码不能为空。")
        }

        let passwordData = Data(credentials.password.utf8)
        let updateStatus = client.update(item, passwordData)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, action: "保存")
        }

        let addStatus = client.add(item, passwordData)
        if addStatus == errSecSuccess { return }
        // 多个窗口同时保存同一账户时，另一个调用可能在 update 与 add 之间创建条目。
        if addStatus == errSecDuplicateItem {
            let retryStatus = client.update(item, passwordData)
            if retryStatus == errSecSuccess { return }
            throw keychainError(retryStatus, action: "保存")
        }
        throw keychainError(addStatus, action: "保存")
    }

    public func remove(forServer server: String, username: String) async throws {
        let item = try makeItem(server: server, username: username)
        let status = client.delete(item)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "删除")
        }
    }

    private func makeItem(server: String, username: String) throws -> KeychainRepositoryCredentialItem {
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VersionControlError.invalidData("SVN 服务地址不能为空。")
        }
        guard !username.isEmpty else {
            throw VersionControlError.invalidData("SVN 用户名不能为空。")
        }
        return KeychainRepositoryCredentialItem(service: service, account: Self.account(server: server, username: username))
    }

    /// 对两个 UTF-8 字段分别 Base64 编码并带版本前缀，避免简单拼接产生歧义。
    /// 账号字段不含密码，也不使用钥匙串 label/comment 保存敏感内容。
    static func account(server: String, username: String) -> String {
        let encodedServer = Data(server.utf8).base64EncodedString()
        let encodedUsername = Data(username.utf8).base64EncodedString()
        return "v1:\(encodedServer):\(encodedUsername)"
    }

    private func keychainError(_ status: OSStatus, action: String) -> VersionControlError {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "状态码 \(status)"
        return .executionFailed("无法\(action) SVN 凭据：\(detail)。请检查 macOS 钥匙串访问权限。")
    }
}

/// 适配器内部的最小钥匙串接口，使单元测试不触及用户钥匙串。
struct KeychainRepositoryCredentialStoreClient: @unchecked Sendable {
    let read: (KeychainRepositoryCredentialItem) -> (status: OSStatus, data: Data?)
    let update: (KeychainRepositoryCredentialItem, Data) -> OSStatus
    let add: (KeychainRepositoryCredentialItem, Data) -> OSStatus
    let delete: (KeychainRepositoryCredentialItem) -> OSStatus

    static let live = Self(
        read: { item in
            var query = item.query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        update: { item, data in
            SecItemUpdate(item.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        },
        add: { item, data in
            var query = item.query
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
            return SecItemAdd(query as CFDictionary, nil)
        },
        delete: { item in
            SecItemDelete(item.query as CFDictionary)
        }
    )
}

struct KeychainRepositoryCredentialItem: Sendable, Equatable {
    let service: String
    let account: String

    var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
