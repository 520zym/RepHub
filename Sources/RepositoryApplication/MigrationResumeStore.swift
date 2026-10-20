import Foundation

/// 只登记由 RepHub 自己创建的迁移检查点，供应用重启后列出可继续的作业。
/// 这是一个索引，不是信任边界：真正恢复前仍必须由迁移服务重新校验检查点、
/// 本地 Git 对象和来源状态。索引从不保存用户名、口令或 URL 中的凭据。
public final class MigrationResumeStore: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable { case repository, workingCopy }

    public struct Record: Codable, Identifiable, Sendable, Equatable {
        public let id: UUID
        public let kind: Kind
        public let checkpointURL: URL
        public let source: String
        public let location: String
        public let progress: String
        public let updatedAt: Date

        public init(id: UUID, kind: Kind, checkpointURL: URL, source: String,
                    location: String, progress: String, updatedAt: Date = .now) {
            self.id = id; self.kind = kind; self.checkpointURL = checkpointURL.standardizedFileURL
            self.source = source; self.location = location; self.progress = progress; self.updatedAt = updatedAt
        }
    }

    private struct Stored: Codable { var records: [Record] }
    private let defaults: UserDefaults
    private let key: String
    private let legacyWorkingCopyRoot: URL
    private let lock = NSLock()

    public static let shared = MigrationResumeStore()

    public init(defaults: UserDefaults = .standard, key: String = "rephub.migration-resume-records",
                legacyWorkingCopyRoot: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults; self.key = key; self.legacyWorkingCopyRoot = legacyWorkingCopyRoot.standardizedFileURL
    }

    public func records(kind: Kind, searchRoots: [URL] = []) -> [Record] {
        lock.lock(); defer { lock.unlock() }
        let ignored = ignoredKeys()
        var result = load().records.filter { $0.kind == kind && !ignored.contains(ignoreKey(id: $0.id, kind: $0.kind)) }
        if kind == .workingCopy {
            // 兼容本功能引入前已生成的临时保留目录：只检查系统临时目录的一层、
            // 且只接受本应用固定前缀，绝不递归扫描用户磁盘。
            for legacy in legacyWorkingCopyRecords() where !ignored.contains(ignoreKey(id: legacy.id, kind: legacy.kind)) && !result.contains(where: { $0.id == legacy.id }) {
                result.append(legacy)
            }
        }
        if kind == .repository {
            for legacy in legacyRepositoryRecords(in: searchRoots) where !ignored.contains(ignoreKey(id: legacy.id, kind: legacy.kind)) && !result.contains(where: { $0.id == legacy.id }) {
                result.append(legacy)
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func register(_ record: Record) {
        lock.lock(); defer { lock.unlock() }
        var stored = load()
        stored.records.removeAll { $0.id == record.id && $0.kind == record.kind }
        stored.records.append(record)
        save(stored)
        var ignored = ignoredKeys(); ignored.remove(ignoreKey(id: record.id, kind: record.kind)); saveIgnored(ignored)
    }

    /// 仅移除索引，不触碰用户磁盘上的检查点或迁移结果。
    public func remove(id: UUID, kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        var stored = load(); stored.records.removeAll { $0.id == id && $0.kind == kind }; save(stored)
        var ignored = ignoredKeys(); ignored.insert(ignoreKey(id: id, kind: kind)); saveIgnored(ignored)
    }

    /// 文件选择器允许直接选中隐藏的 checkpoint.json 或它所在保留目录。
    public static func checkpointURL(for selection: URL) -> URL {
        let isDirectory = (try? selection.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return (isDirectory || selection.hasDirectoryPath) ? selection.appendingPathComponent("checkpoint.json") : selection
    }

    private func load() -> Stored {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored(records: [])
        }
        return value
    }

    private func save(_ value: Stored) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func ignoreKey(id: UUID, kind: Kind) -> String { "\(kind.rawValue):\(id.uuidString)" }
    private func ignoredKeys() -> Set<String> { Set(defaults.stringArray(forKey: "\(key).ignored") ?? []) }
    private func saveIgnored(_ values: Set<String>) { defaults.set(values.sorted(), forKey: "\(key).ignored") }

    private func legacyWorkingCopyRecords() -> [Record] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: legacyWorkingCopyRoot,
                                                                           includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let prefix = "RepHub-working-copy-migration-"
        return children.compactMap { folder in
            let name = folder.lastPathComponent
            guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else { return nil }
            let checkpoint = folder.appendingPathComponent("checkpoint.json")
            guard FileManager.default.fileExists(atPath: checkpoint.path) else { return nil }
            let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
            let summary = legacyWorkingCopySummary(checkpoint)
            // 旧临时记录可能来自已经清理的工作副本或测试夹具；固定来源已不存在时，
            // 服务无法恢复该计划，不把它作为可继续条目重新引入列表。
            if let sourceDirectory = summary.sourceDirectory,
               (try? sourceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { return nil }
            return Record(id: id, kind: .workingCopy, checkpointURL: checkpoint,
                          source: summary.location.map { "当前工作副本：\($0)" } ?? "旧工作副本迁移检查点（需手动核验）",
                          location: folder.path, progress: summary.progress,
                          updatedAt: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// 旧检查点仅限读取小型 JSON 元数据，绝不显示或保留来源 URL / 认证信息。
    private func legacyWorkingCopySummary(_ checkpoint: URL) -> (location: String?, progress: String, sourceDirectory: URL?) {
        guard let size = (try? checkpoint.resourceValues(forKeys: [.fileSizeKey]).fileSize), size <= 1_048_576,
              let data = try? Data(contentsOf: checkpoint, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = object["plan"] as? [String: Any] else {
            return (nil, "旧检查点无法解析，继续前将重新核验", nil)
        }
        let path = (plan["workingCopyPath"] as? String).flatMap { URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
        let completed = (object["mappings"] as? [Any])?.count
        let total = (plan["revisions"] as? [Any])?.count
        let progress = (completed != nil && total != nil) ? "已核对 \(completed!) / \(total!) 条修订；继续前将重新核验" : "旧检查点，继续前将重新核验"
        return (path, progress, (plan["workingCopyPath"] as? String).map { URL(fileURLWithPath: $0) })
    }

    /// 新目录迁移的旧暂存目录只在用户已选择的结果父目录中检查一层。
    private func legacyRepositoryRecords(in roots: [URL]) -> [Record] {
        let prefix = ".RepHub-migration-"
        return roots.flatMap { root -> [Record] in
            guard let children = try? FileManager.default.contentsOfDirectory(at: root.standardizedFileURL,
                                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                                               options: [.skipsPackageDescendants]) else { return [] }
            return children.compactMap { folder in
                let name = folder.lastPathComponent
                guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else { return nil }
                let checkpoint = folder.appendingPathComponent("checkpoint.json")
                guard FileManager.default.fileExists(atPath: checkpoint.path) else { return nil }
                let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
                return Record(id: id, kind: .repository, checkpointURL: checkpoint,
                              source: "旧新目录迁移检查点（需手动核验）", location: folder.path,
                              progress: "旧检查点，继续前将重新核验", updatedAt: values?.contentModificationDate ?? .distantPast)
            }
        }
    }
}
