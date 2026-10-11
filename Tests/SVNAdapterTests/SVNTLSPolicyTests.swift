import Foundation
import Testing
@testable import SVNAdapter
import ToolExecution
import VersionControlCore

@Suite("Subversion 旧 TLS 策略")
struct SVNTLSPolicyTests {
    @Test("现代连接成功时不启用旧 TLS")
    func keepsModernConnectionWhenItSucceeds() async throws {
        let fallback = SVNAutomaticTLSFallback()
        let calls = TLSCallCounter()
        let result = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return success() },
            legacy: { await calls.legacy(); return success() }
        )
        #expect(result.exitCode == 0)
        #expect(await calls.snapshot() == (1, 0))
    }

    @Test("旧 TLS 成功后仅在同一主机端口的短期缓存内复用")
    func cachesOnlySuccessfulLegacyEndpointUntilExpiry() async throws {
        let clock = TLSClock(Date(timeIntervalSince1970: 100))
        let fallback = SVNAutomaticTLSFallback(now: { clock.value }, cacheLifetime: 15 * 60)
        let calls = TLSCallCounter()
        let modernTLSFailure = failure("svn: E120171: Error running context: An error occurred during SSL communication")

        _ = try await fallback.execute(
            remoteURL: "https://SVN.example.test:8443/repository",
            modern: { await calls.modern(); return modernTLSFailure },
            legacy: { await calls.legacy(); return success() }
        )
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test:8443/another-repository",
            modern: { await calls.modern(); return modernTLSFailure },
            legacy: { await calls.legacy(); return success() }
        )
        // 端口不同，不能使用前一台端点的兼容记忆。
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test:9443/repository",
            modern: { await calls.modern(); return success() },
            legacy: { await calls.legacy(); return success() }
        )
        _ = try await fallback.execute(
            remoteURL: "https://other-svn.example.test:8443/repository",
            modern: { await calls.modern(); return success() },
            legacy: { await calls.legacy(); return success() }
        )
        #expect(await calls.snapshot() == (3, 2))

        clock.advance(by: 901)
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test:8443/repository",
            modern: { await calls.modern(); return modernTLSFailure },
            legacy: { await calls.legacy(); return success() }
        )
        #expect(await calls.snapshot() == (4, 3))
    }

    @Test("兼容重试失败不写入缓存，也不会在同次操作内循环")
    func doesNotCacheFailedFallback() async throws {
        let fallback = SVNAutomaticTLSFallback()
        let calls = TLSCallCounter()
        let handshakeFailure = failure("SSL handshake failure")
        let legacyFailure = failure("still failed")
        let first = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return handshakeFailure },
            legacy: { await calls.legacy(); return legacyFailure }
        )
        #expect(first.exitCode != 0)
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return handshakeFailure },
            legacy: { await calls.legacy(); return success() }
        )
        #expect(await calls.snapshot() == (2, 2))
    }

    @Test("旧 TLS 运行时不支持时保留原始 SVN 握手诊断")
    func preservesModernResultWhenLegacyPreparationIsUnsupported() async throws {
        let fallback = SVNAutomaticTLSFallback()
        let modernFailure = failure("svn: E120171: An error occurred during SSL communication")
        let result = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { modernFailure },
            legacy: { throw VersionControlError.unsupported("OpenSSL 3 unavailable") }
        )
        #expect(result.error.contains(modernFailure.error))
        #expect(result.error.contains("OpenSSL 3 unavailable"))
        #expect(result.exitCode != 0)
    }

    @Test("缓存命中的兼容调用失败后，下次重新尝试现代协商")
    func dropsCacheWhenCachedLegacyCallFails() async throws {
        let fallback = SVNAutomaticTLSFallback()
        let calls = TLSCallCounter()
        let handshakeFailure = failure("TLS handshake failure")
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return handshakeFailure },
            legacy: { await calls.legacy(); return success() }
        )
        let cachedFailure = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return success() },
            legacy: { await calls.legacy(); return failure("legacy connection reset") }
        )
        #expect(cachedFailure.exitCode != 0)
        _ = try await fallback.execute(
            remoteURL: "https://svn.example.test/repository",
            modern: { await calls.modern(); return success() },
            legacy: { await calls.legacy(); return success() }
        )
        #expect(await calls.snapshot() == (2, 2))
    }

    @Test("证书、认证、网络及非 HTTPS 地址绝不降级")
    func doesNotFallbackForUnrelatedFailuresOrUnsafeEndpoint() async throws {
        let failures = [
            "svn: E230001: Server SSL certificate verification failed",
            "svn: E230001: certificate has expired",
            "svn: E230001: issuer is not trusted",
            "svn: E230001: hostname mismatch",
            "svn: E170001: Authentication failed",
            "svn: E170013: Unable to connect to a repository at URL",
            "svn: E170013: connection timed out",
            "svn: E170013: connection reset by peer",
            "svn: E170013: temporary failure in name resolution",
            "svn: E120171: SSL handshake failure; E230001: certificate verification failed"
        ]
        for detail in failures {
            let fallback = SVNAutomaticTLSFallback()
            let calls = TLSCallCounter()
            _ = try await fallback.execute(
                remoteURL: "https://svn.example.test/repository",
                modern: { await calls.modern(); return failure(detail) },
                legacy: { await calls.legacy(); return success() }
            )
            #expect(await calls.snapshot() == (1, 0))
        }
        let stdoutOnly = CommandResult(
            data: Data("SSL handshake failure certificate".utf8),
            errorData: Data("svn: E170013: Unable to connect".utf8),
            exitCode: 1
        )
        #expect(!SVNAutomaticTLSFallback.isProtocolHandshakeFailure(stdoutOnly))
        for detail in ["hostname mismatch", "Authentication failed", "connection reset by peer", "timed out", "cancelled", "could not resolve host"] {
            #expect(!SVNAutomaticTLSFallback.isProtocolHandshakeFailure(
                failure("svn: E120171: An error occurred during SSL communication; " + detail)
            ))
        }
        #expect(SVNAutomaticTLSFallback.isProtocolHandshakeFailure(failure(
            "svn: E170013: Unable to connect to a repository at URL 'https://svn.example.test/certificate'\nsvn: E120171: An error occurred during SSL communication"
        )))
        for address in [nil, "http://svn.example.test/repository", "file:///tmp/repository", "https://user:password@svn.example.test/repository"] {
            let fallback = SVNAutomaticTLSFallback()
            let calls = TLSCallCounter()
            _ = try await fallback.execute(
                remoteURL: address,
                modern: { await calls.modern(); return failure("SSL handshake failure") },
                legacy: { await calls.legacy(); return success() }
            )
            #expect(await calls.snapshot() == (1, 0))
        }
    }

    @Test("取消或超时直接向上返回，不能发起旧 TLS 重试")
    func doesNotFallbackForCancellationOrTimeout() async throws {
        let fallback = SVNAutomaticTLSFallback()
        let calls = TLSCallCounter()
        do {
            _ = try await fallback.execute(
                remoteURL: "https://svn.example.test/repository",
                modern: { await calls.modern(); throw CancellationError() },
                legacy: { await calls.legacy(); return success() }
            )
            Issue.record("应返回取消错误")
        } catch is CancellationError {}
        do {
            _ = try await fallback.execute(
                remoteURL: "https://svn.example.test/repository",
                modern: { await calls.modern(); throw VersionControlError.timedOut("svn") },
                legacy: { await calls.legacy(); return success() }
            )
            Issue.record("应返回超时错误")
        } catch {}
        #expect(await calls.snapshot() == (2, 0))
    }

    @Test("远端读取使用可注入命令执行器，现代成功不创建兼容配置")
    func providerUsesInjectedExecutorForRemoteRead() async throws {
        let capture = SVNCommandCapture()
        let xml = """
        <?xml version="1.0"?><log><logentry revision="9"><author>tester</author><date>2026-10-11T00:00:00.000000Z</date><msg>remote</msg></logentry></log>
        """
        let provider = SVNProvider(
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, _, configuration in
                await capture.record(arguments: arguments, usedLegacyConfiguration: configuration != nil)
                return CommandResult(data: Data(xml.utf8), exitCode: 0)
            }
        )
        let binding = RepositoryBinding(
            providerID: .svn,
            providerName: "Subversion",
            root: URL(fileURLWithPath: "/tmp/rephub-svn-test", isDirectory: true),
            remoteURL: "https://svn.example.test/repository",
            capabilities: [.history]
        )
        let revisions = try await provider.history(in: binding, limit: 1, reference: nil)
        #expect(revisions.map(\.id) == ["r9"])
        #expect(await capture.snapshot().arguments.contains("log"))
        #expect(!(await capture.snapshot().usedLegacyConfiguration))
    }

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

private actor TLSCallCounter {
    private var modernCalls = 0
    private var legacyCalls = 0
    func modern() { modernCalls += 1 }
    func legacy() { legacyCalls += 1 }
    func snapshot() -> (Int, Int) { (modernCalls, legacyCalls) }
}

private actor SVNCommandCapture {
    private var latestArguments: [String] = []
    private var usedConfiguration = false
    func record(arguments: [String], usedLegacyConfiguration: Bool) {
        latestArguments = arguments
        usedConfiguration = usedLegacyConfiguration
    }
    func snapshot() -> (arguments: [String], usedLegacyConfiguration: Bool) {
        (latestArguments, usedConfiguration)
    }
}

private final class TLSClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ current: Date) { self.current = current }
    var value: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

private func success() -> CommandResult { CommandResult(data: Data(), exitCode: 0) }
private func failure(_ message: String) -> CommandResult {
    CommandResult(data: Data(), errorData: Data(message.utf8), exitCode: 1)
}
