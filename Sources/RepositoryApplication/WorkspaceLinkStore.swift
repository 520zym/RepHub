import Foundation

/// 主工作区到关联目录的本地映射；仅保存规范化的本地路径，不保存远端地址或凭据。
@MainActor
public final class WorkspaceLinkStore {
    private let defaults: UserDefaults?
    private let key: String
    private var values: [String: [String]]

    public init(defaults: UserDefaults? = nil, key: String = "rephub.workspace-links.v1") {
        self.defaults = defaults
        self.key = key
        if let defaults, let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.values = Self.sanitizedValues(decoded)
        } else {
            self.values = [:]
        }
    }

    public func linkedDirectories(for primary: URL) -> [URL] {
        let key = normalized(primary).path
        return (values[key] ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `linkedDirectories` 的简写，供界面按“项目目录”读取关联项。
    public func directories(for primary: URL) -> [URL] { linkedDirectories(for: primary) }

    public func setLinkedDirectories(_ directories: [URL], for primary: URL) {
        let main = normalized(primary)
        var seen = Set([main.path])
        let paths = directories.compactMap { candidate -> String? in
            guard candidate.isFileURL else { return nil }
            let path = normalized(candidate).path
            return seen.insert(path).inserted ? path : nil
        }
        if paths.isEmpty { values.removeValue(forKey: main.path) }
        else { values[main.path] = paths }
        persist()
    }

    /// `setLinkedDirectories` 的简写，保留内存模式与可注入 UserDefaults 的相同行为。
    public func setDirectories(_ directories: [URL], for primary: URL) {
        setLinkedDirectories(directories, for: primary)
    }

    public func attach(_ directory: URL, to primary: URL) {
        setLinkedDirectories(linkedDirectories(for: primary) + [directory], for: primary)
    }

    public func remove(_ directory: URL, from primary: URL) {
        let path = normalized(directory).path
        setLinkedDirectories(linkedDirectories(for: primary).filter { normalized($0).path != path }, for: primary)
    }

    public func removeAll(for primary: URL) {
        values.removeValue(forKey: normalized(primary).path)
        persist()
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func sanitizedValues(_ raw: [String: [String]]) -> [String: [String]] {
        var sanitized: [String: [String]] = [:]
        for (primary, links) in raw {
            guard isSafeAbsolutePath(primary) else { continue }
            let normalizedPrimary = URL(fileURLWithPath: primary, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            var seen = Set([normalizedPrimary])
            let normalizedLinks = links.compactMap { path -> String? in
                guard isSafeAbsolutePath(path) else { return nil }
                let normalized = URL(fileURLWithPath: path, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                return seen.insert(normalized).inserted ? normalized : nil
            }
            if !normalizedLinks.isEmpty { sanitized[normalizedPrimary] = normalizedLinks }
        }
        return sanitized
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func persist() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}
