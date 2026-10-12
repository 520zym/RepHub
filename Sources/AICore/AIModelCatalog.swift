import Foundation

/// 厂商预设属于连接配置，不改变底层协议种类。
public enum AIProviderPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek, kimi, miniMax, glm
    public var id: String { rawValue }
    public var title: String {
        switch self { case .deepSeek: "DeepSeek"; case .kimi: "Kimi"; case .miniMax: "MiniMax"; case .glm: "GLM（智谱）" }
    }
    public var baseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .kimi: "https://api.moonshot.cn/v1"
        case .miniMax: "https://api.minimax.cn/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        }
    }
    public var defaultModel: String {
        switch self { case .deepSeek: "deepseek-flash"; case .kimi: "kimi-k3"; case .miniMax: "MiniMax-M3"; case .glm: "glm-5" }
    }
    public var fallbackModels: [AIModelDescriptor] {
        let ids: [String]
        switch self {
        case .deepSeek: ids = ["deepseek-flash", "deepseek-v4-pro"]
        case .kimi: ids = ["kimi-k3"]
        case .miniMax: ids = ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5"]
        case .glm: ids = ["glm-5"]
        }
        return ids.map { AIModelDescriptor(id: $0) }
    }
    public var supportsModelDiscovery: Bool { self != .glm }
}

public struct AIModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public init(id: String, name: String? = nil) { self.id = id; self.name = name }
}

public enum AIModelCatalogSource: String, Codable, Sendable { case remote, officialPreset }

public struct AIModelCatalog: Codable, Hashable, Sendable {
    public let models: [AIModelDescriptor]
    public let source: AIModelCatalogSource
    public let fetchedAt: Date
    public let note: String?
    public init(models: [AIModelDescriptor], source: AIModelCatalogSource, fetchedAt: Date = Date(), note: String? = nil) {
        self.models = models; self.source = source; self.fetchedAt = fetchedAt; self.note = note
    }
}

public protocol AIModelCatalogProvider: Sendable {
    /// 只查询模型元数据，不发起推理，不上传代码。
    func models(for connection: AIConnection, apiKey: String?) async throws -> AIModelCatalog
}
