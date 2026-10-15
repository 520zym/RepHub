import Foundation
import Observation
import VersionControlCore

/// 已成功使用过的远程地址。地址中从不允许携带认证、查询参数或片段。
public struct RemoteRepositoryHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let url: String
    public let lastUsedAt: Date

    public var id: String { providerID.rawValue + "\u{0}" + url }

    public init(providerID: ProviderID, url: String, lastUsedAt: Date) {
        self.providerID = providerID
        self.url = url
        self.lastUsedAt = lastUsedAt
    }
}

/// SVN 服务端的非敏感账号元数据。密码只保留在 `RepositoryCredentialStore`。
public struct SavedRepositoryAccount: Identifiable, Codable, Equatable, Sendable {
    public let server: String
    public let username: String
    public let lastUsedAt: Date

    public var id: String { server + "\u{0}" + username }

    public init(server: String, username: String, lastUsedAt: Date) {
        self.server = server
        self.username = username
        self.lastUsedAt = lastUsedAt
    }
}

public enum RemoteRepositoryHistoryError: Error, LocalizedError, Sendable {
    case invalidRemoteURL
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteURL: "远程仓库地址格式无效，或包含不能保存的认证信息。"
        case .invalidCredentials: "SVN 用户名和密码不能为空，且不能包含换行或空字符。"
        }
    }
}

/// 远程获取历史。地址和账号元数据保存至偏好设置，密码永远经独立安全存储读写。
@MainActor
@Observable
public final class RemoteRepositoryHistoryStore {
    private enum StorageKey {
        static let entries = "rephub.remoteRepositoryHistory.entries.v1"
        static let accounts = "rephub.remoteRepositoryHistory.accounts.v1"
    }

    private static let maximumEntriesPerProvider = 20
    private let defaults: UserDefaults?
    private let secrets: any RepositoryCredentialStore
    public private(set) var entries: [RemoteRepositoryHistoryEntry]
    public private(set) var accounts: [SavedRepositoryAccount]

    public init(defaults: UserDefaults? = nil,
                secrets: any RepositoryCredentialStore = MemoryRepositoryCredentialStore()) {
        self.defaults = defaults
        self.secrets = secrets
        let loadedEntries = Self.load([RemoteRepositoryHistoryEntry].self, key: StorageKey.entries, defaults: defaults)
        let loadedAccounts = Self.load([SavedRepositoryAccount].self, key: StorageKey.accounts, defaults: defaults)
        entries = Self.normalizedEntries(loadedEntries)
        accounts = Self.normalizedAccounts(loadedAccounts)
        if entries != (loadedEntries ?? []) { persistEntries() }
        if accounts != (loadedAccounts ?? []) { persistAccounts() }
    }

    public func entries(for providerID: ProviderID) -> [RemoteRepositoryHistoryEntry] {
        entries.filter { $0.providerID == providerID }
    }

    /// 归一到协议、主机与非默认端口；仅接受 SVN 能使用且可持久化认证的网络协议。
    public static func credentialServer(for raw: String) -> String? {
        guard let normalized = normalizedURL(raw, providerID: .svn),
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              ["http", "https", "svn", "svn+ssh"].contains(scheme) else { return nil }
        let host = normalizedHost(rawHost)
        let defaultPort: Int? = switch scheme {
        case "http": 80
        case "https": 443
        case "svn": 3690
        case "svn+ssh": 22
        default: nil
        }
        let port = components.port
        guard port == nil || (1...65_535).contains(port!) else { return nil }
        let displayHost = host.contains(":") ? "[\(host)]" : host
        let portPart = port != nil && port != defaultPort ? ":\(port!)" : ""
        return "\(scheme)://\(displayHost)\(portPart)"
    }

    public func accounts(for remoteURL: String) -> [SavedRepositoryAccount] {
        guard let server = Self.credentialServer(for: remoteURL) else { return [] }
        return accounts.filter { $0.server == server }
    }

    public func credentials(for remoteURL: String, username: String? = nil) async throws -> RepositoryCredentials? {
        guard let server = Self.credentialServer(for: remoteURL) else { return nil }
        let requested = username
        let account: SavedRepositoryAccount?
        if let requested, !requested.isEmpty {
            account = accounts.first { $0.server == server && $0.username == requested }
        } else {
            account = accounts.first { $0.server == server }
        }
        guard let account,
              let password = try await secrets.password(forServer: server, username: account.username) else { return nil }
        return RepositoryCredentials(username: account.username, password: password)
    }

    /// 在远端地址成功使用后记录。无效或敏感地址不进入历史。
    public func record(providerID: ProviderID, url: String) {
        guard let url = Self.normalizedURL(url, providerID: providerID) else { return }
        let now = Date()
        let entry = RemoteRepositoryHistoryEntry(providerID: providerID, url: url, lastUsedAt: now)
        var next = [entry] + entries.filter { !($0.providerID == providerID && $0.url == url) }
        let sameProvider = next.filter { $0.providerID == providerID }
        if sameProvider.count > Self.maximumEntriesPerProvider {
            let retained = Set(sameProvider.prefix(Self.maximumEntriesPerProvider).map(\.id))
            next.removeAll { $0.providerID == providerID && !retained.contains($0.id) }
        }
        entries = next
        persistEntries()
    }

