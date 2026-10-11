import Foundation
import Security
import AICore

/// 将 API 密钥保存在当前 macOS 用户钥匙串；持久化配置中仅保存连接 UUID。
public struct KeychainAISecretStore: AISecretStore, Sendable {
    public static let service = "com.zym.RepHub.ai"
    private let service: String

    public init(service: String = KeychainAISecretStore.service) {
        self.service = service
    }

    public func read(for connectionID: UUID) throws -> String? {
        var query = itemQuery(for: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw keychainError(status, action: "读取")
        }
        return secret
    }

    public func save(_ secret: String, for connectionID: UUID) throws {
        guard !secret.isEmpty else {
            throw AIError.invalidConfiguration("API 密钥不能为空。")
        }
        let data = Data(secret.utf8)
        let query = itemQuery(for: connectionID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, action: "保存")
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus, action: "保存") }
    }

    public func delete(for connectionID: UUID) throws {
        let status = SecItemDelete(itemQuery(for: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "删除")
        }
    }

    private func itemQuery(for connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
    }

    private func keychainError(_ status: OSStatus, action: String) -> AIError {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "状态码 \(status)"
        return .unavailable("无法\(action) API 密钥：\(detail)。请检查 macOS 钥匙串访问权限。")
    }
}
