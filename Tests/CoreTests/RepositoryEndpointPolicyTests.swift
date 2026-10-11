import Foundation
import Testing
import VersionControlCore

@Suite("HTTPS 连接端点")
struct RepositoryEndpointPolicyTests {
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

}
