import Foundation
import AICore

/// 通过 OpenAI Chat Completions 兼容接口执行只读 AI 场景。
///
/// `baseURL` 可填写服务根路径（例如 `https://example.com/v1`），也可以直接填写
/// `.../chat/completions`。仅接受 HTTPS，以及用于本机开发的 localhost HTTP；不会跟随
/// 重定向，避免 API Key 被发送到另一个地址。
public struct OpenAICompatibleProvider: AIProvider, Sendable {
    public let kind: AIConnectionKind = .openAICompatible

    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(session: URLSession = .shared, maximumResponseBytes: Int = 512 * 1024) {
        self.session = session
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func check(_ connection: AIConnection) async throws -> String {
        _ = try endpoint(for: connection)
        guard connection.kind == kind else {
            throw AIError.invalidConfiguration("所选连接不是模型 API（Chat Completions）。")
        }
        guard !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidConfiguration("请填写模型名称。")
        }
        _ = try validatedTimeout(for: connection)
        return "配置有效，尚未连接模型"
    }

    public func execute(
        _ request: AIExecutionRequest,
        apiKey: String?,
        progress: @escaping AIProgressHandler
    ) async throws -> String {
        try Task.checkCancellation()
        guard request.connection.kind == kind else {
            throw AIError.invalidConfiguration("所选连接不是模型 API（Chat Completions）。")
        }
        guard request.context.byteCount <= 256 * 1024 else {
            throw AIError.contextTooLarge
        }
        let endpoint = try endpoint(for: request.connection)
        let apiKey = try validatedAPIKey(apiKey, for: endpoint)
        let timeout = try validatedTimeout(for: request.connection)
        let body = try requestBody(for: request)
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // 兼容服务端可能采用 SSE，但当前客户端请求普通完整响应，避免半截结果被当成可提交文本。
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        await progress(.status("正在发送已选差异…"))
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: RedirectBlockingDelegate())
            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, 4 * 1024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else {
                    throw AIError.failed("模型响应超过大小限制，已停止读取结果。")
                }
                data.append(byte)
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIError.unavailable("模型服务没有返回有效的 HTTP 响应。")
            }
            guard (200...299).contains(http.statusCode) else {
                // 不包含服务端响应正文，正文可能错误地回显凭据或包含敏感诊断数据。
                throw AIError.failed("模型服务返回 HTTP \(http.statusCode)，请检查地址、模型、密钥或服务状态。")
            }
            let completion = try decodeCompletion(data)
            if let finishReason = completion.finishReason, finishReason != "stop" {
                if finishReason == "length" {
                    throw AIError.failed("模型输出因长度限制而未完成，请缩小差异范围或调整模型配置。")
                }
                throw AIError.failed("模型没有以正常状态完成输出，请检查模型配置或缩小差异范围。")
            }
            let output = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw AIError.emptyOutput }
            await progress(.textDelta(output))
            await progress(.status("已生成"))
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.unavailable("连接模型服务超时，请检查网络或调高超时时间。")
        } catch {
            throw AIError.unavailable("无法连接模型服务，请检查地址、网络和 TLS 配置。")
        }
    }

    private func requestBody(for request: AIExecutionRequest) throws -> Data {
        let payload = ChatRequest(
            model: request.connection.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: request.systemPrompt),
                .init(role: "user", content: request.userPrompt)
            ]
        )
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw AIError.failed("无法编码模型请求。")
        }
    }

    private func endpoint(for connection: AIConnection) throws -> URL {
        let raw = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIError.invalidConfiguration("模型 API 地址无效，不能包含账号、查询参数或片段。")
        }
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocalhost) else {
            throw AIError.invalidConfiguration("模型 API 地址必须使用 HTTPS；仅允许 localhost 使用 HTTP。")
        }
        var path = components.percentEncodedPath
        if !path.hasSuffix("/chat/completions") {
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isOfficialAPIHost = host == "api.openai.com"
            if path.isEmpty && isOfficialAPIHost {
                path = "/v1/chat/completions"
            } else {
                path = "/" + (path.isEmpty ? "chat/completions" : path + "/chat/completions")
            }
        }
        components.percentEncodedPath = path
        guard let endpoint = components.url else {
            throw AIError.invalidConfiguration("模型 API 地址无效。")
        }
        return endpoint
    }

    private func validatedTimeout(for connection: AIConnection) throws -> TimeInterval {
        guard connection.timeoutSeconds.isFinite, (10...1800).contains(connection.timeoutSeconds) else {
            throw AIError.invalidConfiguration("超时时间需在 10 到 1800 秒之间。")
        }
        return connection.timeoutSeconds
    }

    /// 外部服务必须使用密钥；仅 loopback 本地模型可省略认证。
    private func validatedAPIKey(_ rawKey: String?, for endpoint: URL) throws -> String? {
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            let containsUnsafeControl = key.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F
            }
            guard !containsUnsafeControl else {
                throw AIError.invalidConfiguration("API 密钥不能包含换行或控制字符。")
            }
            return key
        }
        guard isLoopback(endpoint) else {
            throw AIError.invalidConfiguration("请先在设置中保存此连接的 API 密钥。")
        }
        return nil
    }

    private func isLoopback(_ endpoint: URL) -> Bool {
        let host = endpoint.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func decodeCompletion(_ data: Data) throws -> DecodedCompletion {
        do {
            let response = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let first = response.choices.first else {
                throw AIError.emptyOutput
            }
            return .init(content: first.message.content ?? "", finishReason: first.finishReason)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.failed("模型服务返回了无法识别的结果，请检查所用接口是否兼容 Chat Completions。")
        }
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    let choices: [Choice]
}

private struct DecodedCompletion { let content: String; let finishReason: String? }

/// API Key 只可发送到用户明确配置的端点；任何 3xx 都保留为原始 HTTP 失败。
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
