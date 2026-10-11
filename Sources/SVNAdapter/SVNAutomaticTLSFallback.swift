import Foundation
import ToolExecution
import VersionControlCore

/// 仅在一次现代 HTTPS 请求明确因 TLS/SSL 协商失败时，重试一次受限的旧 TLS 配置。
/// 成功的端点只在本次进程内记忆 15 分钟，之后重新优先使用现代协商。
actor SVNAutomaticTLSFallback {
    typealias Command = @Sendable () async throws -> CommandResult

    enum Mode: Sendable {
        case modern
        case legacyCompatible
    }

    private let now: @Sendable () -> Date
    private let cacheLifetime: TimeInterval
    private var legacyUntil: [RepositoryEndpointPolicy: Date] = [:]

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        cacheLifetime: TimeInterval = 15 * 60
    ) {
        self.now = now
        self.cacheLifetime = cacheLifetime
    }

    func execute(remoteURL: String?, modern: @escaping Command, legacy: @escaping Command) async throws -> CommandResult {
        let selection = try await probe(remoteURL: remoteURL, modern: modern, legacy: legacy)
        return selection.result
    }

    /// 为只读请求选择本次连接的 TLS 模式。调用方可将返回的模式用于紧随其后的写操作，
    /// 从而确保写命令绝不会因 TLS 兼容逻辑而自动重放。
    func probe(remoteURL: String?, modern: @escaping Command, legacy: @escaping Command) async throws -> (result: CommandResult, mode: Mode) {
        try Task.checkCancellation()
        guard let endpoint = endpoint(for: remoteURL) else {
            return (try await modern(), .modern)
        }

        if let expiry = legacyUntil[endpoint], expiry > now() {
            // 命中缓存时只执行一次兼容调用；失败不能在同一次操作内反复切换。
            do {
                try Task.checkCancellation()
                let result = try await legacy()
                try Task.checkCancellation()
                if result.exitCode != 0 {
                    legacyUntil.removeValue(forKey: endpoint)
                }
                return (result, .legacyCompatible)
            } catch {
                legacyUntil.removeValue(forKey: endpoint)
                throw error
            }
        }
        legacyUntil.removeValue(forKey: endpoint)

        let modernResult = try await modern()
        guard modernResult.exitCode != 0, Self.isProtocolHandshakeFailure(modernResult) else {
            return (modernResult, .modern)
        }

        try Task.checkCancellation()
        let legacyResult: CommandResult
        do {
            legacyResult = try await legacy()
        } catch let error as VersionControlError {
            // 同时保留原始握手诊断与运行时限制，交由 requireSuccess 统一脱敏。
            if case .unsupported(let reason) = error {
                return (CommandResult(
                    data: modernResult.data,
                    errorData: Data((modernResult.error + "\n自动 TLS 兼容不可用：" + reason).utf8),
                    exitCode: modernResult.exitCode
                ), .modern)
            }
            throw error
        }
        try Task.checkCancellation()
        if legacyResult.exitCode == 0 {
            legacyUntil[endpoint] = now().addingTimeInterval(cacheLifetime)
        }
        return (legacyResult, .legacyCompatible)
    }

    private func endpoint(for remoteURL: String?) -> RepositoryEndpointPolicy? {
        guard let remoteURL else { return nil }
        return try? RepositoryEndpointPolicy(httpsAddress: remoteURL, tlsMode: .legacyCompatible)
    }

    /// 只接受协议或握手本身的错误。证书、认证、网络、超时和取消均不在此范围。
    static func isProtocolHandshakeFailure(_ result: CommandResult) -> Bool {
        // stdout 常包含提交内容或仓库路径，不能用它推断连接错误；先移除 stderr 中的 URL，
        // 避免路径恰好出现 certificate 等普通文件名触发错误分类。
        let text = result.error
            .replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "", options: .regularExpression)
            .lowercased()
        let excluded = [
            "certificate", "cert verification", "hostname", "host name", "e230001",
            "authentication", "authorization", "not authorized", "e170001", "e215004",
            "connection refused", "connection timed out", "network is unreachable",
            "connection reset", "connection aborted", "name or service not known",
            "could not resolve", "couldn't resolve", "no route to host", "getaddrinfo",
            "temporary failure in name resolution", "timed out", "timeout", "cancelled", "canceled"
        ]
        guard !excluded.contains(where: text.contains) else { return false }

        let indicators = [
            "an error occurred during ssl communication",
            "ssl handshake", "tls handshake", "handshake failure",
            "unsafe legacy renegotiation", "unsupported protocol", "protocol version",
            "wrong version number", "no protocols available", "tlsv1 alert protocol version"
        ]
        return indicators.contains(where: text.contains)
    }
}
