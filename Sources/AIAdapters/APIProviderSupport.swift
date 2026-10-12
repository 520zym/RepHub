import Foundation
import AICore

/// 云端模型适配器共享的最小 HTTP 边界。
/// 它避免错误文本泄露凭据，并阻止 API 密钥随重定向发送到其他地址。
enum APIProviderSupport {
    static let maximumContextBytes = 256 * 1024

    static func endpoint(_ rawURL: String, suffix: String) throws -> URL {
        let raw = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIError.invalidConfiguration("模型 API 地址无效，不能包含账号、查询参数或片段。")
        }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else {
            throw AIError.invalidConfiguration("模型 API 地址必须使用 HTTPS；仅允许 localhost 使用 HTTP。")
        }
        let normalizedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // 必须精确比对末段，避免 /notresponses 这类地址被误判为 /responses。
        if path.split(separator: "/").last.map(String.init) != normalizedSuffix {
            // 两个官方服务常以域名根地址作为配置值；它们的 API 固定从 /v1 开始。
            let isOfficialAPIHost = host == "api.openai.com" || host == "api.anthropic.com"
            if path.isEmpty && isOfficialAPIHost {
                path = "v1/" + normalizedSuffix
            } else {
                path = path.isEmpty ? normalizedSuffix : path + "/" + normalizedSuffix
            }
        }
        components.percentEncodedPath = "/" + path
        guard let result = components.url else { throw AIError.invalidConfiguration("模型 API 地址无效。") }
        return result
    }

    static func timeout(_ connection: AIConnection) throws -> TimeInterval {
        guard connection.timeoutSeconds.isFinite, (10...1800).contains(connection.timeoutSeconds) else {
            throw AIError.invalidConfiguration("超时时间需在 10 到 1800 秒之间。")
        }
        return connection.timeoutSeconds
    }

    static func apiKey(_ value: String?, endpoint: URL) throws -> String? {
        // 先检查原始值。若先 trim，首尾换行会被静默丢弃，可能掩盖粘贴错误。
        if let value, value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw AIError.invalidConfiguration("API 密钥不能包含换行或控制字符。")
        }
        let key = value?.trimmingCharacters(in: .whitespaces)
        if let key, !key.isEmpty {
            return key
        }
        guard isLoopback(endpoint.host ?? "") else {
            throw AIError.invalidConfiguration("请先在设置中保存此连接的 API 密钥。")
        }
        return nil
    }

    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return name == "localhost" || name == "127.0.0.1" || name == "::1"
    }

    static func data(
        session: URLSession, request: URLRequest, maximumBytes: Int
    ) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: APIOnlyRedirectBlockingDelegate())
            var data = Data(); data.reserveCapacity(min(maximumBytes, 4096))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw AIError.failed("模型响应超过大小限制，已停止读取结果。") }
                data.append(byte)
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIError.unavailable("模型服务没有返回有效的 HTTP 响应。")
            }
            guard (200...299).contains(http.statusCode) else {
                throw AIError.failed("模型服务返回 HTTP \(http.statusCode)，请检查地址、模型、密钥或服务状态。")
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as AIError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut {
            throw AIError.unavailable("连接模型服务超时，请检查网络或调高超时时间。")
        } catch {
            throw AIError.unavailable("无法连接模型服务，请检查地址、网络和 TLS 配置。")
        }
    }
}

/// 始终拒绝重定向，避免 Bearer Token 被转交给其他主机。
final class APIOnlyRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
