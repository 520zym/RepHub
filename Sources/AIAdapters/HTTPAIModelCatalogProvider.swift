import Foundation
import AICore

/// 通过 OpenAI 风格的 `GET /models` 查询模型元数据。
///
/// 此请求不会发送提示词、代码或差异；密钥仍只会发送给用户配置的同一主机，且不跟随重定向。
public struct HTTPAIModelCatalogProvider: AIModelCatalogProvider, Sendable {
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(session: URLSession = .shared, maximumResponseBytes: Int = 256 * 1024) {
        self.session = session
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func models(for connection: AIConnection, apiKey: String?) async throws -> AIModelCatalog {
        try Task.checkCancellation()
        guard connection.kind == .openAICompatible || connection.kind == .openAIResponses else {
            throw AIError.invalidConfiguration("当前连接类型不支持自动读取模型列表。")
        }
        if case .glm? = connection.preset {
            return AIModelCatalog(models: AIProviderPreset.glm.fallbackModels, source: .officialPreset,
                                  note: "暂未找到 GLM 官方公开的模型列表接口；以下为官方预设，可手动填写其他模型 ID。")
        }
        let endpoint = try modelsEndpoint(for: connection)
        let key = try APIProviderSupport.apiKey(apiKey, endpoint: endpoint)
        var request = URLRequest(url: endpoint, timeoutInterval: try APIProviderSupport.timeout(connection))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data = try await APIProviderSupport.data(session: session, request: request, maximumBytes: maximumResponseBytes)
        let decoded = try decode(data)
        guard !decoded.isEmpty else { throw AIError.failed("模型服务没有返回可用模型，请检查密钥权限或服务配置。") }
        return AIModelCatalog(models: decoded, source: .remote)
    }

    private func modelsEndpoint(for connection: AIConnection) throws -> URL {
        let raw = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIError.invalidConfiguration("模型 API 地址无效，不能包含账号、查询参数或片段。")
        }
        guard scheme == "https" || (scheme == "http" && APIProviderSupport.isLoopback(host)) else {
            throw AIError.invalidConfiguration("模型 API 地址必须使用 HTTPS；仅允许 localhost 使用 HTTP。")
        }
        var parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if Array(parts.suffix(2)) == ["chat", "completions"] { parts.removeLast(2) }
        else if parts.last == "responses" { parts.removeLast() }
        // API 根地址缺少 /v1 时仅对 OpenAI 官方补齐，与现有适配器行为一致。
        if parts.isEmpty && host == "api.openai.com" { parts.append("v1") }
        if parts.last != "models" { parts.append("models") }
        components.percentEncodedPath = "/" + parts.joined(separator: "/")
        guard let result = components.url else { throw AIError.invalidConfiguration("模型 API 地址无效。") }
        return result
    }

    private func decode(_ data: Data) throws -> [AIModelDescriptor] {
        struct Item: Decodable { let id: String; let name: String? }
        struct Payload: Decodable { let data: [Item] }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            var known = Set<String>()
            return payload.data.compactMap { item in
                let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, known.insert(id).inserted else { return nil }
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AIModelDescriptor(id: id, name: name?.isEmpty == true ? nil : name)
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        } catch {
            throw AIError.failed("模型服务返回了无法识别的模型列表。")
        }
    }
}
