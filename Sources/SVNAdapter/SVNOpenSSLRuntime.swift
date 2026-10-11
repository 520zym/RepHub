import Foundation
import ToolExecution
import VersionControlCore

/// 旧 TLS 配置依赖 OpenSSL 3 的 `OPENSSL_CONF` 加载机制。
/// 结果按实际被定位到的 svn 可执行文件路径缓存，避免每次远端读取重复启动 svn。
actor SVNOpenSSLRuntime {
    static let shared = SVNOpenSSLRuntime()

    private var openSSL3SupportByExecutable: [String: Bool] = [:]

    func requireOpenSSL3(using runner: CommandRunner) async throws {
        guard let executable = ToolLocator.find("svn") else {
            throw VersionControlError.toolUnavailable("svn")
        }
        if let supported = openSSL3SupportByExecutable[executable] {
            try ensureSupported(supported)
            return
        }

        let result = try await runner.run(
            executable: executable,
            arguments: ["--version", "--verbose"],
            timeout: 10
        )
        guard result.exitCode == 0 else {
            throw VersionControlError.unsupported("无法确认当前 svn 是否支持旧 TLS 兼容，请检查 svn --version --verbose 输出。")
        }
        let supported = Self.loadsOpenSSL3(from: result.output)
        openSSL3SupportByExecutable[executable] = supported
        try ensureSupported(supported)
    }

    static func loadsOpenSSL3(from verboseOutput: String) -> Bool {
        verboseOutput.contains("libssl.3.dylib")
    }

    private func ensureSupported(_ supported: Bool) throws {
        guard supported else {
            throw VersionControlError.unsupported(
                "旧 TLS 兼容需要由 OpenSSL 3 构建的 svn（--version --verbose 中应加载 libssl.3.dylib）；当前 svn 不支持该受限兼容配置。"
            )
        }
    }
}
