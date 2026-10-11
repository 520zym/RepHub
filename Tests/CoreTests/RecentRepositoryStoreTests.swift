import Foundation
import RepositoryApplication
import Testing
import VersionControlCore

@Suite("最近打开仓库")
@MainActor
struct RecentRepositoryStoreTests {
    @Test("重启后恢复最近仓库，并保留绑定名称")
    func restoresAfterRestart() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let directory = URL(fileURLWithPath: "/private/tmp/rephub-recent-restore", isDirectory: true)
        let workspace = managedWorkspace(at: directory, names: ["Git", "SVN"])

        let first = RecentRepositoryStore(defaults: defaults)
        first.record(workspace)
        let restored = RecentRepositoryStore(defaults: defaults)

        #expect(restored.entries.count == 1)
        #expect(restored.entries[0].path == directory.path)
        #expect(restored.entries[0].providerNames == ["Git", "SVN"])
    }

    @Test("重复打开置顶且不会重复")
    func duplicateMovesToFront() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let store = RecentRepositoryStore(defaults: defaults)
        let first = managedWorkspace(at: URL(fileURLWithPath: "/private/tmp/rephub-recent-first", isDirectory: true))
        let second = managedWorkspace(at: URL(fileURLWithPath: "/private/tmp/rephub-recent-second", isDirectory: true))

        store.record(first)
        store.record(second)
        store.record(first)

        #expect(store.entries.map(\.path) == [first.directory.path, second.directory.path])
    }

    @Test("最多保留二十个仓库")
    func limitsEntries() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let store = RecentRepositoryStore(defaults: defaults)
        for index in 0..<22 {
            store.record(managedWorkspace(at: URL(fileURLWithPath: "/private/tmp/rephub-recent-limit-\(index)", isDirectory: true)))
        }

        #expect(store.entries.count == 20)
        #expect(store.entries.first?.path.hasSuffix("rephub-recent-limit-21") == true)
        #expect(store.entries.last?.path.hasSuffix("rephub-recent-limit-2") == true)
    }

    @Test("可移除单条并清空持久化")
    func removesAndClears() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let store = RecentRepositoryStore(defaults: defaults)
        let first = managedWorkspace(at: URL(fileURLWithPath: "/private/tmp/rephub-recent-remove-first", isDirectory: true))
        let second = managedWorkspace(at: URL(fileURLWithPath: "/private/tmp/rephub-recent-remove-second", isDirectory: true))
        store.record(first)
        store.record(second)

        store.remove(store.entries[0])
        #expect(store.entries.map(\.path) == [first.directory.path])
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(RecentRepositoryStore(defaults: defaults).entries.isEmpty)
    }

    @Test("未受管控文件夹不进入历史")
    func unmanagedWorkspaceIsNotRecorded() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let store = RecentRepositoryStore(defaults: defaults)
        store.record(Workspace(directory: URL(fileURLWithPath: "/private/tmp/rephub-recent-unmanaged", isDirectory: true), bindings: [], issues: []))
        #expect(store.entries.isEmpty)
    }

    @Test("符号链接路径与真实路径合并为同一条")
    func deduplicatesSymbolicLinks() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-recent-link-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentRepositoryStore(defaults: defaults)

        store.record(managedWorkspace(at: real))
        store.record(managedWorkspace(at: link))

        #expect(store.entries.count == 1)
        #expect(store.entries[0].path == real.resolvingSymlinksInPath().path)
    }

    @Test("损坏持久化安全回退为空")
    func corruptedPersistenceFallsBackSafely() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        defaults.set(Data("not json".utf8), forKey: "rephub.recentRepositories.v1")
        #expect(RecentRepositoryStore(defaults: defaults).entries.isEmpty)
    }

    @Test("持久化中的相对路径和网址不会被当成本地仓库")
    func invalidPersistedPathsAreFiltered() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite: suite) }
        let now = Date()
        let values = [
            RecentRepository(path: "relative/repository", name: "relative", providerNames: ["Git"], lastOpenedAt: now),
            RecentRepository(path: "https://example.invalid/repository", name: "remote", providerNames: ["Git"], lastOpenedAt: now),
            RecentRepository(path: "/private/tmp/rephub-recent-valid", name: "valid", providerNames: ["SVN"], lastOpenedAt: now)
        ]
        defaults.set(try JSONEncoder().encode(values), forKey: "rephub.recentRepositories.v1")

        let store = RecentRepositoryStore(defaults: defaults)
        #expect(store.entries.map(\.path) == ["/private/tmp/rephub-recent-valid"])
    }

    private func managedWorkspace(at directory: URL, names: [String] = ["Git"]) -> Workspace {
        let bindings = names.enumerated().map { index, name in
            RepositoryBinding(
                providerID: ProviderID(rawValue: "test-\(index)"),
                providerName: name,
                root: directory,
                capabilities: [.status]
            )
        }
        return Workspace(directory: directory, bindings: bindings, issues: [])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "rephub.recent.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileNoSuchFile) }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func clear(_ defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }
}
