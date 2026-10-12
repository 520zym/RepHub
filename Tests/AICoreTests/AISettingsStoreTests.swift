import AICore
import AIApplication
import Foundation
import Testing

@MainActor
struct AISettingsStoreTests {
    @Test("旧连接 JSON 仍可解码，新 API 种类统一需要模型与地址")
    func connectionKindsRemainCodableAndValidateAsAPI() throws {
        let oldJSON = #"{"id":"00000000-0000-0000-0000-000000000001","name":"旧 Chat","kind":"openAICompatible","baseURL":"https://example.com/v1","model":"old","executablePath":"","timeoutSeconds":30}"#
        let old = try JSONDecoder().decode(AIConnection.self, from: Data(oldJSON.utf8))
        #expect(old.kind == .openAICompatible)
        #expect(AIConnectionKind.openAIResponses.isAPI)
        #expect(AIConnectionKind.anthropicMessages.isAPI)
        #expect(!AIConnectionKind.codexCLI.isAPI)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(secrets: MemorySecrets(), defaults: defaults)
        try store.saveConnection(.init(name: "Responses", kind: .openAIResponses, baseURL: "https://api.example/v1", model: "gpt"))
        try store.saveConnection(.init(name: "Messages", kind: .anthropicMessages, baseURL: "https://api.example/v1", model: "claude"))
        #expect(store.connections.count == 2)
    }
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

    @Test("场景固定模型必须绑定连接，删除连接后会一并清除")
    func sceneModelOverrideLifecycle() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(secrets: MemorySecrets(), defaults: defaults)
        let connection = AIConnection(name: "API", baseURL: "https://example.com/v1", model: "default")
        try store.saveConnection(connection)
        let scene = AIScene(name: "审查", kind: .codeReview, prompt: "审查", connectionID: connection.id, modelOverride: "  focused-model  ")
        try store.saveScene(scene)
        #expect(store.scenes.last?.modelOverride == "focused-model")
        try store.deleteConnection(id: connection.id)
        #expect(store.scenes.last?.connectionID == nil)
        #expect(store.scenes.last?.modelOverride == nil)
    }

    @Test("用量记录限制容量且不保存内容字段")
    func usageStorePersistsSafeBoundedRecords() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = AIUsageStore(defaults: defaults)
        let connectionID = UUID()
        let sceneID = UUID()
        for index in 0...(AIUsageStore.maximumRecords + 2) {
            usage.record(.init(date: Date(timeIntervalSince1970: TimeInterval(index)), connectionID: connectionID,
                               connectionName: "连接", sceneID: sceneID, sceneName: "场景", model: "model",
                               durationSeconds: 1, outcome: .succeeded,
                               usage: .init(inputTokens: index, outputTokens: 1)))
        }
        #expect(usage.records.count == AIUsageStore.maximumRecords)
        #expect(usage.records.first?.usage?.inputTokens == AIUsageStore.maximumRecords + 2)
        let raw = String(decoding: defaults.data(forKey: "rephub.ai.usage.v1")!, as: UTF8.self)
        #expect(!raw.contains("prompt"))
        #expect(!raw.contains("/private/repository"))
    }

    @Test("保留旧密钥时不能将它带到新的服务主机")
    func changingServiceHostRequiresNewKeyButChangingPathDoesNot() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = AISettingsStore(secrets: secrets, defaults: defaults)
        let old = AIConnection(name: "旧服务", baseURL: "https://old.example/v1", model: "model")
        try store.saveConnection(old, apiKey: "old-key")

        var sameHost = old
        sameHost.baseURL = "https://old.example/v2"
        try store.saveConnection(sameHost)
        #expect(store.connections.count == 1)
        #expect(store.connections.first?.baseURL == "https://old.example/v2")
        #expect(try store.hasSecret(for: old.id))

        var newHost = sameHost
        newHost.baseURL = "https://new.example/v1"
        do {
            try store.saveConnection(newHost)
            Issue.record("切换主机且未填写密钥时必须拒绝保存")
        } catch {
            #expect(error.localizedDescription == "更换服务地址后请填写新密钥，或先移除原密钥。")
        }
        #expect(store.connections.first?.baseURL == "https://old.example/v2")
        #expect(try store.hasSecret(for: old.id))
    }

    @Test("带有旧密钥的命令行连接改为 API 时需要新密钥")
    func changingCLIConnectionToAPIRequiresNewKey() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(secrets: MemorySecrets(), defaults: defaults)
        let cli = AIConnection(name: "本地命令", kind: .codexCLI, timeoutSeconds: 30)
        try store.saveConnection(cli, apiKey: "legacy-secret")
        var api = cli
        api.kind = .openAICompatible
        api.baseURL = "https://api.example/v1"
        api.model = "model"
        #expect(throws: AIError.self) { try store.saveConnection(api) }
        #expect(store.connections.count == 1)
        #expect(store.connections.first?.kind == .codexCLI)
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
