import Foundation
import Testing
@testable import AIAdapters
import AICore

// URLProtocol 的协议类注册是 session 级共享状态，串行执行避免各用例替换夹具响应。
@Suite("OpenAI Chat Completions 适配器", .serialized)
struct OpenAICompatibleProviderTests {
    @Test("根地址会补全 Chat Completions 路径，并分开发送 system 与 user")
    func requestShapeAndResponseDecoding() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request, body: requestBodyData(request))
            return .init(status: 200, body: #"{"choices":[{"message":{"content":" feat: 生成说明 "},"finish_reason":"stop"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        let output = try await provider.execute(request(baseURL: "https://model.example/v1"), apiKey: "secret-value") { _ in }

        #expect(output == "feat: 生成说明")
        let latestRequest = recorder.latest()
        let captured = try #require(latestRequest)
        #expect(captured.url?.absoluteString == "https://model.example/v1/chat/completions")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(recorder.latestBody())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"]?.contains("测试.swift") == true)
    }

    @Test("完整接口地址不重复拼接")
    func completeEndpointIsKept() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://model.example/v1/chat/completions")
            return .init(status: 200, body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        let value = try await provider.execute(request(baseURL: "https://model.example/v1/chat/completions"), apiKey: "key") { _ in }
        #expect(value == "ok")
    }

    @Test("OpenAI 官方根地址会补全 v1 Chat Completions 路径")
    func officialRootAddsV1Path() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            return .init(status: 200, body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        #expect(try await provider.execute(request(baseURL: "https://api.openai.com"), apiKey: "key") { _ in } == "ok")
    }

    @Test("拒绝不安全 URL，检查不会访问模型")
    func configurationValidationDoesNotMakeRequest() async throws {
        let provider = OpenAICompatibleProvider(session: makeSession())
        let connection = AIConnection(name: "bad", baseURL: "http://model.example/v1", model: "gpt")
        await expectAIError(containing: "必须使用 HTTPS") { try await provider.check(connection) }
        let userInfo = AIConnection(name: "bad", baseURL: "https://user:pass@model.example/v1?x=1", model: "gpt")
        await expectAIError(containing: "不能包含账号") { try await provider.check(userInfo) }
        let localhost = AIConnection(name: "local", baseURL: "http://localhost:11434/v1", model: "local")
        #expect(try await provider.check(localhost) == "配置有效，尚未连接模型")
    }

    @Test("HTTP 失败不回显服务端正文或 API 密钥")
    func httpFailureHidesResponseBodyAndKey() async throws {
        MockURLProtocol.handler = { _ in .init(status: 401, body: "secret-value service diagnostic") }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        do {
            _ = try await provider.execute(request(), apiKey: "secret-value") { _ in }
            Issue.record("应当抛出 HTTP 错误")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("HTTP 401"))
            #expect(!message.contains("secret-value"))
            #expect(!message.contains("diagnostic"))
        }
    }

    @Test("本地模型可省略认证，外部 HTTPS 必须提供密钥")
    func localModelMayOmitKeyButRemoteModelMayNot() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return .init(status: 200, body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        #expect(try await provider.execute(request(baseURL: "http://localhost:11434/v1"), apiKey: nil) { _ in } == "ok")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "Authorization") == nil)
        await expectAIError(containing: "保存此连接的 API 密钥") {
            try await provider.execute(request(), apiKey: nil) { _ in }
        }
    }

    @Test("密钥中的换行和控制字符会在发请求前被拒绝")
    func keyWithControlCharactersIsRejected() async throws {
        let provider = OpenAICompatibleProvider(session: makeSession())
        await expectAIError(containing: "控制字符") {
            try await provider.execute(request(), apiKey: "valid\r\nInjected: true") { _ in }
        }
    }

    @Test("重定向被保留为失败，不会把密钥转交给其他地址")
    func redirectsAreNotFollowed() async throws {
        MockURLProtocol.handler = { _ in
            .init(status: 302, body: "", headers: ["Location": "https://other.example/chat/completions"])
        }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        await expectAIError(containing: "HTTP 302") { try await provider.execute(request(), apiKey: "key") { _ in } }
    }

    @Test("空文本及服务端截断不会作为可提交结果返回")
    func rejectsEmptyAndTruncatedOutput() async throws {
        MockURLProtocol.handler = { _ in .init(status: 200, body: #"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#) }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        await expectAIError(containing: "没有返回可用文本") { try await provider.execute(request(), apiKey: "key") { _ in } }
        MockURLProtocol.handler = { _ in .init(status: 200, body: #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#) }
        await expectAIError(containing: "长度限制") { try await provider.execute(request(), apiKey: "key") { _ in } }
        MockURLProtocol.handler = { _ in .init(status: 200, body: #"{"choices":[{"message":{"content":"filtered"},"finish_reason":"content_filter"}]}"#) }
        await expectAIError(containing: "正常状态") { try await provider.execute(request(), apiKey: "key") { _ in } }
    }

    @Test("取消任务会取消 HTTP 请求，不生成部分文本")
    func cancellationIsPropagated() async throws {
        MockURLProtocol.handler = { _ in .init(status: 200, body: #"{"choices":[{"message":{"content":"late"},"finish_reason":"stop"}]}"#) }
        defer { MockURLProtocol.handler = nil }
        let provider = OpenAICompatibleProvider(session: makeSession())
        let task = Task {
            try await provider.execute(request(), apiKey: "key") { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后不应产生模型结果")
        } catch is CancellationError {
            // 预期：上层可据此停止进度状态。
        }
    }

    @Test("报告 Chat 用量，且长度截断时仍先上报真实计费结果")
    func reportsUsageBeforeRejectingTruncatedOutput() async throws {
        MockURLProtocol.handler = { _ in
            .init(status: 200, body: #"{"model":"deepseek-test","usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}},"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let recorder = UsageRecorder()
        await expectAIError(containing: "长度限制") {
            try await OpenAICompatibleProvider(session: makeSession()).execute(request(), apiKey: "key") { event in
                if case .usage(let usage) = event { recorder.record(usage) }
            }
        }
        let usage = try #require(recorder.first())
        #expect(usage.inputTokens == 11)
        #expect(usage.outputTokens == 7)
        #expect(usage.totalTokens == 18)
        #expect(usage.cachedInputTokens == 3)
        #expect(usage.reasoningTokens == 2)
        #expect(usage.model == "deepseek-test")
    }

    @Test("MiniMax HTTP 200 中的 base_resp 业务错误不会被当作成功")
    func rejectsMiniMaxBusinessError() async throws {
        MockURLProtocol.handler = { _ in
            .init(status: 200, body: #"{"base_resp":{"status_code":1004},"usage":{"prompt_tokens":6,"completion_tokens":1}}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let recorder = UsageRecorder()
        await expectAIError(containing: "服务状态 1004") {
            try await OpenAICompatibleProvider(session: makeSession()).execute(request(), apiKey: "key") { event in
                if case .usage(let usage) = event { recorder.record(usage) }
            }
        }
        #expect(recorder.first()?.totalTokens == 7)
    }

    @Test("模型列表复用安全边界，GLM 返回官方预设且不会联网")
    func modelCatalogDiscoveryAndGLMFallback() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { wire in
            recorder.record(wire)
            return .init(status: 200, body: #"{"data":[{"id":"deepseek-v4-pro","name":"Pro"},{"id":"deepseek-flash"}]}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let connection = AIConnection(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let catalog = try await HTTPAIModelCatalogProvider(session: makeSession()).models(for: connection, apiKey: "key")
        if case .remote = catalog.source { } else { Issue.record("应来自远端模型列表") }
        #expect(catalog.models.map(\.id) == ["deepseek-flash", "deepseek-v4-pro"])
        #expect(recorder.latest()?.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(recorder.latest()?.value(forHTTPHeaderField: "Authorization") == "Bearer key")

        MockURLProtocol.handler = { _ in
            Issue.record("GLM 预设不应发起网络请求")
            return .init(status: 500, body: "")
        }
        let glm = AIConnection(name: "GLM", baseURL: AIProviderPreset.glm.baseURL, model: "glm-5", preset: .glm)
        let preset = try await HTTPAIModelCatalogProvider(session: makeSession()).models(for: glm, apiKey: "key")
        if case .officialPreset = preset.source { } else { Issue.record("GLM 应明确标识为官方预设") }
        #expect(preset.models.map(\.id) == ["glm-5"])
    }
}

private func request(baseURL: String = "https://model.example/v1") -> AIExecutionRequest {
    let connection = AIConnection(name: "测试", baseURL: baseURL, model: "test-model", timeoutSeconds: 10)
    let scene = AIScene(name: "生成提交说明", kind: .commitMessage, prompt: "只生成说明")
    return AIExecutionRequest(connection: connection, scene: scene, context: AIContext(sourceLabel: "测试", basis: "工作区", files: [.init(path: "测试.swift", patch: "+ let answer = 42")]))
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func expectAIError<Result>(
    containing text: String,
    _ operation: () async throws -> Result
) async {
    do {
        _ = try await operation()
        Issue.record("应当抛出 AIError：\(text)")
    } catch let error as AIError {
        #expect(error.localizedDescription.contains(text))
    } catch {
        Issue.record("应当抛出 AIError，实际为：\(error)")
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?
    func record(_ request: URLRequest, body: Data? = nil) {
        lock.withLock { self.request = request; self.body = body }
    }
    func latest() -> URLRequest? { lock.withLock { request } }
    func latestBody() -> Data? { lock.withLock { body } }
}

private final class UsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AITokenUsage] = []
    func record(_ usage: AITokenUsage) { lock.withLock { values.append(usage) } }
    func first() -> AITokenUsage? { lock.withLock { values.first } }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
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

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        let headers: [String: String]
        init(status: Int, body: String, headers: [String: String] = [:]) {
            self.status = status; self.body = body; self.headers = headers
        }
    }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"].merging(reply.headers) { _, replacement in replacement })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
