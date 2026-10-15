import Foundation
import RepositoryApplication
import Testing
import VersionControlCore

@Suite("远程仓库历史")
@MainActor
struct RemoteRepositoryHistoryStoreTests {
    @Test("地址按版本控制方式去重置顶，并在重启后恢复")
    func persistsAndDeduplicatesEntries() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let store = RemoteRepositoryHistoryStore(defaults: defaults)
        store.record(providerID: .git, url: "https://git.example.test/team/project.git")
        store.record(providerID: .svn, url: "https://svn.example.test:8443/repo/trunk")
        store.record(providerID: .git, url: "https://git.example.test/team/project.git")

        #expect(store.entries(for: .git).count == 1)
        #expect(store.entries.count == 2)
        let restored = RemoteRepositoryHistoryStore(defaults: defaults)
        #expect(Set(restored.entries.map(\.url)) == [
            "https://git.example.test/team/project.git",
            "https://svn.example.test:8443/repo/trunk"
        ])
    }

    @Test("敏感地址不会进入历史")
    func refusesSensitiveURLs() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let store = RemoteRepositoryHistoryStore(defaults: defaults)
        store.record(providerID: .git, url: "https://alice:secret@git.example.test/project.git")
        store.record(providerID: .git, url: "https://git.example.test/project.git?token=secret")
        store.record(providerID: .svn, url: "https://alice@svn.example.test/repo")
        store.record(providerID: .git, url: "https://git.example.test/line\nproject")

        #expect(store.entries.isEmpty)
    }

    @Test("Git SSH 与本地 file 地址可保存")
    func acceptsGitSSHAndFileURLs() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let store = RemoteRepositoryHistoryStore(defaults: defaults)
        store.record(providerID: .git, url: "git@Git.Example.test:team/project.git")
        store.record(providerID: .git, url: "ssh://git@git.example.test/team/project.git")
        store.record(providerID: .git, url: "file:///private/tmp/project.git")
        store.record(providerID: .git, url: "https://git.example.test/team/with space.git")

        #expect(store.entries(for: .git).map(\.url) == [
            "https://git.example.test/team/with%20space.git",
            "file:///private/tmp/project.git",
            "ssh://git@git.example.test/team/project.git",
            "git@git.example.test:team/project.git"
        ])
    }

    @Test("账号按服务端隔离，默认端口会归一")
    func separatesCredentialEndpointsAndRestoresMostRecentAccount() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let secrets = MemoryRepositoryCredentialStore()
        let store = RemoteRepositoryHistoryStore(defaults: defaults, secrets: secrets)
        try await store.remember(RepositoryCredentials(username: "first", password: "one"),
                                 for: "https://svn.example.test:443/a/trunk")
        try await store.remember(RepositoryCredentials(username: "second", password: "two"),
                                 for: "https://svn.example.test/b/branches")
        try await store.remember(RepositoryCredentials(username: "other", password: "three"),
                                 for: "https://svn.example.test:8443/a/trunk")

        #expect(store.accounts(for: "https://svn.example.test/anything").map(\.username) == ["second", "first"])
        #expect(store.accounts(for: "https://svn.example.test:8443/anything").map(\.username) == ["other"])
        let latest = try await store.credentials(for: "https://svn.example.test/repo")
        #expect(latest?.username == "second")
        #expect(latest?.password == "two")
        let first = try await store.credentials(for: "https://svn.example.test/repo", username: "first")
        #expect(first?.password == "one")
    }

    @Test("密码不进入偏好设置，安全存储失败不产生账号元数据")
    func neverPersistsPasswordsAndDoesNotPublishFailedSecrets() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let failing = FailingCredentialStore()
        let store = RemoteRepositoryHistoryStore(defaults: defaults, secrets: failing)
        await #expect(throws: TestError.self) {
            try await store.remember(RepositoryCredentials(username: "alice", password: "sensitive-password"),
                                     for: "https://svn.example.test/repo")
        }
        #expect(store.accounts.isEmpty)

        let secrets = MemoryRepositoryCredentialStore()
        let working = RemoteRepositoryHistoryStore(defaults: defaults, secrets: secrets)
        try await working.remember(RepositoryCredentials(username: "alice", password: "sensitive-password"),
                                   for: "https://svn.example.test/repo")
        let data = try #require(defaults.persistentDomain(forName: suite))
        #expect(String(describing: data).contains("sensitive-password") == false)
        let encoded = try JSONEncoder().encode(working.accounts)
        #expect(encoded.range(of: Data("sensitive-password".utf8)) == nil)
    }

    @Test("移除条目不会删除同服务端账号，移除账号会同步删除安全凭据")
    func removesSeparately() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let secrets = MemoryRepositoryCredentialStore()
        let store = RemoteRepositoryHistoryStore(defaults: defaults, secrets: secrets)
        let remote = "https://svn.example.test/repo"
        store.record(providerID: .svn, url: remote)
        try await store.remember(RepositoryCredentials(username: "alice", password: "secret"), for: remote)
        store.remove(try #require(store.entries.first))
        #expect(store.entries.isEmpty)
        #expect((try await store.credentials(for: remote))?.password == "secret")

        try await store.removeAccount(try #require(store.accounts.first))
        #expect(store.accounts.isEmpty)
        #expect(try await store.credentials(for: remote) == nil)
    }

    @Test("损坏和不安全的持久化元数据会在加载时剔除")
    func removesInvalidPersistedMetadata() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let now = Date()
        let entries = [
            RemoteRepositoryHistoryEntry(providerID: .git, url: "https://ok.example.test/project.git", lastUsedAt: now),
            RemoteRepositoryHistoryEntry(providerID: .git, url: "https://bad:password@example.test/project.git", lastUsedAt: now.addingTimeInterval(-1))
        ]
        let accounts = [
            SavedRepositoryAccount(server: "https://svn.example.test", username: "alice", lastUsedAt: now),
            SavedRepositoryAccount(server: "file:///private/tmp", username: "bad", lastUsedAt: now),
            SavedRepositoryAccount(server: "https://svn.example.test", username: "line\nfeed", lastUsedAt: now)
        ]
        defaults.set(try JSONEncoder().encode(entries), forKey: "rephub.remoteRepositoryHistory.entries.v1")
        defaults.set(try JSONEncoder().encode(accounts), forKey: "rephub.remoteRepositoryHistory.accounts.v1")

        let store = RemoteRepositoryHistoryStore(defaults: defaults)
        #expect(store.entries.map(\.url) == ["https://ok.example.test/project.git"])
        #expect(store.accounts.map(\.username) == ["alice"])
    }

    @Test("服务端地址只包含协议、主机和有效非默认端口")
    func normalizesCredentialServer() {
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "HTTPS://Svn.Example.Test:443/repo") == "https://svn.example.test")
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "https://svn.example.test:8443/repo") == "https://svn.example.test:8443")
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "https://[::1]:8443/repo") == "https://[::1]:8443")
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "https://[::1]:443/repo") == "https://[::1]")
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "file:///private/tmp/repo") == nil)
        #expect(RemoteRepositoryHistoryStore.credentialServer(for: "https://alice@svn.example.test/repo") == nil)
    }

    @Test("每种版本控制方式最多保存二十条地址")
    func limitsEntriesPerProvider() throws {
        let (defaults, suite) = try makeDefaults()
        defer { clear(defaults, suite) }
        let store = RemoteRepositoryHistoryStore(defaults: defaults)
        for index in 0..<22 {
            store.record(providerID: .git, url: "https://git.example.test/team/\(index).git")
        }
        store.record(providerID: .svn, url: "https://svn.example.test/repo")

        #expect(store.entries(for: .git).count == 20)
        #expect(store.entries(for: .git).first?.url.hasSuffix("21.git") == true)
        #expect(store.entries(for: .git).last?.url.hasSuffix("2.git") == true)
        #expect(store.entries(for: .svn).count == 1)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "rephub.remote.history.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileNoSuchFile) }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func clear(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }
}

private enum TestError: Error, Equatable { case rejected }

private actor FailingCredentialStore: RepositoryCredentialStore {
    func password(forServer server: String, username: String) async throws -> String? { nil }
    func save(_ credentials: RepositoryCredentials, forServer server: String) async throws { throw TestError.rejected }
    func remove(forServer server: String, username: String) async throws {}
}
