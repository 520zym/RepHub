import Foundation

/// 分栏尺寸的轻量持久化存储。键名由调用方指定，以便不同工作台区域独立恢复。
public struct SplitLayoutStore {
    private let defaults: UserDefaults
    private let namespace: String

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "com.zym.RepHub.split-layout.v1"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    public func value(for storageKey: String) -> CGFloat? {
        guard let key = qualifiedKey(for: storageKey),
              let number = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        let value = CGFloat(number.doubleValue)
        return value.isFinite && value >= 0 ? value : nil
    }

    public func save(_ value: CGFloat, for storageKey: String) {
        guard value.isFinite, value >= 0,
              let key = qualifiedKey(for: storageKey) else { return }
        defaults.set(Double(value), forKey: key)
    }

    private func qualifiedKey(for storageKey: String) -> String? {
        let normalized = storageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "\(namespace).\(normalized)"
    }
}
