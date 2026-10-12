import Foundation
import AICore

/// Anthropic Messages API 适配器。首发只请求单轮、非流式文本结果。
public struct AnthropicMessagesProvider: AIProvider, Sendable {
    public let kind: AIConnectionKind = .anthropicMessages
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(session: URLSession = .shared, maximumResponseBytes: Int = 512 * 1024) {
        self.session = session; self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func check(_ connection: AIConnection) async throws -> String {
        guard connection.kind == kind else { throw AIError.invalidConfiguration("所选连接不是 Anthropic Messages API。") }
        _ = try endpoint(for: connection)
        guard !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidConfiguration("请填写模型名称。") }
        _ = try APIProviderSupport.timeout(connection)
        return "配置有效，尚未连接模型"
    }

    public func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        try Task.checkCancellation()
        guard request.connection.kind == kind else { throw AIError.invalidConfiguration("所选连接不是 Anthropic Messages API。") }
        guard request.context.byteCount <= APIProviderSupport.maximumContextBytes else { throw AIError.contextTooLarge }
        let endpoint = try endpoint(for: request.connection)
        let key = try APIProviderSupport.apiKey(apiKey, endpoint: endpoint)
        let body = try encodedBody(for: request)
        var wire = URLRequest(url: endpoint, timeoutInterval: try APIProviderSupport.timeout(request.connection))
        wire.httpMethod = "POST"; wire.httpBody = body
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        wire.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        wire.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key { wire.setValue(key, forHTTPHeaderField: "x-api-key") }
        await progress(.status("正在发送已选差异…"))
        let data = try await APIProviderSupport.data(session: session, request: wire, maximumBytes: maximumResponseBytes)
        if let usage = usage(from: data) { await progress(.usage(usage)) }
        let text = try decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyOutput }
        await progress(.textDelta(text)); await progress(.status("已生成"))
        return text
    }

    private func endpoint(for connection: AIConnection) throws -> URL { try APIProviderSupport.endpoint(connection.baseURL, suffix: "messages") }

    private func encodedBody(for request: AIExecutionRequest) throws -> Data {
        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable { let model: String; let system: String; let messages: [Message]; let maxTokens: Int; let stream: Bool
            enum CodingKeys: String, CodingKey { case model, system, messages, stream; case maxTokens = "max_tokens" }
        }
        do {
            return try JSONEncoder().encode(Body(model: request.connection.model.trimmingCharacters(in: .whitespacesAndNewlines),
                                                system: request.systemPrompt,
                                                messages: [.init(role: "user", content: request.userPrompt)], maxTokens: 4096, stream: false))
        } catch { throw AIError.failed("无法编码模型请求。") }
    }

    private func decode(_ data: Data) throws -> String {
        struct Block: Decodable { let type: String; let text: String? }
        struct Response: Decodable { let content: [Block]; let stopReason: String?
            enum CodingKeys: String, CodingKey { case content; case stopReason = "stop_reason" }
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.stopReason == "end_turn" else {
                throw AIError.failed("模型未以正常状态完成输出，请缩小差异范围或调整模型配置。")
            }
            var values: [String] = []
            for block in response.content {
                guard block.type == "text", let text = block.text else {
                    throw AIError.failed("模型返回了非文本结果，当前只接受完整文本输出。")
                }
                values.append(text)
            }
            guard !values.isEmpty else { throw AIError.emptyOutput }
            return values.joined()
        } catch let error as AIError { throw error }
        catch { throw AIError.failed("模型服务返回了无法识别的 Messages 结果。") }
    }

    private func usage(from data: Data) -> AITokenUsage? {
        struct Usage: Decodable {
            let inputTokens: Int?; let outputTokens: Int?; let cacheReadInputTokens: Int?; let cacheCreationInputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens", cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }
        struct Envelope: Decodable { let usage: Usage?; let model: String? }
        guard let response = try? JSONDecoder().decode(Envelope.self, from: data), let value = response.usage else { return nil }
        let baseInput = nonnegative(value.inputTokens)
        let cacheRead = nonnegative(value.cacheReadInputTokens)
        let cacheCreation = nonnegative(value.cacheCreationInputTokens)
        // input_tokens 是总输入量的基数；单独出现缓存字段不能冒充完整输入量。
        let totalInput = baseInput.flatMap { safelyAdd([$0, cacheRead, cacheCreation]) }
        let reported = AITokenUsage(inputTokens: totalInput, outputTokens: nonnegative(value.outputTokens),
                                    cachedInputTokens: cacheRead, cacheCreationInputTokens: cacheCreation, model: response.model)
        return reported.hasReportedTokens ? reported : nil
    }

    private func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }

    private func safelyAdd(_ values: [Int?]) -> Int? {
        values.compactMap { $0 }.reduce(into: Optional(0)) { partial, value in
            guard let existing = partial else { return }
            let result = existing.addingReportingOverflow(value)
            partial = result.overflow ? nil : result.partialValue
        }
    }
}
