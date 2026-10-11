import Foundation
import VersionControlCore

/// 保存 Subversion HTTPS 端点的协议兼容规则；不保存认证信息或仓库路径。
public actor RepositoryConnectionSettings {
    private struct StoredRules: Codable {
        let version: Int
        let rules: [RepositoryEndpointPolicy]
    }

    private let storageURL: URL
    private var loadedRules: [RepositoryEndpointPolicy]?

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
    }

    public func rules() async throws -> [RepositoryEndpointPolicy] {
        try loadRulesIfNeeded()
    }

    /// 只对输入地址的 HTTPS 主机和端口写入或删除旧 TLS 兼容规则。
    public func setLegacyCompatibility(for address: String, enabled: Bool) async throws {
        let endpoint = try RepositoryEndpointPolicy(httpsAddress: address, tlsMode: .legacyCompatible)
        var rules = try loadRulesIfNeeded()
        rules.removeAll { $0.id == endpoint.id }
        if enabled { rules.append(endpoint) }
        rules.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        try persist(rules)
        loadedRules = rules
    }

    /// 非 HTTPS、携带凭据的 URL 或无规则命中时一律使用现代协商。
    public func mode(for remoteURL: String?) async -> RepositoryTLSMode {
        guard let rules = try? loadRulesIfNeeded() else { return .modern }
        return rules.first { $0.matches(remoteURL: remoteURL) }?.tlsMode ?? .modern
    }

    private func loadRulesIfNeeded() throws -> [RepositoryEndpointPolicy] {
        if let loadedRules { return loadedRules }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            loadedRules = []
            return []
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let stored = try JSONDecoder().decode(StoredRules.self, from: data)
            guard stored.version == 1 else { throw RepositoryConnectionSettingsError.unsupportedVersion }
            let unique = Dictionary(stored.rules.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            let rules = unique.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            loadedRules = rules
            return rules
        } catch let error as RepositoryConnectionSettingsError {
            throw error
        } catch {
            throw RepositoryConnectionSettingsError.unreadableConfiguration
        }
    }

    private func persist(_ rules: [RepositoryEndpointPolicy]) throws {
        let parent = storageURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredRules(version: 1, rules: rules))
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            throw RepositoryConnectionSettingsError.cannotSaveConfiguration
        }
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RepHub", isDirectory: true)
            .appendingPathComponent("svn-connections.json", isDirectory: false)
    }
}

public enum RepositoryConnectionSettingsError: Error, LocalizedError, Sendable {
    case unreadableConfiguration
    case unsupportedVersion
    case cannotSaveConfiguration

    public var errorDescription: String? {
        switch self {
        case .unreadableConfiguration:
            "无法读取 SVN 连接设置。配置文件可能已损坏，未覆盖原文件。"
        case .unsupportedVersion:
            "SVN 连接设置版本不受支持，未覆盖原文件。"
        case .cannotSaveConfiguration:
            "无法保存 SVN 连接设置，请检查应用支持目录权限。"
        }
    }
}
