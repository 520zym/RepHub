import Foundation
import Testing
@testable import AIAdapters
import AICore

@Suite("Responses 与 Messages API 适配器", .serialized)
struct ResponsesAndMessagesProviderTests {
    @Test("Responses 请求固定 store false 并提取 completed assistant output_text")
    func responsesRequestAndCompletedText() async throws {
        let recorder = ProtocolRequestRecorder()
        ProtocolMockURLProtocol.handler = { wire in
            recorder.record(wire, body: protocolRequestBodyData(wire))
            return .init(status: 200, body: #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":" feat: response "}]}]}"#)
        }
        defer { ProtocolMockURLProtocol.handler = nil }
        let provider = OpenAIResponsesProvider(session: protocolSession())
        let result = try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "secret") { _ in }
        #expect(result == "feat: response")
        #expect(recorder.latest()?.url?.absoluteString == "https://model.example/v1/responses")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(recorder.latestBody())
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)
        #expect(object["tools"] == nil)
    }

    @Test("Responses 拒绝未完成、拒绝、工具及未完成消息")
    func responsesRejectsUnsafeOrIncompleteResult() async {
        let provider = OpenAIResponsesProvider(session: protocolSession())
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"status":"in_progress","output":[]}"#) }
        defer { ProtocolMockURLProtocol.handler = nil }
        await protocolExpectAIError(containing: "未完成") { try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"no"}]}]}"#) }
        await protocolExpectAIError(containing: "拒绝") { try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"status":"completed","output":[{"type":"function_call"}]}"#) }
        await protocolExpectAIError(containing: "工具或执行结果") { try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"status":"completed","output":[{"type":"computer_call"}]}"#) }
        await protocolExpectAIError(containing: "工具或执行结果") { try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}]}"#) }
        await protocolExpectAIError(containing: "消息未完成") { try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
    }

    @Test("Messages 请求包含版本、系统提示和单轮用户消息")
    func messagesRequestAndEndTurnText() async throws {
        let recorder = ProtocolRequestRecorder()
        ProtocolMockURLProtocol.handler = { wire in
            recorder.record(wire, body: protocolRequestBodyData(wire))
            return .init(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":" review result "}]}"#)
        }
        defer { ProtocolMockURLProtocol.handler = nil }
        let provider = AnthropicMessagesProvider(session: protocolSession())
        let result = try await provider.execute(protocolRequest(kind: .anthropicMessages), apiKey: "anthropic-secret") { _ in }
        #expect(result == "review result")
        #expect(recorder.latest()?.url?.absoluteString == "https://model.example/v1/messages")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(recorder.latestBody())
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        #expect(object["system"] is String)
        #expect(object["max_tokens"] as? Int == 4096)
        #expect(object["stream"] as? Bool == false)
        #expect((object["messages"] as? [[String: String]])?.first?["role"] == "user")
    }

    @Test("Messages 不接受截断及混入的非文本内容")
    func messagesRejectsNonTextAndTruncation() async {
        let provider = AnthropicMessagesProvider(session: protocolSession())
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#) }
        defer { ProtocolMockURLProtocol.handler = nil }
        await protocolExpectAIError(containing: "正常状态") { try await provider.execute(protocolRequest(kind: .anthropicMessages), apiKey: "key") { _ in } }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"ok"},{"type":"tool_use"}]}"#) }
        await protocolExpectAIError(containing: "非文本") { try await provider.execute(protocolRequest(kind: .anthropicMessages), apiKey: "key") { _ in } }
    }

    @Test("两种 API 共用安全边界：HTTP、大小与取消")
    func protocolSafetyBoundaries() async {
        let responseProvider = OpenAIResponsesProvider(session: protocolSession(), maximumResponseBytes: 8)
        await protocolExpectAIError(containing: "必须使用 HTTPS") {
            try await responseProvider.execute(protocolRequest(kind: .openAIResponses, baseURL: "http://model.example"), apiKey: "key") { _ in }
        }
        ProtocolMockURLProtocol.handler = { _ in .init(status: 200, body: String(repeating: "x", count: 32)) }
        defer { ProtocolMockURLProtocol.handler = nil }
        await protocolExpectAIError(containing: "大小限制") { try await responseProvider.execute(protocolRequest(kind: .openAIResponses), apiKey: "key") { _ in } }
        let task = Task { try await AnthropicMessagesProvider(session: protocolSession()).execute(protocolRequest(kind: .anthropicMessages), apiKey: "key") { _ in } }
        task.cancel()
        do { _ = try await task.value; Issue.record("取消后不应产生结果") } catch is CancellationError { }
        catch { Issue.record("应传递取消，实际为：\(error)") }
    }

    @Test("端点末段必须精确匹配，密钥换行不可被静默裁剪")
    func endpointAndKeyValidationAreStrict() async throws {
        let recorder = ProtocolRequestRecorder()
        ProtocolMockURLProtocol.handler = { wire in
            recorder.record(wire, body: protocolRequestBodyData(wire))
            return .init(status: 200, body: #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}"#)
        }
        defer { ProtocolMockURLProtocol.handler = nil }
        let provider = OpenAIResponsesProvider(session: protocolSession())
        #expect(try await provider.execute(protocolRequest(kind: .openAIResponses, baseURL: "https://model.example/v1/notresponses"), apiKey: " key ") { _ in } == "ok")
        #expect(recorder.latest()?.url?.absoluteString == "https://model.example/v1/notresponses/responses")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        await protocolExpectAIError(containing: "控制字符") {
            try await provider.execute(protocolRequest(kind: .openAIResponses), apiKey: "\nkey") { _ in }
        }
    }

    @Test("官方根地址补全各自的 v1 端点，完整端点不重复拼接")
    func officialRootsAddV1Path() async throws {
        let recorder = ProtocolRequestRecorder()
        ProtocolMockURLProtocol.handler = { wire in
            recorder.record(wire, body: protocolRequestBodyData(wire))
            if wire.url?.host == "api.anthropic.com" {
                return .init(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}"#)
            }
            return .init(status: 200, body: #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}"#)
        }
        defer { ProtocolMockURLProtocol.handler = nil }
        let responses = OpenAIResponsesProvider(session: protocolSession())
        #expect(try await responses.execute(protocolRequest(kind: .openAIResponses, baseURL: "https://api.openai.com"), apiKey: "key") { _ in } == "ok")
        #expect(recorder.latest()?.url?.absoluteString == "https://api.openai.com/v1/responses")
        let messages = AnthropicMessagesProvider(session: protocolSession())
        #expect(try await messages.execute(protocolRequest(kind: .anthropicMessages, baseURL: "https://api.anthropic.com"), apiKey: "key") { _ in } == "ok")
        #expect(recorder.latest()?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(try await messages.execute(protocolRequest(kind: .anthropicMessages, baseURL: "https://api.anthropic.com/v1/messages"), apiKey: "key") { _ in } == "ok")
        #expect(recorder.latest()?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }
}

private func protocolRequest(kind: AIConnectionKind, baseURL: String = "https://model.example/v1") -> AIExecutionRequest {
    .init(connection: AIConnection(name: "测试", kind: kind, baseURL: baseURL, model: "test-model", timeoutSeconds: 10),
          scene: AIScene(name: "审查", kind: .codeReview, prompt: "只审查"),
          context: AIContext(sourceLabel: "测试", basis: "工作区", files: [.init(path: "测试.swift", patch: "+ let x = 1")]))
}

private func protocolSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProtocolMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func protocolExpectAIError<Result>(containing text: String, _ operation: () async throws -> Result) async {
    do { _ = try await operation(); Issue.record("应当抛出 AIError：\(text)") }
    catch let error as AIError { #expect(error.localizedDescription.contains(text)) }
    catch { Issue.record("应当抛出 AIError，实际为：\(error)") }
}

private final class ProtocolRequestRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var request: URLRequest?; private var body: Data?
    func record(_ request: URLRequest, body: Data?) { lock.withLock { self.request = request; self.body = body } }
    func latest() -> URLRequest? { lock.withLock { request } }
    func latestBody() -> Data? { lock.withLock { body } }
}

private func protocolRequestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class ProtocolMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: String; init(status: Int, body: String) { self.status = status; self.body = body } }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
