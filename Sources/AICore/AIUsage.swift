import Foundation

/// 仅记录服务端/CLI 报告的用量；缓存和推理 token 是输入/输出的组成部分。
/// nil 表示未报告，0 表示明确报告为零。
public struct AITokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let reasoningTokens: Int?
    public let model: String?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil,
                cachedInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil,
                reasoningTokens: Int? = nil, model: String? = nil) {
        func valid(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        self.inputTokens = valid(inputTokens); self.outputTokens = valid(outputTokens)
        var computedTotal: Int?
        if let input = self.inputTokens, let output = self.outputTokens {
            let sum = input.addingReportingOverflow(output)
            computedTotal = sum.overflow ? nil : sum.partialValue
        }
        self.totalTokens = valid(totalTokens) ?? computedTotal
        self.cachedInputTokens = valid(cachedInputTokens)
        self.cacheCreationInputTokens = valid(cacheCreationInputTokens)
        self.reasoningTokens = valid(reasoningTokens)
        self.model = model
    }
    public var hasReportedTokens: Bool {
        [inputTokens, outputTokens, totalTokens, cachedInputTokens, cacheCreationInputTokens, reasoningTokens].contains { $0 != nil }
    }
}

public enum AIUsageOutcome: String, Codable, Sendable { case succeeded, failed, cancelled }

/// 不保存密钥、请求正文、代码、输出或仓库路径。
public struct AIUsageRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let connectionID: UUID
    public let connectionName: String
    public let sceneID: UUID
    public let sceneName: String
    public let model: String
    public let durationSeconds: Double
    public let outcome: AIUsageOutcome
    public let usage: AITokenUsage?
    public init(id: UUID = UUID(), date: Date = Date(), connectionID: UUID, connectionName: String,
                sceneID: UUID, sceneName: String, model: String, durationSeconds: Double,
                outcome: AIUsageOutcome, usage: AITokenUsage?) {
        self.id = id; self.date = date; self.connectionID = connectionID; self.connectionName = connectionName
        self.sceneID = sceneID; self.sceneName = sceneName; self.model = model
        self.durationSeconds = durationSeconds; self.outcome = outcome; self.usage = usage
    }
}
