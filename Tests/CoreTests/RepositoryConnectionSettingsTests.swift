import Foundation
import Testing
import RepositoryApplication
import VersionControlCore

@Suite("SVN 连接兼容规则")
struct RepositoryConnectionSettingsTests {
    @Test("只精确匹配规范化 HTTPS 主机和端口")
    func matchesExactHTTPSHostAndPort() throws {
        let policy = try RepositoryEndpointPolicy(httpsAddress: "https://[2001:DB8::7]:8443/repository/trunk", tlsMode: .legacyCompatible)
        #expect(policy.host == "2001:db8::7")
        #expect(policy.port == 8443)
        #expect(policy.id == "[2001:db8::7]:8443")
        #expect(policy.matches(remoteURL: "https://[2001:db8::7]:8443/another/path"))
        #expect(!policy.matches(remoteURL: "https://[2001:db8::7]:443/another/path"))
        #expect(!policy.matches(remoteURL: "http://[2001:db8::7]:8443/another/path"))
    }

    @Test("拒绝凭据和查询参数，不在规则中保存秘密")
    func rejectsCredentialsAndQueries() throws {
        #expect(throws: RepositoryEndpointPolicyError.invalidEndpoint) {
            try RepositoryEndpointPolicy(httpsAddress: "https://user:secret@example.invalid:8443/repo", tlsMode: .legacyCompatible)
        }
        #expect(throws: RepositoryEndpointPolicyError.invalidEndpoint) {
            try RepositoryEndpointPolicy(httpsAddress: "https://example.invalid:8443/repo?token=secret", tlsMode: .legacyCompatible)
        }
        #expect(throws: RepositoryEndpointPolicyError.invalidEndpoint) {
            try RepositoryEndpointPolicy(host: "svn example.invalid", tlsMode: .legacyCompatible)
        }
        #expect(throws: RepositoryEndpointPolicyError.invalidEndpoint) {
            try RepositoryEndpointPolicy(host: "[2001:db8::7]", tlsMode: .legacyCompatible)
        }
    }

    @Test("持久化仅保存端点，未命中时保持现代策略")
    func persistsEndpointAndDefaultsToModern() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-ConnectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("svn-connections.json")
        let settings = RepositoryConnectionSettings(storageURL: storage)
        try await settings.setLegacyCompatibility(for: "https://SVN.example.invalid:8443/repository/trunk", enabled: true)

        #expect(await settings.mode(for: "https://svn.example.invalid:8443/other") == .legacyCompatible)
        #expect(await settings.mode(for: "https://svn.example.invalid/other") == .modern)
        #expect(await settings.mode(for: "file:///tmp/repository") == .modern)

        let persisted = try String(contentsOf: storage, encoding: .utf8)
        #expect(persisted.contains("svn.example.invalid"))
        #expect(!persisted.contains("repository/trunk"))
        #expect(!persisted.contains("secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let restored = RepositoryConnectionSettings(storageURL: storage)
        let restoredRules = try await restored.rules()
        #expect(restoredRules.count == 1)
        #expect(await restored.mode(for: "https://svn.example.invalid:8443/path") == .legacyCompatible)

        try await restored.setLegacyCompatibility(for: "https://svn.example.invalid:8443/other", enabled: false)
        #expect((try await restored.rules()).isEmpty)
    }

    @Test("IPv6 规则可按显示地址删除")
    func removesIPv6RuleUsingDisplayAddress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-IPv6ConnectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = RepositoryConnectionSettings(storageURL: directory.appendingPathComponent("svn-connections.json"))
        try await settings.setLegacyCompatibility(for: "https://[2001:db8::7]:8443/repository", enabled: true)
        let rule = try #require((try await settings.rules()).first)
        #expect(rule.id == "[2001:db8::7]:8443")

        try await settings.setLegacyCompatibility(for: "https://\(rule.id)", enabled: false)
        #expect((try await settings.rules()).isEmpty)
    }
}
