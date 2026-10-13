import Foundation

/// 已迁入 Git 的 SVN 工作副本在源端出现新修订时的只读检查结果。
public struct MigrationSourceUpdate: Sendable, Equatable, Identifiable {
    public var id: String { directory.standardizedFileURL.path + ":" + latestRevision }
    public let directory: URL
    public let sourceURL: String
    public let repositoryUUID: String
    public let migratedRevision: String
    public let latestRevision: String
    public let checkedAt: Date

    public init(directory: URL, sourceURL: String, repositoryUUID: String,
                migratedRevision: String, latestRevision: String, checkedAt: Date = Date()) {
        self.directory = directory
        self.sourceURL = sourceURL
        self.repositoryUUID = repositoryUUID
        self.migratedRevision = migratedRevision
        self.latestRevision = latestRevision
        self.checkedAt = checkedAt
    }
}

/// 没有记录、正在迁移和无法可靠比较都不会被伪装成“已是最新”。
public enum MigrationSourceUpdateCheck: Sendable, Equatable {
    case noMigrationRecord
    case skippedBusy
    case current(migratedRevision: String, checkedAt: Date)
    case update(MigrationSourceUpdate)
}
