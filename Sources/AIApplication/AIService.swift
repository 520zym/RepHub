import Foundation
import AICore

/// AI 业务仅依赖提供者契约；具体网络/CLI/钥匙串实现由应用入口注入。
public struct AIService: Sendable {
    private let providers: [any AIProvider]
    private let secrets: any AISecretStore
    private let modelCatalogProvider: (any AIModelCatalogProvider)?
    private let usageStore: AIUsageStore?

    public init(providers: [any AIProvider], secrets: any AISecretStore,
                modelCatalogProvider: (any AIModelCatalogProvider)? = nil,
                usageStore: AIUsageStore? = nil) {
        self.providers = providers
        self.secrets = secrets
        self.modelCatalogProvider = modelCatalogProvider
        self.usageStore = usageStore
    }

    public func check(_ connection: AIConnection) async throws -> String {
        try Task.checkCancellation()
        return try await provider(for: connection.kind).check(connection)
    }

    /// 只发送 API 密钥和连接配置以读取模型清单，不会发送代码或写入连接。
    public func discoverModels(for connection: AIConnection, apiKey: String? = nil) async throws -> AIModelCatalog {
        guard connection.kind.isAPI else {
            throw AIError.invalidConfiguration("本地命令行连接没有可读取的远程模型列表。")
        }
        guard let modelCatalogProvider else {
            throw AIError.unavailable("当前应用没有注册模型发现适配器。")
        }
        let key = try apiKey ?? secrets.read(for: connection.id)
        do {
            return try await modelCatalogProvider.models(for: connection, apiKey: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw sanitized(error, key: key)
        }
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
        let key = request.connection.kind.isAPI ? try secrets.read(for: request.connection.id) : nil
        var resolvedConnection = request.connection
        resolvedConnection.model = request.effectiveModel
        let resolvedRequest = AIExecutionRequest(connection: resolvedConnection, scene: request.scene, context: request.context)
        let timeoutSeconds = resolvedConnection.timeoutSeconds
        let startedAt = Date()
        let usage = UsageAccumulator()
        let collectingProgress: AIProgressHandler = { event in
            if case .usage(let value) = event { await usage.replace(with: value) }
            await progress(event)
        }
        await collectingProgress(.status("正在连接 \(resolvedConnection.name)…"))
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await provider.execute(resolvedRequest, apiKey: key, progress: collectingProgress) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
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
            await saveUsage(request: resolvedRequest, startedAt: startedAt, outcome: .succeeded, usage: usage)
            return result
        } catch is CancellationError {
            await saveUsage(request: resolvedRequest, startedAt: startedAt, outcome: .cancelled, usage: usage)
            throw CancellationError()
        }
        catch {
            if Task.isCancelled {
                await saveUsage(request: resolvedRequest, startedAt: startedAt, outcome: .cancelled, usage: usage)
                throw CancellationError()
            }
            await saveUsage(request: resolvedRequest, startedAt: startedAt, outcome: .failed, usage: usage)
            throw sanitized(error, key: key)
        }
    }

    private func saveUsage(request: AIExecutionRequest, startedAt: Date, outcome: AIUsageOutcome,
                           usage: UsageAccumulator) async {
        guard let usageStore else { return }
        let latest = await usage.value
        let value = latest?.hasReportedTokens == true ? latest : nil
        let reportedModel = latest?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (reportedModel?.isEmpty == false ? reportedModel : nil) ?? request.connection.model
        let record = AIUsageRecord(date: startedAt,
                                   connectionID: request.connection.id,
                                   connectionName: request.connection.name,
                                   sceneID: request.scene.id,
                                   sceneName: request.scene.name,
                                   model: model,
                                   durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
                                   outcome: outcome,
                                   usage: value)
        await usageStore.record(record)
    }

    private func sanitized(_ error: Error, key: String?) -> AIError {
        var message = error.localizedDescription
        if let key, !key.isEmpty {
            message = message.replacingOccurrences(of: key, with: "***")
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != key {
                message = message.replacingOccurrences(of: trimmed, with: "***")
            }
        }
        return .failed(String(message.prefix(2_000)))
    }

    private func provider(for kind: AIConnectionKind) throws -> any AIProvider {
        guard let provider = providers.first(where: { $0.kind == kind }) else {
            throw AIError.unavailable("尚未注册 \(kind.title) 适配器。")
        }
        return provider
    }
}

private actor UsageAccumulator {
    private var latest: AITokenUsage?
    func replace(with value: AITokenUsage) { latest = value }
    var value: AITokenUsage? { latest }
}
