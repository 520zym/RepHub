import Foundation

/// HTTPS 连接的协议下限策略。默认使用工具及系统的现代 TLS 协商设置。
public enum RepositoryTLSMode: String, Codable, CaseIterable, Sendable {
    case modern
    case legacyCompatible
}

/// 仅表示一个 HTTPS 服务器端点，不保留仓库路径、用户名、密码或查询参数。
public struct RepositoryEndpointPolicy: Identifiable, Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let tlsMode: RepositoryTLSMode

    /// 端点的可显示、可复用地址部分；IPv6 按 URL 权威部分保留方括号。
    public var id: String {
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return "\(displayHost):\(port)"
    }

    public init(host: String, port: Int = 443, tlsMode: RepositoryTLSMode) throws {
        guard let normalizedHost = Self.normalizeHost(host), (1...65_535).contains(port) else {
            throw RepositoryEndpointPolicyError.invalidEndpoint
        }
        self.host = normalizedHost
        self.port = port
        self.tlsMode = tlsMode
    }

    /// 配置入口只接受无凭据的 HTTPS 地址；路径会被丢弃，端口默认 443。
    public init(httpsAddress: String, tlsMode: RepositoryTLSMode) throws {
        guard let endpoint = Self.endpoint(from: httpsAddress, allowCredentials: false) else {
            throw RepositoryEndpointPolicyError.invalidEndpoint
        }
        try self.init(host: endpoint.host, port: endpoint.port, tlsMode: tlsMode)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let host = try values.decode(String.self, forKey: .host)
        let port = try values.decode(Int.self, forKey: .port)
        let tlsMode = try values.decode(RepositoryTLSMode.self, forKey: .tlsMode)
        try self.init(host: host, port: port, tlsMode: tlsMode)
    }

    /// 仅 HTTPS 且完整匹配主机和端口时才应用规则；包含凭据的远端地址不参与匹配。
    public func matches(remoteURL: String?) -> Bool {
        guard let remoteURL,
              let endpoint = Self.endpoint(from: remoteURL, allowCredentials: false) else {
            return false
        }
        return host == endpoint.host && port == endpoint.port
    }

    private enum CodingKeys: String, CodingKey { case host, port, tlsMode }

    private static func endpoint(from address: String, allowCredentials: Bool) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              components.fragment == nil,
              components.query == nil,
              (allowCredentials || (components.user == nil && components.password == nil)) else {
            return nil
        }
        // Foundation may return IPv6 URL hosts with brackets. 只对解析器已识别的成对方括号解包。
        let parsedHost = components.host ?? ""
        let hostValue: String
        if parsedHost.first == "[", parsedHost.last == "]" {
            hostValue = String(parsedHost.dropFirst().dropLast())
        } else {
            hostValue = parsedHost
        }
        guard let host = normalizeHost(hostValue) else { return nil }
        let port = components.port ?? 443
        guard (1...65_535).contains(port) else { return nil }
        return (host, port)
    }

    private static func normalizeHost(_ value: String) -> String? {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains(where: { "/@?#[]".contains($0) }) else {
            return nil
        }

        // 与 URLComponents 解析出的 `host` 使用同一规则，允许裸 IPv6，拒绝非主机字符。
        let authority = value.contains(":") ? "[\(value)]" : value
        guard let parsedHost = URLComponents(string: "https://\(authority)")?.host else {
            return nil
        }
        let normalizedParsed = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard normalizedParsed.caseInsensitiveCompare(value) == .orderedSame else { return nil }
        return normalizedParsed.lowercased()
    }
}

public enum RepositoryEndpointPolicyError: Error, LocalizedError, Sendable {
    case invalidEndpoint

    public var errorDescription: String? {
        "请输入不含账号、密码或查询参数的完整 HTTPS 服务器地址，例如 https://svn.example.com:8443。"
    }
}
