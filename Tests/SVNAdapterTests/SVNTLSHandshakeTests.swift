import Darwin
import Foundation
import XCTest
@testable import SVNAdapter
import ToolExecution

/// 在回环接口启动本地服务器，验证生产配置真正完成各版本握手且不绕过证书验证。
@MainActor
final class SVNTLSHandshakeTests: XCTestCase {
    func testCompatibilityNegotiatesTLS10Through13AndStillRejectsInvalidCertificates() async throws {
        guard let openssl = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("需要 OpenSSL 3 运行本地 TLS 协议矩阵。")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-tls-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificate = folder.appendingPathComponent("server.crt")
        let key = folder.appendingPathComponent("server.key")
        let unrelatedCertificate = folder.appendingPathComponent("unrelated.crt")
        let runner = CommandRunner()
        for (name, cert, keyPath) in [("localhost", certificate, key), ("unrelated", unrelatedCertificate, folder.appendingPathComponent("unrelated.key"))] {
            let result = try await runner.run(executable: openssl, arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-noenc", "-sha256", "-days", "1",
                "-subj", "/CN=\(name)", "-addext", "subjectAltName=DNS:\(name)",
                "-keyout", keyPath.path, "-out", cert.path
            ])
            XCTAssertEqual(result.exitCode, 0, result.error)
        }

        for (flag, protocolName) in [("-tls1", "TLSv1"), ("-tls1_1", "TLSv1.1"), ("-tls1_2", "TLSv1.2"), ("-tls1_3", "TLSv1.3")] {
            let port = try availablePort()
            let server = Process()
            server.executableURL = URL(fileURLWithPath: openssl)
            server.arguments = ["s_server", "-accept", "127.0.0.1:\(port)", "-cert", certificate.path,
                                "-key", key.path, flag, "-cipher", "DEFAULT:@SECLEVEL=0", "-www", "-quiet"]
            server.standardInput = FileHandle.nullDevice
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer {
                if server.isRunning { server.terminate() }
                server.waitUntilExit()
            }
            let baseArguments = ["s_client", "-connect", "127.0.0.1:\(port)", "-brief", "-no_ign_eof", "-verify_return_error"]
            let result = try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                var result = CommandResult(data: Data(), exitCode: -1)
                for _ in 0..<30 {
                    result = try await runner.run(executable: openssl,
                        arguments: baseArguments + ["-CAfile", certificate.path, "-verify_hostname", "localhost"],
                        timeout: 3, opensslConfiguration: configuration)
                    if !result.error.contains("Connection refused") { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                return result
            }
            XCTAssertEqual(result.exitCode, 0, "\(protocolName): \(result.error)")
            XCTAssertTrue(result.error.contains("Protocol version: \(protocolName)\n"), result.error)
            XCTAssertTrue(result.error.contains("Verification: OK"), result.error)

            // 不传协议强制参数；同一份客户端配置应自动协商服务器支持的最高版本。
            if flag == "-tls1" {
                let modern = try await runner.run(executable: openssl,
                    arguments: baseArguments + ["-CAfile", certificate.path, "-verify_hostname", "localhost"], timeout: 3)
                XCTAssertNotEqual(modern.exitCode, 0, "现代默认路径不应意外开启 TLS 1.0")
            }

            for (trust, hostname) in [(certificate, "wrong.example.invalid"), (unrelatedCertificate, "localhost")] {
                let invalid = try await SVNTLSConfiguration.withLegacyCompatibleConfiguration { configuration in
                    try await runner.run(executable: openssl,
                        arguments: baseArguments + ["-CAfile", trust.path, "-verify_hostname", hostname],
                        timeout: 3, opensslConfiguration: configuration)
                }
                XCTAssertNotEqual(invalid.exitCode, 0, "\(protocolName) 必须拒绝错误证书或主机名")
                XCTAssertTrue(invalid.error.contains("certificate verify failed"), invalid.error)
            }
        }
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOBUFS) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }
}