    /// 先成功保存密码，再更新账号元数据，保证读取历史绝不指向未保存的密码。
    public func remember(_ credentials: RepositoryCredentials, for remoteURL: String) async throws {
        let username = credentials.username
        guard !username.isEmpty, !credentials.password.isEmpty,
              !Self.containsCredentialControlCharacter(username),
              !Self.containsCredentialControlCharacter(credentials.password) else {
            throw RemoteRepositoryHistoryError.invalidCredentials
        }
        guard let server = Self.credentialServer(for: remoteURL) else { throw RemoteRepositoryHistoryError.invalidRemoteURL }
        let normalized = RepositoryCredentials(username: username, password: credentials.password)
        try await secrets.save(normalized, forServer: server)
        let account = SavedRepositoryAccount(server: server, username: username, lastUsedAt: Date())
        accounts = [account] + accounts.filter { !($0.server == server && $0.username == username) }
        persistAccounts()
    }

    public func remove(_ entry: RemoteRepositoryHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persistEntries()
    }

    public func removeAccount(_ account: SavedRepositoryAccount) async throws {
        try await secrets.remove(forServer: account.server, username: account.username)
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
    }

    private func persistEntries() { persist(entries, key: StorageKey.entries) }
    private func persistAccounts() { persist(accounts, key: StorageKey.accounts) }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults?) -> T? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func normalizedEntries(_ values: [RemoteRepositoryHistoryEntry]?) -> [RemoteRepositoryHistoryEntry] {
        var seen = Set<String>()
        var perProvider: [ProviderID: Int] = [:]
        return (values ?? []).sorted { $0.lastUsedAt > $1.lastUsedAt }.compactMap { value in
            guard let url = normalizedURL(value.url, providerID: value.providerID) else { return nil }
            let entry = RemoteRepositoryHistoryEntry(providerID: value.providerID, url: url, lastUsedAt: value.lastUsedAt)
            guard seen.insert(entry.id).inserted else { return nil }
            let count = perProvider[entry.providerID, default: 0]
            guard count < maximumEntriesPerProvider else { return nil }
            perProvider[entry.providerID] = count + 1
            return entry
        }
    }

    private static func normalizedAccounts(_ values: [SavedRepositoryAccount]?) -> [SavedRepositoryAccount] {
        var seen = Set<String>()
        return (values ?? []).sorted { $0.lastUsedAt > $1.lastUsedAt }.compactMap { value in
            let username = value.username
            guard !username.isEmpty, !containsCredentialControlCharacter(username),
                  let server = normalizedCredentialServer(value.server) else { return nil }
            let account = SavedRepositoryAccount(server: server, username: username, lastUsedAt: value.lastUsedAt)
            guard seen.insert(account.id).inserted else { return nil }
            return account
        }
    }

    private static func normalizedCredentialServer(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else { return nil }
        return credentialServer(for: raw + "/")
    }

    private static func normalizedURL(_ raw: String, providerID: ProviderID) -> String? {
        let value = raw
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isSafeText(value),
              !value.contains("#"), !value.contains("?") else { return nil }
        if providerID == .git, let scp = normalizedGitSCP(value) { return scp }
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else { return nil }
        components.scheme = scheme
        guard components.query == nil, components.fragment == nil, components.password == nil else { return nil }
        if scheme == "file" {
            guard components.host == nil || components.host?.isEmpty == true,
                  components.user == nil, components.path.hasPrefix("/") else { return nil }
            return components.url?.standardizedFileURL.absoluteString
        }
        let allowed: Set<String> = providerID == .git
            ? ["http", "https", "ssh", "git"]
            : ["http", "https", "svn", "svn+ssh"]
        guard allowed.contains(scheme), let host = components.host, !host.isEmpty,
              components.port == nil || (1...65_535).contains(components.port!) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard components.user == nil else { return nil }
        }
        if providerID == .svn { guard components.user == nil else { return nil } }
        components.host = host.lowercased()
        return components.string
    }

    private static func normalizedGitSCP(_ value: String) -> String? {
        guard !value.contains("://"), let at = value.firstIndex(of: "@"), let colon = value[at...].firstIndex(of: ":") else { return nil }
        let user = String(value[..<at])
        let host = String(value[value.index(after: at)..<colon])
        let path = String(value[value.index(after: colon)...])
        guard !user.isEmpty, !host.isEmpty, !path.isEmpty, isSafeText(user), isSafeText(host), isSafeText(path),
              !user.contains(":"), !host.contains("@"), !host.contains("/") else { return nil }
        return "\(user)@\(host.lowercased()):\(path)"
    }

    private static func normalizedHost(_ value: String) -> String {
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("["), lowercased.hasSuffix("]") {
            return String(lowercased.dropFirst().dropLast())
        }
        return lowercased
    }

    private static func isSafeText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func containsCredentialControlCharacter(_ value: String) -> Bool {
        value.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }
}
