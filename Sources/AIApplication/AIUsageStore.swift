import AICore
import Foundation
import Observation

/// 本机保留的 AI 用量摘要。记录不包含密钥、提示词、模型输出、差异内容或仓库路径。
@MainActor
@Observable
public final class AIUsageStore {
    private enum StorageKey { static let records = "rephub.ai.usage.v1" }
    public static let maximumRecords = 1_000

    private let defaults: UserDefaults
    public private(set) var records: [AIUsageRecord]
    public private(set) var loadError: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults.data(forKey: StorageKey.records) {
                let loaded = try JSONDecoder().decode([AIUsageRecord].self, from: data)
                    .sorted { $0.date > $1.date }
                records = Array(loaded.prefix(Self.maximumRecords))
            } else {
                records = []
            }
            loadError = nil
        } catch {
            records = []
            loadError = "无法读取 AI 用量记录：\(error.localizedDescription)"
        }
    }

    public func record(_ record: AIUsageRecord) {
        var next = [record] + records.filter { $0.id != record.id }
        next.sort { $0.date > $1.date }
        if next.count > Self.maximumRecords { next.removeLast(next.count - Self.maximumRecords) }
        persist(next)
    }

    public func clear() {
        persist([])
    }

    private func persist(_ value: [AIUsageRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            defaults.set(try encoder.encode(value), forKey: StorageKey.records)
            records = value
            loadError = nil
        } catch {
            loadError = "无法保存 AI 用量记录：\(error.localizedDescription)"
        }
    }
}
