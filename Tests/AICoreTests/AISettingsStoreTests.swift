import AICore
import AIApplication
import Foundation
import Testing

@MainActor
struct AISettingsStoreTests {
    @Test("连接 JSON 不包含 API 密钥，密钥只交给 SecretStore")
    func secretNeverAppearsInStoredJSON() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = AISettingsStore(secrets: secrets, defaults: defaults)
        let key = "repHub-test-secret-should-not-serialize"
        let connection = AIConnection(name: "本地模型", baseURL: "http://localhost:11434/v1", model: "test-model")

        try store.saveConnection(connection, apiKey: key)

        let stored = defaults.data(forKey: "rephub.ai.connections.v1")!
        #expect(!String(decoding: stored, as: UTF8.self).contains(key))
        #expect(try secrets.read(for: connection.id) == key)
        #expect(try store.hasSecret(for: connection.id))
    }

    @Test("删除连接会解除所有场景的默认连接引用并清除密钥")
    func deletingConnectionClearsSceneReferences() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = AISettingsStore(secrets: secrets, defaults: defaults)
        let connection = AIConnection(name: "API", baseURL: "https://example.com/v1", model: "test")
        try store.saveConnection(connection, apiKey: "secret")
        let scene = AIScene(name: "自定义审查", kind: .codeReview, prompt: "只审查", connectionID: connection.id)
        try store.saveScene(scene)

        try store.deleteConnection(id: connection.id)

        #expect(store.connections.isEmpty)
        #expect(store.scenes.first(where: { $0.id == scene.id })?.connectionID == nil)
        #expect(try secrets.read(for: connection.id) == nil)
    }

    @Test("删除所有场景后重建 Store 不会重新写入默认场景")
    func emptyScenesRemainEmptyAfterRestart() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let first = AISettingsStore(secrets: secrets, defaults: defaults)
        for scene in first.scenes { first.deleteScene(id: scene.id) }
        #expect(first.scenes.isEmpty)

        let restored = AISettingsStore(secrets: secrets, defaults: defaults)
        #expect(restored.scenes.isEmpty)
    }

    @Test("无效配置不会覆盖当前连接或写入密钥")
    func invalidConnectionDoesNotPretendToSave() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = AISettingsStore(secrets: secrets, defaults: defaults)
        let invalid = AIConnection(name: "", baseURL: "https://example.com/v1", model: "model")

        #expect(throws: AIError.self) {
            try store.saveConnection(invalid, apiKey: "should-not-save")
        }
        #expect(store.connections.isEmpty)
        #expect(try secrets.read(for: invalid.id) == nil)
    }

    @Test("钥匙串写入失败时不发布连接配置")
    func secretFailureDoesNotPublishConnection() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(secrets: FailingSecrets(), defaults: defaults)
        let connection = AIConnection(name: "API", baseURL: "https://example.com/v1", model: "test")

        #expect(throws: TestSecretError.self) {
            try store.saveConnection(connection, apiKey: "secret")
        }
        #expect(store.connections.isEmpty)
        #expect(defaults.data(forKey: "rephub.ai.connections.v1") == nil)
    }

    @Test("仅 localhost 可使用 HTTP，CLI 可留空模型和路径")
    func validatesConnectionKindsWithoutOverrestrictingCLI() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(secrets: MemorySecrets(), defaults: defaults)
        let remoteHTTP = AIConnection(name: "远端 HTTP", baseURL: "http://example.com/v1", model: "test")
        #expect(throws: AIError.self) { try store.saveConnection(remoteHTTP) }

        let cli = AIConnection(name: "Codex", kind: .codexCLI, timeoutSeconds: 30)
        try store.saveConnection(cli)
        #expect(store.connections.map(\.id) == [cli.id])
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "RepHub.AISettingsStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private final class MemorySecrets: AISecretStore, @unchecked Sendable {
    private var values: [UUID: String] = [:]

    func read(for connectionID: UUID) throws -> String? { values[connectionID] }
    func save(_ secret: String, for connectionID: UUID) throws { values[connectionID] = secret }
    func delete(for connectionID: UUID) throws { values.removeValue(forKey: connectionID) }
}

private enum TestSecretError: Error { case unavailable }

private struct FailingSecrets: AISecretStore {
    func read(for connectionID: UUID) throws -> String? { nil }
    func save(_ secret: String, for connectionID: UUID) throws { throw TestSecretError.unavailable }
    func delete(for connectionID: UUID) throws { throw TestSecretError.unavailable }
}
