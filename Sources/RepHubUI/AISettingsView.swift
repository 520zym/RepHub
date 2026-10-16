import AICore
import AIApplication
import SwiftUI

/// 密钥由设置存储在 macOS 钥匙串中；模型目录与本机用量统计不包含密钥、提示词或代码内容。
public struct AISettingsView: View {
    @Bindable private var store: AISettingsStore
    private let service: AIService
    private let usageStore: AIUsageStore?
    @State private var editingConnection: AIConnection?
    @State private var editingScene: AIScene?
    @State private var message: Notice?
    @State private var confirmsUsageClear = false

    public init(store: AISettingsStore, service: AIService, usageStore: AIUsageStore? = nil) {
        self.store = store
        self.service = service
        self.usageStore = usageStore
    }

    public var body: some View {
        Form {
            Section {
                if store.connections.isEmpty {
                    ContentUnavailableView("还没有 AI 连接", systemImage: "cpu", description: Text("添加模型 API、Codex CLI 或 Claude Code 后，场景才能运行。"))
                } else {
                    ForEach(store.connections) { connection in connectionRow(connection) }
                }
                Button("添加连接", systemImage: "plus") { editingConnection = AIConnection() }
            } header: {
                Text("AI 连接")
            } footer: {
                Text("内置 DeepSeek、Kimi、MiniMax、GLM 预设。API 密钥仅保存在 macOS 钥匙串中。")
            }

            Section {
                if store.scenes.isEmpty {
                    ContentUnavailableView("还没有场景", systemImage: "text.badge.plus", description: Text("创建一个提交说明或代码审查场景。"))
                } else {
                    ForEach(store.scenes) { scene in sceneRow(scene) }
                }
                Button("添加场景", systemImage: "plus") { editingScene = AIScene(name: "新场景", kind: .commitMessage, prompt: "") }
            } header: {
                Text("AI 场景")
            } footer: {
                Text("场景可继承连接默认模型，或固定使用该连接中的某一个模型。")
            }

            if let usageStore { usageSection(usageStore) }
            if let loadError = store.loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI 与场景")
        .sheet(item: $editingConnection) { ConnectionEditor(store: store, service: service, connection: $0) }
        .sheet(item: $editingScene) { SceneEditor(store: store, scene: $0) }
        .alert(item: $message) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("好"))) }
        .confirmationDialog("清空用量统计？", isPresented: $confirmsUsageClear, titleVisibility: .visible) {
            Button("清空统计", role: .destructive) { usageStore?.clear() }
        } message: { Text("这只会删除本机保存的用量统计，不会影响连接、密钥或场景。") }
    }

    private func connectionRow(_ connection: AIConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: connection.kind)).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(detail(for: connection)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("编辑") { editingConnection = connection }.buttonStyle(.borderless)
            Button("删除", role: .destructive) {
                do { try store.deleteConnection(id: connection.id) }
                catch { message = Notice(title: "无法删除连接", message: error.localizedDescription) }
            }.buttonStyle(.borderless)
        }
    }

    private func sceneRow(_ scene: AIScene) -> some View {
        HStack(spacing: 12) {
            Image(systemName: scene.kind == .commitMessage ? "text.append" : "checklist").foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                Text(scene.kind.title + connectionSummary(scene)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("编辑") { editingScene = scene }.buttonStyle(.borderless)
            Button("删除", role: .destructive) { store.deleteScene(id: scene.id) }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder private func usageSection(_ usageStore: AIUsageStore) -> some View {
        let records = usageStore.records
        let reported = records.compactMap(\.usage).filter(\.hasReportedTokens)
        let input = tokenSum(reported.compactMap(\.inputTokens))
        let output = tokenSum(reported.compactMap(\.outputTokens))
        let total = tokenSum(reported.compactMap(\.totalTokens))
        Section {
            if records.isEmpty {
                Text("尚无本机执行记录").foregroundStyle(.secondary)
            } else {
                LabeledContent("已记录执行") { Text("\(records.count) 次") }
                LabeledContent("服务返回用量") { Text("\(reported.count) / \(records.count) 次") }
                if let input { LabeledContent("已报告输入") { Text(input.formatted()) } }
                if let output { LabeledContent("已报告输出") { Text(output.formatted()) } }
                if let total { LabeledContent("已报告合计") { Text(total.formatted()) } }
                Text((records.contains { $0.usage?.inputTokens == nil || $0.usage?.outputTokens == nil || $0.usage?.totalTokens == nil }
                      ? "部分请求未返回完整用量。" : "") + "缓存 Token 已包含在输入 Token 中，不会重复相加；未报告的字段标记为“未返回”。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空本机统计", role: .destructive) { confirmsUsageClear = true }
                ForEach(records.prefix(10)) { record in
                    usageRecordRow(record)
                }
                if records.count > 10 {
                    DisclosureGroup("查看其余 \(records.count - 10) 条记录") {
                        ForEach(Array(records.dropFirst(10))) { record in usageRecordRow(record) }
                    }
                }
            }
        } header: {
            Text("Token 用量")
        } footer: { Text("统计仅保留最近 1000 次执行记录，不进行价格估算。") }
    }

    private func usageRecordRow(_ record: AIUsageRecord) -> some View {
        DisclosureGroup {
            LabeledContent("执行结果") { Text(outcomeTitle(record.outcome)) }
            if let usage = record.usage, usage.hasReportedTokens {
                if let input = usage.inputTokens { LabeledContent("输入") { Text(input.formatted()) } }
                if let output = usage.outputTokens { LabeledContent("输出") { Text(output.formatted()) } }
                if let total = usage.totalTokens { LabeledContent("合计") { Text(total.formatted()) } }
                if let cached = usage.cachedInputTokens { LabeledContent("缓存读取（已含于输入）") { Text(cached.formatted()) } }
                if let created = usage.cacheCreationInputTokens { LabeledContent("缓存写入（已含于输入）") { Text(created.formatted()) } }
                if let reasoning = usage.reasoningTokens { LabeledContent("推理（已含于输出）") { Text(reasoning.formatted()) } }
            } else {
                Text("本次服务没有返回 Token 用量。").foregroundStyle(.secondary)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: outcomeIcon(record.outcome)).foregroundStyle(outcomeColor(record.outcome)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sceneName + " · " + record.model).lineLimit(1)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let usage = record.usage, usage.hasReportedTokens {
                Text(usageSummary(usage)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("未返回").font(.caption).foregroundStyle(.secondary)
            }
            }
        }
    }

    private func usageSummary(_ usage: AITokenUsage) -> String {
        if let total = usage.totalTokens { return "总 \(total.formatted())" }
        let pieces = [("入", usage.inputTokens), ("出", usage.outputTokens)].compactMap { label, value in value.map { "\(label) \($0.formatted())" } }
        return pieces.isEmpty ? "已报告部分" : pieces.joined(separator: " · ")
    }

    private func tokenSum(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var result = 0
        for value in values {
            let sum = result.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }

    private func outcomeIcon(_ outcome: AIUsageOutcome) -> String {
        switch outcome { case .succeeded: "checkmark.circle.fill"; case .failed: "exclamationmark.circle.fill"; case .cancelled: "xmark.circle.fill" }
    }

    private func outcomeColor(_ outcome: AIUsageOutcome) -> Color {
        switch outcome { case .succeeded: .green; case .failed: .orange; case .cancelled: .secondary }
    }

    private func outcomeTitle(_ outcome: AIUsageOutcome) -> String {
        switch outcome { case .succeeded: "完成"; case .failed: "失败"; case .cancelled: "已取消" }
    }

    private func detail(for connection: AIConnection) -> String {
        switch connection.kind {
        case .openAICompatible, .openAIResponses, .anthropicMessages:
            return [connection.preset?.title ?? connection.kind.title, connection.model,
                    connection.modelCatalog?.source == .remote ? "已发现模型" : nil].compactMap { $0 }.joined(separator: " · ")
        case .codexCLI, .claudeCLI: return connection.executablePath.isEmpty ? "自动检测本机命令" : connection.executablePath
        }
    }

    private func connectionSummary(_ scene: AIScene) -> String {
        guard let id = scene.connectionID else { return " · 执行时选择连接" }
        guard let connection = store.connections.first(where: { $0.id == id }) else { return " · 连接不可用" }
        return " · \(connection.name)" + (scene.modelOverride.map { " · \($0)" } ?? " · 继承 \(connection.model)")
    }

    private func icon(for kind: AIConnectionKind) -> String {
        switch kind { case .openAICompatible, .openAIResponses, .anthropicMessages: "network"; case .codexCLI: "terminal"; case .claudeCLI: "command" }
    }
}

private struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store: AISettingsStore
    private let service: AIService
    private let persistedConnection: AIConnection
    @State private var connection: AIConnection
    @State private var apiKey = ""
    @State private var isDiscovering = false
    @State private var isChecking = false
    @State private var discoveryFailed = false
    @State private var showAdvanced = false
    @State private var notice: Notice?
    @State private var discoveryTask: Task<Void, Never>?
    @State private var checkTask: Task<Void, Never>?

    init(store: AISettingsStore, service: AIService, connection: AIConnection) {
        self.store = store; self.service = service; persistedConnection = connection; _connection = State(initialValue: connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                    Section {
                        Picker("内置厂商", selection: $connection.preset) {
                            Text("自定义 API / CLI").tag(AIProviderPreset?.none)
                            ForEach(AIProviderPreset.allCases) { Text($0.title).tag(Optional($0)) }
                        }.onChange(of: connection.preset) { _, preset in apply(preset) }
                        TextField("名称", text: $connection.name)
                        Picker("类型", selection: $connection.kind) {
                            ForEach(AIConnectionKind.allCases) { Text($0.title).tag($0) }
                        }
                        .onChange(of: connection.kind) { previous, kind in
                            if kind != .openAICompatible { connection.preset = nil; connection.modelCatalog = nil }
                            if previous.isAPI && !kind.isAPI { connection.model = "" }
                        }
                    } header: {
                        Text("连接")
                    }
                    if connection.kind.isAPI { apiSettings } else { cliSettings }
            }.formStyle(.grouped).disabled(isDiscovering)
            Divider()
            HStack {
                Button("检查配置") { check() }.disabled(isChecking || isDiscovering)
                if isDiscovering || isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { cancelTasks(); dismiss() }
                if discoveryFailed {
                    Button("仅保存手动配置") { save(connection) }.disabled(isDiscovering || isChecking)
                }
                Button("保存") { primarySave() }.keyboardShortcut(.defaultAction).disabled(isDiscovering || isChecking)
            }.padding()
        }
        .workbenchSheet(minWidth: 540, idealWidth: 620, minHeight: 500, idealHeight: 640)
        .onDisappear { cancelTasks() }
        .alert(item: $notice) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("好"))) }
    }

    @ViewBuilder private var apiSettings: some View {
        Section {
            SecureField("API 密钥", text: $apiKey, prompt: Text("留空则保持原密钥"))
                .onChange(of: apiKey) { _, _ in connection.modelCatalog = nil }
            keyStatus
            modelSettings
            if connection.preset == .glm {
                Text("GLM 使用官方预设模型。暂未找到官方公开的模型列表接口，因此不会以“自动检测”或密钥校验方式显示。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if canDiscoverModels {
                Text(connection.preset?.supportsModelDiscovery == true
                     ? "保存时自动读取模型列表，也可手动刷新。读取失败后仍可保存手动配置。"
                     : "点击“读取模型列表”可查询服务提供的模型；也可直接填写模型标识并保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("模型 API")
        }
        DisclosureGroup("高级连接设置", isExpanded: $showAdvanced) {
            TextField("API 地址", text: $connection.baseURL, prompt: Text("https://api.example.com/v1"))
                .onChange(of: connection.baseURL) { _, _ in connection.modelCatalog = nil }
            TextField("超时（秒）", value: $connection.timeoutSeconds, format: .number)
            Text(apiDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyStatus: some View {
        if (try? store.hasSecret(for: connection.id)) == true, canReuseStoredKey {
            HStack { Text("此连接已有保存的密钥；留空不会覆盖。").font(.caption).foregroundStyle(.secondary); Spacer()
                Button("移除密钥", role: .destructive) { removeSecret() }.buttonStyle(.borderless) }
        } else if (try? store.hasSecret(for: connection.id)) == true {
            Text("已保存的密钥仅属于原连接地址；更换厂商或地址后不会自动发送它，请重新输入新密钥。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var modelSettings: some View {
        let models = pickerModels
        if !models.isEmpty { Picker("模型", selection: $connection.model) { ForEach(models) { Text($0.name ?? $0.id).tag($0.id) } } }
        TextField("模型标识", text: $connection.model, prompt: Text("可手动填写服务提供的模型标识"))
        if canDiscoverModels {
            Button("读取模型列表") { discoverModels() }.disabled(isDiscovering || isChecking)
        } else if connection.preset == .glm {
            Button("查看官方预设") {
                connection.modelCatalog = AIModelCatalog(models: AIProviderPreset.glm.fallbackModels, source: .officialPreset,
                                                        note: "暂未找到官方公开的模型列表接口")
            }
        }
        if let catalog = connection.modelCatalog { Text(catalogDescription(catalog)).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var cliSettings: some View {
        Section {
            TextField("可执行文件路径", text: $connection.executablePath, prompt: Text("留空自动检测"))
            TextField("模型（可选）", text: $connection.model, prompt: Text("留空使用 CLI 默认模型"))
            TextField("超时（秒）", value: $connection.timeoutSeconds, format: .number)
            Text("CLI 复用本机已有登录状态；不会保存命令行工具的密钥。").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("本机命令")
        }
    }

    private var availableModels: [AIModelDescriptor] { let found = connection.modelCatalog?.models ?? []; return found.isEmpty ? (connection.preset?.fallbackModels ?? []) : found }
    private var pickerModels: [AIModelDescriptor] {
        let models = availableModels
        return models.contains(where: { $0.id == connection.model }) || connection.model.isEmpty
            ? models : [AIModelDescriptor(id: connection.model, name: "当前手动模型：\(connection.model)")] + models
    }
    private var canReuseStoredKey: Bool {
        persistedConnection.kind == connection.kind && persistedConnection.baseURL == connection.baseURL && persistedConnection.preset == connection.preset
    }
    private var canDiscoverModels: Bool {
        connection.preset != .glm && (connection.kind == .openAICompatible || connection.kind == .openAIResponses)
    }
    private func apply(_ preset: AIProviderPreset?) {
        guard let preset else { return }
        connection.kind = .openAICompatible; connection.name = preset.title; connection.baseURL = preset.baseURL; connection.model = preset.defaultModel; connection.modelCatalog = nil; showAdvanced = false
    }
    private func primarySave() {
        if connection.preset == .glm {
            connection.modelCatalog = AIModelCatalog(models: AIProviderPreset.glm.fallbackModels, source: .officialPreset,
                                                     note: "暂未找到官方公开的模型列表接口")
            save(connection)
        } else if connection.preset?.supportsModelDiscovery == true, canDiscoverModels,
                  !apiKey.isEmpty || canReuseStoredKey && (try? store.hasSecret(for: connection.id)) == true || isLocalhost(connection.baseURL) {
            discoverModels(saveAfterDiscovery: true)
        } else {
            save(connection)
        }
    }
    private func discoverModels(saveAfterDiscovery: Bool = false) {
        guard canDiscoverModels else {
            notice = Notice(title: "此连接不支持读取模型列表", message: "请手动填写模型标识；GLM 会提供官方预设模型。")
            return
        }
        let snapshot = connection
        // nil 才会要求业务层读取已存密钥；换地址的本机无密钥服务必须传空串。
        let draftKey: String? = apiKey.isEmpty ? (canReuseStoredKey ? nil : "") : apiKey
        guard !apiKey.isEmpty || canReuseStoredKey || isLocalhost(snapshot.baseURL) else {
            notice = Notice(title: "需要 API 密钥", message: "当前地址没有可复用的已保存密钥，请输入密钥后再读取模型列表。")
            return
        }
        discoveryTask?.cancel(); isDiscovering = true; discoveryFailed = false
        discoveryTask = Task { do {
            let catalog = try await service.discoverModels(for: snapshot, apiKey: draftKey)
            guard !Task.isCancelled, sameEndpoint(snapshot, connection) else { return }
            connection.modelCatalog = catalog
            if !catalog.models.contains(where: { $0.id == connection.model }), let first = catalog.models.first { connection.model = first.id }
            if saveAfterDiscovery { save(connection) } else { notice = Notice(title: "模型列表已更新", message: catalogDescription(catalog)) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            discoveryFailed = true
            notice = Notice(title: "无法读取模型列表", message: "\(error.localizedDescription)\n\n不会把这次失败当作检测成功；可选择“仅保存手动配置”。")
        }
        isDiscovering = false; discoveryTask = nil }
    }
    private func save(_ value: AIConnection) { do { try store.saveConnection(value, apiKey: apiKey.isEmpty ? nil : apiKey); dismiss() } catch { notice = Notice(title: "无法保存连接", message: error.localizedDescription) } }
    private func check() {
        isChecking = true
        let snapshot = connection
        checkTask?.cancel()
        checkTask = Task { do { notice = Notice(title: "配置格式可用", message: try await service.check(snapshot)) }
        catch { notice = Notice(title: "配置检查失败", message: error.localizedDescription) }
        isChecking = false; checkTask = nil }
    }
    private func sameEndpoint(_ lhs: AIConnection, _ rhs: AIConnection) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.baseURL == rhs.baseURL && lhs.preset == rhs.preset
    }
    private func isLocalhost(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
    private func cancelTasks() { discoveryTask?.cancel(); checkTask?.cancel() }
    private func catalogDescription(_ catalog: AIModelCatalog) -> String { let source = catalog.source == .remote ? "已从服务读取" : "官方预设"; return "\(source) \(catalog.models.count) 个模型" + (catalog.note.map { " · \($0)" } ?? "") }
    private var apiDescription: String { switch connection.kind { case .openAICompatible: return "填写服务基础地址（通常以 /v1 结尾）或完整 /chat/completions 地址。"; case .openAIResponses: return "填写服务基础地址或完整 /responses 地址。"; case .anthropicMessages: return "填写服务基础地址或完整 /messages 地址。"; case .codexCLI, .claudeCLI: return "" } }
    private func removeSecret() { do { try store.saveConnection(persistedConnection, apiKey: ""); notice = Notice(title: "已移除密钥", message: "此连接下次执行时不会再使用原密钥。") } catch { notice = Notice(title: "无法移除密钥", message: error.localizedDescription) } }
}

private struct SceneEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store: AISettingsStore
    @State private var scene: AIScene
    @State private var useCustomModel = false
    @State private var notice: Notice?
    init(store: AISettingsStore, scene: AIScene) {
        self.store = store
        _scene = State(initialValue: scene)
        let connection = scene.connectionID.flatMap { id in store.connections.first(where: { $0.id == id }) }
        let models: [AIModelDescriptor] = connection.map { value in
            let found = value.modelCatalog?.models ?? []
            return found.isEmpty ? (value.preset?.fallbackModels ?? []) : found
        } ?? []
        _useCustomModel = State(initialValue: scene.modelOverride.map { override in !models.contains(where: { $0.id == override }) } ?? false)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $scene.name)
                    Picker("用途", selection: $scene.kind) { ForEach(AISceneKind.allCases) { Text($0.title).tag($0) } }
                    Picker("默认连接", selection: $scene.connectionID) {
                        Text("执行时选择").tag(UUID?.none)
                        ForEach(store.connections) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: scene.connectionID) { _, _ in scene.modelOverride = nil; useCustomModel = false }
                    if let connection = selectedConnection { sceneModelPicker(connection) }
                } header: {
                    Text("场景")
                }
                Section {
                    TextEditor(text: $scene.prompt).font(.body).frame(minHeight: 190)
                } header: {
                    Text("提示词")
                }
            }.formStyle(.grouped)
            Divider(); HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { save() }.keyboardShortcut(.defaultAction) }.padding()
        }
        .workbenchSheet(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 570)
        .alert(item: $notice) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("好"))) }
    }
    @ViewBuilder private func sceneModelPicker(_ connection: AIConnection) -> some View {
        let models = pickerModels(for: connection)
        if useCustomModel {
            TextField("固定模型", text: Binding(get: { scene.modelOverride ?? "" }, set: { scene.modelOverride = $0.isEmpty ? nil : $0 }), prompt: Text("输入模型标识"))
            Button("从已知模型中选择") { useCustomModel = false }
        } else {
            Picker("运行模型", selection: $scene.modelOverride) {
                Text("继承连接默认（\(connection.model)）").tag(String?.none)
                ForEach(models) { Text($0.name ?? $0.id).tag(Optional($0.id)) }
                Text("手动填写模型…").tag(Optional("__custom__"))
            }.onChange(of: scene.modelOverride) { _, value in if value == "__custom__" { scene.modelOverride = nil; useCustomModel = true } }
            Text("固定模型只作用于“\(connection.name)”；执行时临时改选其他连接，会使用该连接的默认模型。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var selectedConnection: AIConnection? { guard let id = scene.connectionID else { return nil }; return store.connections.first(where: { $0.id == id }) }
    private func sceneModels(for connection: AIConnection) -> [AIModelDescriptor] { let found = connection.modelCatalog?.models ?? []; return found.isEmpty ? (connection.preset?.fallbackModels ?? []) : found }
    private func pickerModels(for connection: AIConnection) -> [AIModelDescriptor] {
        let models = sceneModels(for: connection)
        guard let override = scene.modelOverride, !override.isEmpty, !models.contains(where: { $0.id == override }) else { return models }
        return [AIModelDescriptor(id: override, name: "当前手动模型：\(override)")] + models
    }
    private func save() { if scene.connectionID == nil { scene.modelOverride = nil }; do { try store.saveScene(scene); dismiss() } catch { notice = Notice(title: "无法保存场景", message: error.localizedDescription) } }
}

private struct Notice: Identifiable { let id = UUID(); let title: String; let message: String }
