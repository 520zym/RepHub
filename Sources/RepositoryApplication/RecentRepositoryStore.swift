import Foundation
import Observation

/// 用户最近打开过、且已识别出版本控制绑定的工作区。
///
/// 条目只保存展示所需的快照信息，不会在读取时扫描文件夹或调用版本控制工具。
public struct RecentRepository: Identifiable, Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let providerNames: [String]
    public let lastOpenedAt: Date

    public var id: String { path }
    public var directory: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// 主目录使用 `~` 缩写，方便在打开仓库面板中辨认。
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    public init(path: String, name: String, providerNames: [String], lastOpenedAt: Date) {
        self.path = path
        self.name = name
        self.providerNames = providerNames
        self.lastOpenedAt = lastOpenedAt
    }
}

/// 最近工作区的本地持久化。`defaults == nil` 时仅保存在内存，适合预览和隔离测试。
@MainActor
@Observable
public final class RecentRepositoryStore {
    private static let storageKey = "rephub.recentRepositories.v1"
    private static let maximumEntries = 20

    private let defaults: UserDefaults?
    public private(set) var entries: [RecentRepository]

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let defaults, let data = defaults.data(forKey: Self.storageKey) else {
            entries = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([RecentRepository].self, from: data)
            let normalized = Self.normalizedEntries(decoded)
            entries = normalized
            if normalized != decoded { persist(normalized) }
        } catch {
            // 历史版本或损坏数据不阻断打开仓库；下次正常记录时会覆盖它。
            entries = []
        }
    }

    /// 记录成功识别到的工作区。未受版本控制的文件夹不会进入历史记录。
    public func record(_ workspace: Workspace) {
        guard !workspace.isUnmanaged, !workspace.bindings.isEmpty,
              let path = Self.normalizedPath(for: workspace.directory, resolvingSymlinks: true) else {
            return
        }

        let providerNames = Self.uniqueProviderNames(workspace.bindings.map(\.providerName))
        let entry = RecentRepository(
            path: path,
            name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
            providerNames: providerNames,
            lastOpenedAt: Date()
        )
        let next = [entry] + entries.filter { $0.path != path }
        entries = Array(next.prefix(Self.maximumEntries))
        persist(entries)
    }

    public func remove(_ entry: RecentRepository) {
        entries.removeAll { $0.path == entry.path }
        persist(entries)
    }

    public func clear() {
        entries = []
        defaults?.removeObject(forKey: Self.storageKey)
    }

    private func persist(_ value: [RecentRepository]) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func normalizedEntries(_ values: [RecentRepository]) -> [RecentRepository] {
        var seen = Set<String>()
        var result: [RecentRepository] = []
        for value in values.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) {
            guard let path = normalizedStoredPath(value.path),
                  !seen.contains(path) else { continue }
            seen.insert(path)
            let names = uniqueProviderNames(value.providerNames)
            guard !names.isEmpty else { continue }
            result.append(RecentRepository(
                path: path,
                name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
                providerNames: names,
                lastOpenedAt: value.lastOpenedAt
            ))
            if result.count == maximumEntries { break }
        }
        return result
    }

    /// 已保存的路径不访问文件系统：移除的磁盘或断开的符号链接仍可作为历史条目展示。
    private static func normalizedStoredPath(_ value: String) -> String? {
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return normalizedPath(for: URL(fileURLWithPath: value, isDirectory: true), resolvingSymlinks: false)
    }

    private static func normalizedPath(for directory: URL, resolvingSymlinks: Bool) -> String? {
        guard directory.isFileURL else { return nil }
        var normalized = directory.standardizedFileURL
        if resolvingSymlinks { normalized = normalized.resolvingSymlinksInPath() }
        let path = normalized.path
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private static func uniqueProviderNames(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
