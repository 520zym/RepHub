import Foundation
import AICore

/// OpenAI Responses API 适配器：只请求单个完整文本结果，不启用工具。
public struct OpenAIResponsesProvider: AIProvider, Sendable {
    public let kind: AIConnectionKind = .openAIResponses
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(session: URLSession = .shared, maximumResponseBytes: Int = 512 * 1024) {
        self.session = session; self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func check(_ connection: AIConnection) async throws -> String {
        guard connection.kind == kind else { throw AIError.invalidConfiguration("所选连接不是 OpenAI Responses API。") }
        _ = try endpoint(for: connection)
        guard !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidConfiguration("请填写模型名称。")
        }
        _ = try APIProviderSupport.timeout(connection)
        return "配置有效，尚未连接模型"
    }

    public func execute(_ request: AIExecutionRequest, apiKey: String?, progress: @escaping AIProgressHandler) async throws -> String {
        try Task.checkCancellation()
        guard request.connection.kind == kind else { throw AIError.invalidConfiguration("所选连接不是 OpenAI Responses API。") }
        guard request.context.byteCount <= APIProviderSupport.maximumContextBytes else { throw AIError.contextTooLarge }
        let endpoint = try endpoint(for: request.connection)
        let key = try APIProviderSupport.apiKey(apiKey, endpoint: endpoint)
        let body = try encodedBody(for: request)
        var wire = URLRequest(url: endpoint, timeoutInterval: try APIProviderSupport.timeout(request.connection))
        wire.httpMethod = "POST"; wire.httpBody = body
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        wire.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let key { wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        await progress(.status("正在发送已选差异…"))
        let data = try await APIProviderSupport.data(session: session, request: wire, maximumBytes: maximumResponseBytes)
        if let usage = usage(from: data) { await progress(.usage(usage)) }
        let text = try decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyOutput }
        await progress(.textDelta(text)); await progress(.status("已生成"))
        return text
    }

    private func endpoint(for connection: AIConnection) throws -> URL {
        try APIProviderSupport.endpoint(connection.baseURL, suffix: "responses")
    }

    private func encodedBody(for request: AIExecutionRequest) throws -> Data {
        struct Input: Encodable { let role: String; let content: String }
        struct Body: Encodable { let model: String; let instructions: String; let input: [Input]; let store: Bool; let stream: Bool }
        do {
            return try JSONEncoder().encode(Body(model: request.connection.model.trimmingCharacters(in: .whitespacesAndNewlines),
                                                instructions: request.systemPrompt,
                                                input: [.init(role: "user", content: request.userPrompt)], store: false, stream: false))
        } catch { throw AIError.failed("无法编码模型请求。") }
    }

    private func decode(_ data: Data) throws -> String {
        struct Content: Decodable { let type: String; let text: String?; let refusal: String? }
        struct Output: Decodable { let type: String; let role: String?; let status: String?; let content: [Content]? }
        struct Response: Decodable { let status: String; let output: [Output] }
        do {
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard result.status == "completed" else {
                throw AIError.failed("模型未完成输出，请缩小差异范围或调整模型配置。")
            }
            var texts: [String] = []
            for item in result.output {
                // reasoning 仅是内部推理项，首发版本不展示也不把它当文本结果。
                if item.type == "reasoning" { continue }
                guard item.type == "message", item.role == "assistant", let content = item.content else {
                    throw AIError.failed("模型返回了工具或执行结果；当前只接受只读文本结果。")
                }
                guard item.status == nil || item.status == "completed" else {
                    throw AIError.failed("模型消息未完成，不能将部分结果作为可用文本。")
                }
                for block in content {
                    if block.type == "refusal" || block.refusal != nil {
                        throw AIError.failed("模型拒绝了本次请求，未生成可用文本。")
                    }
                    guard block.type == "output_text", let text = block.text else {
                        throw AIError.failed("模型返回了非文本结果，当前只接受完整文本输出。")
                    }
                    texts.append(text)
                }
            }
            guard !texts.isEmpty else { throw AIError.emptyOutput }
            return texts.joined()
        } catch let error as AIError { throw error }
        catch { throw AIError.failed("模型服务返回了无法识别的 Responses 结果。") }
    }

    private func usage(from data: Data) -> AITokenUsage? {
        struct TokenDetails: Decodable { let cachedTokens: Int?; let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens"; case reasoningTokens = "reasoning_tokens" }
        }
        struct Usage: Decodable { let inputTokens: Int?; let outputTokens: Int?; let totalTokens: Int?; let inputDetails: TokenDetails?; let outputDetails: TokenDetails?
            enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens", totalTokens = "total_tokens"; case inputDetails = "input_tokens_details", outputDetails = "output_tokens_details" }
        }
        struct Envelope: Decodable { let usage: Usage?; let model: String? }
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data), let value = result.usage else { return nil }
        let reported = AITokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens, totalTokens: value.totalTokens,
                                    cachedInputTokens: value.inputDetails?.cachedTokens,
                                    reasoningTokens: value.outputDetails?.reasoningTokens, model: result.model)
        return reported.hasReportedTokens ? reported : nil
    }
}
