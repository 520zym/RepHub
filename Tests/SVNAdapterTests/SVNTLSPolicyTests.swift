import Foundation
import Testing
@testable import SVNAdapter

@Suite("Subversion 旧 TLS 策略")
struct SVNTLSPolicyTests {
    @Test("仅识别实际加载 OpenSSL 3 的 svn")
    func recognizesOpenSSL3Runtime() {
        #expect(SVNOpenSSLRuntime.loadsOpenSSL3(from: "loaded shared libraries:\n/opt/homebrew/lib/libssl.3.dylib\n"))
        #expect(!SVNOpenSSLRuntime.loadsOpenSSL3(from: "loaded shared libraries:\n/usr/lib/libssl.48.dylib\n"))
    }

    @Test("兼容配置仅允许 TLS 1.0 至 1.3，并保留证书校验")
    func createsScopedLegacyConfiguration() async throws {
        let configuration = try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { file in
            let content = try String(contentsOf: file, encoding: .utf8)
            #expect(content.contains("MinProtocol = TLSv1"))
            #expect(content.contains("MaxProtocol = TLSv1.3"))
            #expect(content.contains("CipherString = DEFAULT:@SECLEVEL=0"))
            #expect(content.contains("Options = UnsafeLegacyServerConnect"))
            #expect(!content.contains("UnsafeLegacyRenegotiation"))
            #expect(!content.localizedCaseInsensitiveContains("trust-server-cert"))

            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            let mode = (values[.posixPermissions] as? NSNumber)?.intValue
            #expect(mode == 0o600)
            return file
        }

        #expect(!FileManager.default.fileExists(atPath: configuration.path))
        #expect(!FileManager.default.fileExists(atPath: configuration.deletingLastPathComponent().path))
    }
}
