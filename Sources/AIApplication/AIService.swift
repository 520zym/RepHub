import Foundation
import AICore

/// AI 业务仅依赖提供者契约；具体网络/CLI/钥匙串实现由应用入口注入。
public struct AIService: Sendable {
    private let providers: [any AIProvider]
    private let secrets: any AISecretStore
    public init(providers: [any AIProvider], secrets: any AISecretStore) {
        self.providers = providers; self.secrets = secrets
    }

    public func check(_ connection: AIConnection) async throws -> String {
        try Task.checkCancellation()
        return try await provider(for: connection.kind).check(connection)
    }

    public func execute(_ request: AIExecutionRequest, progress: @escaping AIProgressHandler) async throws -> String {
        try Task.checkCancellation()
        guard !request.scene.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidConfiguration("请先填写场景提示词。")
        }
        guard !request.context.files.isEmpty else { throw AIError.invalidConfiguration("请先选择要分析的文件。") }
        guard request.context.byteCount <= 256 * 1024, request.scene.prompt.utf8.count <= 32 * 1024 else {
            throw AIError.contextTooLarge
        }
        guard request.connection.timeoutSeconds.isFinite,
              (10...1800).contains(request.connection.timeoutSeconds) else {
            throw AIError.invalidConfiguration("超时时间应在 10～1800 秒之间。")
        }
        let provider = try provider(for: request.connection.kind)
        let key = request.connection.kind == .openAICompatible ? try secrets.read(for: request.connection.id) : nil
        await progress(.status("正在连接 \(request.connection.name)…"))
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await provider.execute(request, apiKey: key, progress: progress) }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.connection.timeoutSeconds))
                    throw AIError.failed("AI 执行超时，请缩小差异范围或调整连接超时时间。")
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
            try Task.checkCancellation()
            let result = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw AIError.emptyOutput }
            guard result.utf8.count <= 1024 * 1024 else { throw AIError.failed("模型输出超过 1 MB，请缩小输入范围。") }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // 提供者不应回显凭据；服务层再遮蔽当前密钥，防止第三方错误文本泄漏。
            var message = error.localizedDescription
            if let key, !key.isEmpty { message = message.replacingOccurrences(of: key, with: "***") }
            throw AIError.failed(String(message.prefix(2000)))
        }
    }

    private func provider(for kind: AIConnectionKind) throws -> any AIProvider {
        guard let provider = providers.first(where: { $0.kind == kind }) else {
            throw AIError.unavailable("尚未注册 \(kind.title) 适配器。")
        }
        return provider
    }
}
