import AICore
import Foundation
import Observation

/// AI 连接与场景的本地配置。密钥只由 `AISecretStore` 保存，永不进入 UserDefaults。
@MainActor
@Observable
public final class AISettingsStore {
    private enum StorageKey {
        static let connections = "rephub.ai.connections.v1"
        static let scenes = "rephub.ai.scenes.v1"
    }

    private let secrets: any AISecretStore
    private let defaults: UserDefaults

    public private(set) var connections: [AIConnection]
    public private(set) var scenes: [AIScene]
    public private(set) var loadError: String?

    public init(secrets: any AISecretStore, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
        loadError = nil

        let loadedConnections = Self.load([AIConnection].self, key: StorageKey.connections, from: defaults)
        let loadedScenes = Self.load([AIScene].self, key: StorageKey.scenes, from: defaults)

        connections = loadedConnections.value ?? []
        if let savedScenes = loadedScenes.value {
            // 空数组是用户主动删除全部场景后的有效配置，不能在下次启动时重新写入默认值。
            scenes = savedScenes
        } else {
            scenes = AIScene.defaults
            if loadedScenes.error == nil {
                // 首次使用时提供两个可编辑的默认场景；写入失败不妨碍使用，但要可见。
                do { try Self.persist(scenes, key: StorageKey.scenes, to: defaults) }
                catch { loadError = "无法保存默认 AI 场景：\(Self.message(for: error))" }
            }
        }

        let errors = [loadedConnections.error, loadedScenes.error].compactMap { $0 }
        if !errors.isEmpty {
            loadError = "无法读取 AI 配置：\(errors.joined(separator: "；"))"
        }
    }

    /// 保存连接。`nil` 保留原有密钥，空字符串删除密钥；配置 JSON 始终不包含密钥。
    public func saveConnection(_ value: AIConnection, apiKey: String? = nil) throws {
        let connection = normalized(value)
        try validate(connection)

        if let previous = connections.first(where: { $0.id == connection.id }),
           apiKey == nil,
           try hasSecret(for: connection.id),
           requiresNewSecret(previous: previous, replacement: connection) {
            throw AIError.invalidConfiguration("更换服务地址后请填写新密钥，或先移除原密钥。")
        }

        var next = connections
        if let index = next.firstIndex(where: { $0.id == connection.id }) {
            next[index] = connection
        } else {
            next.append(connection)
        }
        let encoded = try Self.encode(next)

        // 先完成可能失败的钥匙串操作；失败时内存与 JSON 都保持原状。
        if let apiKey {
            if apiKey.isEmpty { try secrets.delete(for: connection.id) }
            else { try secrets.save(apiKey, for: connection.id) }
        }
        defaults.set(encoded, forKey: StorageKey.connections)
        connections = next
        loadError = nil
    }

    /// 删除连接，同时解除所有引用这个连接的场景。
    public func deleteConnection(id: UUID) throws {
        guard connections.contains(where: { $0.id == id }) else { return }
        let nextConnections = connections.filter { $0.id != id }
        let nextScenes = scenes.map { scene in
            var copy = scene
            if copy.connectionID == id {
                copy.connectionID = nil
                copy.modelOverride = nil
            }
            return copy
        }
        let connectionsData = try Self.encode(nextConnections)
        let scenesData = try Self.encode(nextScenes)

        try secrets.delete(for: id)
        defaults.set(connectionsData, forKey: StorageKey.connections)
        defaults.set(scenesData, forKey: StorageKey.scenes)
        connections = nextConnections
        scenes = nextScenes
        loadError = nil
    }

    public func saveScene(_ value: AIScene) throws {
        let scene = normalized(value)
        try validate(scene)
        if let connectionID = scene.connectionID,
           !connections.contains(where: { $0.id == connectionID }) {
            throw AIError.invalidConfiguration("所选默认连接已不存在，请重新选择。")
        }

        var next = scenes
        if let index = next.firstIndex(where: { $0.id == scene.id }) { next[index] = scene }
        else { next.append(scene) }
        let encoded = try Self.encode(next)
        defaults.set(encoded, forKey: StorageKey.scenes)
        scenes = next
        loadError = nil
    }

    public func deleteScene(id: UUID) {
        let next = scenes.filter { $0.id != id }
        // 编码 AIScene 不会失败；若系统未来扩展为可能失败的格式，保留当前内存更安全。
        guard let data = try? Self.encode(next) else {
            loadError = "无法保存 AI 场景。"
            return
        }
        defaults.set(data, forKey: StorageKey.scenes)
        scenes = next
        loadError = nil
    }

    public func hasSecret(for connectionID: UUID) throws -> Bool {
        try secrets.read(for: connectionID) != nil
    }

    private func validate(_ connection: AIConnection) throws {
        guard !connection.name.isEmpty else { throw AIError.invalidConfiguration("请填写连接名称。") }
        guard connection.timeoutSeconds.isFinite,
              (10...1_800).contains(connection.timeoutSeconds) else {
            throw AIError.invalidConfiguration("超时时间需在 10 秒至 1800 秒之间。")
        }
        guard connection.kind.isAPI else { return }
        guard !connection.model.isEmpty else { throw AIError.invalidConfiguration("模型 API 连接需要填写模型名称。") }
        guard !connection.baseURL.isEmpty,
              let components = URLComponents(string: connection.baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["https", "http"].contains(scheme) else {
            throw AIError.invalidConfiguration("请填写有效的模型 API 地址，不能包含账号、查询参数或片段。")
        }
        if scheme == "http", !Self.isLoopback(host) {
            throw AIError.invalidConfiguration("非本机模型 API 必须使用 HTTPS；localhost 可使用 HTTP。")
        }
    }

    private func validate(_ scene: AIScene) throws {
        guard !scene.name.isEmpty else { throw AIError.invalidConfiguration("请填写场景名称。") }
        guard !scene.prompt.isEmpty else { throw AIError.invalidConfiguration("请填写场景提示词。") }
        if scene.modelOverride != nil, scene.connectionID == nil {
            throw AIError.invalidConfiguration("指定场景模型前，请先选择默认连接。")
        }
    }

    private func normalized(_ connection: AIConnection) -> AIConnection {
        var result = connection
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.executablePath = result.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private func normalized(_ scene: AIScene) -> AIScene {
        var result = scene
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.prompt = result.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        result.modelOverride = result.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.modelOverride?.isEmpty == true { result.modelOverride = nil }
        return result
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return lower == "localhost" || lower == "::1" || lower == "127.0.0.1"
    }

    /// 密钥与服务地址绑定。只允许同一主机调整 API 路径，以免把旧服务的密钥发送给新主机。
    private func requiresNewSecret(previous: AIConnection, replacement: AIConnection) -> Bool {
        guard replacement.kind.isAPI else { return false }
        guard previous.kind.isAPI else { return true }
        let previousHost = URLComponents(string: previous.baseURL)?.host?.lowercased()
        let replacementHost = URLComponents(string: replacement.baseURL)?.host?.lowercased()
        return previousHost != replacementHost
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> (value: T?, error: String?) {
        guard let data = defaults.data(forKey: key) else { return (nil, nil) }
        do { return (try JSONDecoder().decode(type, from: data), nil) }
        catch { return (nil, message(for: error)) }
    }

    private static func persist<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults) throws {
        defaults.set(try encode(value), forKey: key)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
