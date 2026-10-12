import AICore
import AIApplication
import SwiftUI

/// 连接与场景配置只在用户显式保存时写入；检查只验证配置合法性，不发送代码和提示词，也不访问网络。
public struct AISettingsView: View {
    @Bindable private var store: AISettingsStore
    private let service: AIService
    @State private var editingConnection: AIConnection?
    @State private var editingScene: AIScene?
    @State private var message: Notice?

    public init(store: AISettingsStore, service: AIService) {
        self.store = store
        self.service = service
    }

    public var body: some View {
        Form {
            Section {
                if store.connections.isEmpty {
                    ContentUnavailableView("还没有 AI 连接", systemImage: "cpu", description: Text("添加模型 API、Codex CLI 或 Claude Code 后，场景才能运行。"))
                } else {
                    ForEach(store.connections) { connection in
                        connectionRow(connection)
                    }
                }
                Button("添加连接", systemImage: "plus") {
                    editingConnection = AIConnection()
                }
            } header: {
                Text("AI 连接")
            } footer: {
                Text("API 密钥仅保存在 macOS 钥匙串中。CLI 复用本机工具已有登录状态；留空路径时自动检测。")
            }

            Section {
                if store.scenes.isEmpty {
                    ContentUnavailableView("还没有场景", systemImage: "text.badge.plus", description: Text("创建一个提交说明或代码审查场景。"))
                } else {
                    ForEach(store.scenes) { scene in
                        sceneRow(scene)
                    }
                }
                Button("添加场景", systemImage: "plus") {
                    editingScene = AIScene(name: "新场景", kind: .commitMessage, prompt: "")
                }
            } header: {
                Text("AI 场景")
            } footer: {
                Text("场景提示词会和用户主动选择的差异一同发送；可不设置默认连接，在执行时再选择。")
            }

            if let loadError = store.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI 与场景")
        .sheet(item: $editingConnection) { connection in
            ConnectionEditor(store: store, service: service, connection: connection)
        }
        .sheet(item: $editingScene) { scene in
            SceneEditor(store: store, scene: scene)
        }
        .alert(item: $message) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private func connectionRow(_ connection: AIConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: connection.kind))
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(detail(for: connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("编辑") { editingConnection = connection }
                .buttonStyle(.borderless)
            Button("删除", role: .destructive) {
                do { try store.deleteConnection(id: connection.id) }
                catch { message = Notice(title: "无法删除连接", message: error.localizedDescription) }
            }
            .buttonStyle(.borderless)
        }
    }

    private func sceneRow(_ scene: AIScene) -> some View {
        HStack(spacing: 12) {
            Image(systemName: scene.kind == .commitMessage ? "text.append" : "checklist")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                Text(scene.kind.title + connectionSummary(scene.connectionID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("编辑") { editingScene = scene }
                .buttonStyle(.borderless)
            Button("删除", role: .destructive) { store.deleteScene(id: scene.id) }
                .buttonStyle(.borderless)
        }
    }

    private func detail(for connection: AIConnection) -> String {
        switch connection.kind {
        case .openAICompatible, .openAIResponses, .anthropicMessages:
            return connection.kind.title + " · " + connection.model + " · " + connection.baseURL
        case .codexCLI, .claudeCLI: return connection.executablePath.isEmpty ? "自动检测本机命令" : connection.executablePath
        }
    }

    private func connectionSummary(_ id: UUID?) -> String {
        guard let id else { return " · 执行时选择连接" }
        return " · " + (store.connections.first(where: { $0.id == id })?.name ?? "连接不可用")
    }

    private func icon(for kind: AIConnectionKind) -> String {
        switch kind {
        case .openAICompatible, .openAIResponses, .anthropicMessages: "network"
        case .codexCLI: "terminal"
        case .claudeCLI: "command"
        }
    }
}

private struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store: AISettingsStore
    private let service: AIService
    private let persistedConnection: AIConnection
    @State private var connection: AIConnection
    @State private var apiKey = ""
    @State private var isChecking = false
    @State private var notice: Notice?

    init(store: AISettingsStore, service: AIService, connection: AIConnection) {
        self.store = store
        self.service = service
        persistedConnection = connection
        _connection = State(initialValue: connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("连接") {
                    TextField("名称", text: $connection.name)
                    Picker("类型", selection: $connection.kind) {
                        ForEach(AIConnectionKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("超时（秒）", value: $connection.timeoutSeconds, format: .number)
                }
                if connection.kind.isAPI {
                    Section("模型 API") {
                        TextField("API 地址", text: $connection.baseURL, prompt: Text("https://api.example.com/v1"))
                        TextField("模型", text: $connection.model, prompt: Text("填写服务提供的模型标识"))
                        Text(apiDescription)
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("API 密钥", text: $apiKey, prompt: Text("留空则保持原密钥"))
                        if (try? store.hasSecret(for: connection.id)) == true {
                            HStack {
                                Text("此连接已有保存的密钥；留空不会覆盖。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("移除密钥", role: .destructive) { removeSecret() }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } else {
                    Section("本机命令") {
                        TextField("可执行文件路径", text: $connection.executablePath, prompt: Text("留空自动检测"))
                        TextField("模型（可选）", text: $connection.model, prompt: Text("留空使用 CLI 默认模型"))
                        Text("配置检查只查询版本与支持的参数，不会发送代码或调用模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("检查配置") { check() }
                    .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 445)
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private func save() {
        do {
            try store.saveConnection(connection, apiKey: apiKey.isEmpty ? nil : apiKey)
            dismiss()
        } catch {
            notice = Notice(title: "无法保存连接", message: error.localizedDescription)
        }
    }

    private var apiDescription: String {
        let endpoint: String
        switch connection.kind {
        case .openAICompatible: endpoint = "chat/completions"
        case .openAIResponses: endpoint = "responses"
        case .anthropicMessages: endpoint = "messages"
        case .codexCLI, .claudeCLI: return ""
        }
        return "填写服务基础地址（通常以 /v1 结尾）或完整 /\(endpoint) 地址。检查配置只校验格式，运行场景时才调用模型。"
    }

    private func check() {
        isChecking = true
        Task {
            do { notice = Notice(title: "配置可用", message: try await service.check(connection)) }
            catch { notice = Notice(title: "配置检查失败", message: error.localizedDescription) }
            isChecking = false
        }
    }

    private func removeSecret() {
        do {
            // 不连同尚未点击“保存”的表单修改一起写入，仅显式移除已有连接的密钥。
            try store.saveConnection(persistedConnection, apiKey: "")
            notice = Notice(title: "已移除密钥", message: "此连接下次执行时不会再使用原密钥。")
        } catch {
            notice = Notice(title: "无法移除密钥", message: error.localizedDescription)
        }
    }
}

private struct SceneEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store: AISettingsStore
    @State private var scene: AIScene
    @State private var notice: Notice?

    init(store: AISettingsStore, scene: AIScene) {
        self.store = store
        _scene = State(initialValue: scene)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("场景") {
                    TextField("名称", text: $scene.name)
                    Picker("用途", selection: $scene.kind) {
                        ForEach(AISceneKind.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("默认连接", selection: $scene.connectionID) {
                        Text("执行时选择").tag(UUID?.none)
                        ForEach(store.connections) { connection in
                            Text(connection.name).tag(Optional(connection.id))
                        }
                    }
                }
                Section("提示词") {
                    TextEditor(text: $scene.prompt)
                        .font(.body)
                        .frame(minHeight: 170)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 500)
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private func save() {
        do { try store.saveScene(scene); dismiss() }
        catch { notice = Notice(title: "无法保存场景", message: error.localizedDescription) }
    }
}

private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
