import Foundation
import Testing
import RepositoryApplication

@Suite("迁移恢复索引")
struct MigrationResumeStoreTests {
    @Test("记录按迁移类型隔离，并且移除索引不会影响其他记录")
    func isolatesKindsAndRemovesOnlyIndex() throws {
        let suite = "RepHub.MigrationResumeStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-MigrationResumeStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigrationResumeStore(defaults: defaults, key: "test", legacyWorkingCopyRoot: root)
        let repositoryID = UUID(), workingCopyID = UUID()
        store.register(.init(id: repositoryID, kind: .repository,
                             checkpointURL: URL(fileURLWithPath: "/tmp/repository/checkpoint.json"),
                             source: "https://example.test/svn", location: "/tmp/result", progress: "已核对 1 / 2 条修订"))
        store.register(.init(id: workingCopyID, kind: .workingCopy,
                             checkpointURL: URL(fileURLWithPath: "/tmp/working-copy/checkpoint.json"),
                             source: "https://example.test/svn", location: "/tmp/working-copy", progress: "已核对 2 / 2 条修订"))
        #expect(store.records(kind: .repository).map(\.id) == [repositoryID])
        #expect(store.records(kind: .workingCopy).map(\.id) == [workingCopyID])
        store.remove(id: repositoryID, kind: .repository)
        #expect(store.records(kind: .repository).isEmpty)
        #expect(store.records(kind: .workingCopy).map(\.id) == [workingCopyID])
    }

    @Test("旧临时检查点只在指定目录一层发现，移除后不会重新出现")
    func discoversLegacyCheckpointAndHonorsRemoval() throws {
        let suite = "RepHub.MigrationResumeStoreLegacyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-MigrationResumeStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent("RepHub-working-copy-migration-\(id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ROOT-3.6.4.01-HO", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let checkpoint: [String: Any] = ["plan": ["workingCopyPath": source.path, "revisions": [1, 2]], "mappings": [1]]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: folder.appendingPathComponent("checkpoint.json"))
        let first = MigrationResumeStore(defaults: defaults, key: "test", legacyWorkingCopyRoot: root)
        #expect(first.records(kind: .workingCopy).map(\.id) == [id])
        #expect(first.records(kind: .workingCopy).first?.source.contains("ROOT-3.6.4.01-HO") == true)
        first.remove(id: id, kind: .workingCopy)
        let reopened = MigrationResumeStore(defaults: defaults, key: "test", legacyWorkingCopyRoot: root)
        #expect(reopened.records(kind: .workingCopy).isEmpty)
        first.register(.init(id: id, kind: .workingCopy, checkpointURL: folder.appendingPathComponent("checkpoint.json"),
                             source: "fixture", location: source.path, progress: "1/2"))
        #expect(reopened.records(kind: .workingCopy).map(\.id) == [id], "重新保存检查点会恢复条目")
        // 全新索引也不能把来源已被清理的测试夹具当作可继续迁移。
        try FileManager.default.removeItem(at: source)
        let fresh = MigrationResumeStore(defaults: defaults, key: "fresh", legacyWorkingCopyRoot: root)
        #expect(fresh.records(kind: .workingCopy).isEmpty)
    }

    @Test("目录选择会解析到其中的隐藏检查点")
    func resolvesSelectedDirectoryToCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(".RepHub-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MigrationResumeStore.checkpointURL(for: root) == root.appendingPathComponent("checkpoint.json"))
    }
}
