import AICore
import AIApplication
import Foundation
import Observation

/// AI 面板的一次性运行状态。它只持有用户明确选择的差异范围，不主动读取仓库或发起请求。
@MainActor
@Observable
public final class AIRunModel {
    public private(set) var isBusy = false
    public private(set) var kind: AISceneKind = .codeReview
    public private(set) var sourceLabel = ""
    public private(set) var paths: [String] = []
    public private(set) var selectedPaths: Set<String> = []
    public private(set) var output = ""
    public private(set) var progress = ""
    public private(set) var errorMessage: String?
    public private(set) var isStale = false
    public private(set) var completedSnapshotID: String?
    public private(set) var tokenUsage: AITokenUsage?
    public private(set) var hasStartedRequest = false

    /// `nil` 代表尚未选择场景或连接。
    public private(set) var sceneID: UUID?
    public private(set) var connectionID: UUID?

    public let settings: AISettingsStore
    private let service: AIService
    private var contextBuilder: (@Sendable (Set<String>) async throws -> AIContext)?
    private var task: Task<Void, Never>?
    private var requestToken = 0
    private var completedBasis: ResultBasis?
    private static let outputLimit = 1_024 * 1_024

    private struct ResultBasis: Equatable {
        let scene: AIScene
        let connection: AIConnection
        let paths: Set<String>
    }

    public init(settings: AISettingsStore, service: AIService) {
        self.settings = settings
        self.service = service
    }

    isolated deinit { task?.cancel() }

    public var scenes: [AIScene] {
        settings.scenes.filter { $0.kind == kind }
    }

    public var connections: [AIConnection] { settings.connections }

    public var selectedScene: AIScene? {
        scenes.first { $0.id == sceneID }
    }

    public var selectedConnection: AIConnection? {
        connections.first { $0.id == connectionID }
    }

    public var effectiveModel: String {
        guard let connection = selectedConnection else { return "" }
        if let scene = selectedScene, scene.connectionID == connection.id,
           let model = scene.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty { return model }
        return connection.model
    }

    public var canRun: Bool {
        !isBusy && selectedScene != nil && selectedConnection != nil && !selectedPaths.isEmpty && contextBuilder != nil
    }

    /// 提交说明必须和提交窗口的勾选集合一致；仅审查场景可在此窗口调整范围。
    public var canEditFileSelection: Bool { kind == .codeReview && !isBusy }

    public var actionTitle: String {
        kind == .commitMessage ? "生成提交说明" : "开始审查"
    }

    public func prepare(
        kind: AISceneKind,
        sourceLabel: String,
        paths: [String],
        selectedPaths: Set<String>? = nil,
        contextBuilder: @escaping @Sendable (Set<String>) async throws -> AIContext
    ) {
        reset()
        self.kind = kind
        self.sourceLabel = sourceLabel
        self.paths = Array(Set(paths)).sorted()
        self.selectedPaths = (selectedPaths ?? Set(paths)).intersection(Set(paths))
        self.contextBuilder = contextBuilder
        let matchingScenes = scenes
        sceneID = matchingScenes.first?.id
        connectionID = matchingScenes.first?.connectionID ?? connections.first?.id
        clearResult()
    }

    public func selectScene(_ id: UUID?) {
        guard !isBusy, sceneID != id else { return }
        invalidatePendingValidation()
        sceneID = id
        if let scene = selectedScene, let defaultConnection = scene.connectionID {
            connectionID = defaultConnection
        } else if let connectionID, !connections.contains(where: { $0.id == connectionID }) {
            self.connectionID = connections.first?.id
        }
        markStale()
    }

    public func selectConnection(_ id: UUID?) {
        guard !isBusy, connectionID != id else { return }
        invalidatePendingValidation()
        connectionID = id
        markStale()
    }

    public func setSelectedPaths(_ next: Set<String>) {
        guard canEditFileSelection else { return }
        let valid = next.intersection(Set(paths))
        guard selectedPaths != valid else { return }
        invalidatePendingValidation()
        selectedPaths = valid
        markStale()
    }

    public func togglePath(_ path: String) {
        var next = selectedPaths
        if next.contains(path) { next.remove(path) } else { next.insert(path) }
        setSelectedPaths(next)
    }

    public func selectAllPaths() { setSelectedPaths(Set(paths)) }
    public func clearPathSelection() { setSelectedPaths([]) }

    public func run() {
        guard canRun, let scene = selectedScene, let connection = selectedConnection, let contextBuilder else {
            if scenes.isEmpty { errorMessage = "尚未配置“\(kind.title)”场景。请在设置中创建场景后再运行。" }
            else if connections.isEmpty { errorMessage = "尚未配置 AI 连接。请先在设置中添加模型 API 或本机 CLI。" }
            else if selectedPaths.isEmpty { errorMessage = "请至少选择一个文件。" }
            return
        }
        requestToken += 1
        let token = requestToken
        let selected = selectedPaths
        let basis = ResultBasis(scene: scene, connection: connection, paths: selected)
        task?.cancel()
        isBusy = true
        output = ""
        progress = "正在整理所选差异…"
        errorMessage = nil
        isStale = false
        completedSnapshotID = nil
        completedBasis = nil
        tokenUsage = nil
        hasStartedRequest = false

        task = Task { [weak self, service] in
            do {
                let context = try await contextBuilder(selected)
                guard let self, self.accepts(token, basis: basis) else { return }
                guard !context.files.isEmpty else {
                    self.finish(token, error: AIError.failed("所选文件没有可供分析的文本差异。"))
                    return
                }
                self.progress = "正在请求 \(connection.kind.title)…"
                let request = AIExecutionRequest(connection: connection, scene: scene, context: context)
                self.hasStartedRequest = true
                let result = try await service.execute(request) { [weak self] update in
                    await self?.consume(update, token: token, basis: basis)
                }
                guard self.accepts(token, basis: basis), !Task.isCancelled else { return }
                self.output = result
                self.completedSnapshotID = context.snapshotID
                self.completedBasis = basis
                self.progress = "正在核对差异是否变化…"
                do {
                    let current = try await contextBuilder(selected)
                    guard self.accepts(token, basis: basis), !Task.isCancelled else { return }
                    self.isStale = current.snapshotID != context.snapshotID
                    self.progress = self.isStale ? "差异已变化，请重新运行后使用结果。" : "已完成"
                } catch is CancellationError {
                    guard self.accepts(token, basis: basis), !Task.isCancelled else { return }
                    self.isStale = true
                    self.progress = "核对已取消，请重新运行后使用结果。"
                } catch {
                    guard self.accepts(token, basis: basis), !Task.isCancelled else { return }
                    self.isStale = true
                    self.progress = "无法核对最新差异，请重新运行后使用结果。"
                }
                guard self.accepts(token, basis: basis), !Task.isCancelled else { return }
                self.isBusy = false
            } catch is CancellationError {
                guard let self, self.requestToken == token, !Task.isCancelled else { return }
                self.isBusy = false
                self.progress = "已取消"
                self.errorMessage = "AI 运行已取消。"
            } catch {
                guard let self, self.requestToken == token, !Task.isCancelled else { return }
                self.finish(token, error: error)
            }
        }
    }

    public func cancel() {
        guard isBusy else { return }
        requestToken += 1
        task?.cancel()
        task = nil
        isBusy = false
        output = ""
        completedSnapshotID = nil
        completedBasis = nil
        isStale = true
        progress = "已取消"
        errorMessage = "AI 运行已取消。"
    }

    public func reset() {
        requestToken += 1
        task?.cancel()
        task = nil
        clearResult()
    }

    public func markStale() {
        guard !output.isEmpty || completedSnapshotID != nil else { return }
        isStale = true
        if isBusy, completedSnapshotID != nil {
            invalidatePendingValidation()
            isBusy = false
        }
    }

    /// 重新读取当前选择的差异，仅判断现有结果能否继续使用，不会调用模型。
    public func revalidate() {
        guard !isBusy, let expected = completedSnapshotID, let basis = completedBasis, let contextBuilder else { return }
        requestToken += 1
        let token = requestToken
        let selected = selectedPaths
        progress = "正在重新核对差异…"
        task = Task { [weak self] in
            do {
                guard let self else { return }
                guard self.currentBasis == basis else {
                    self.isStale = true
                    self.progress = "场景、连接或文件范围已变化，请重新运行。"
                    return
                }
                let context = try await contextBuilder(selected)
                guard self.requestToken == token, self.currentBasis == basis, !Task.isCancelled else { return }
                self.isStale = context.snapshotID != expected
                self.progress = self.isStale ? "差异已变化，请重新运行。" : "结果仍与当前差异一致"
            } catch is CancellationError {
            } catch {
                guard let self, self.requestToken == token else { return }
                self.isStale = true
                self.progress = "无法核对最新差异，请重新运行。"
            }
        }
    }

    /// 仅当此刻选择的差异仍和输出所依据的快照一致时，才交给调用方填入提交说明。
    public func apply(_ handler: @escaping @MainActor (String) -> Void) {
        guard !isBusy, !output.isEmpty, !isStale, let expected = completedSnapshotID,
              let basis = completedBasis, currentBasis == basis, let contextBuilder else { return }
        requestToken += 1
        let token = requestToken
        let selected = selectedPaths
        let value = output
        task?.cancel()
        isBusy = true
        progress = "正在核对差异…"
        task = Task { [weak self] in
            do {
                let current = try await contextBuilder(selected)
                guard let self, self.requestToken == token, self.currentBasis == basis, !Task.isCancelled else { return }
                guard current.snapshotID == expected else {
                    self.isStale = true
                    self.progress = "差异已变化，未填入旧结果。"
                    self.isBusy = false
                    return
                }
                handler(value)
                self.progress = "已填入提交说明"
                self.isBusy = false
            } catch is CancellationError {
                guard let self, self.requestToken == token, !Task.isCancelled else { return }
                self.isBusy = false
                self.isStale = true
                self.progress = "核对已取消，未填入旧结果。"
            } catch {
                guard let self, self.requestToken == token, !Task.isCancelled else { return }
                self.isStale = true
                self.progress = "无法核对最新差异，未填入旧结果。"
                self.isBusy = false
            }
        }
    }

    private var currentBasis: ResultBasis? {
        guard let scene = selectedScene, let connection = selectedConnection else { return nil }
        return ResultBasis(scene: scene, connection: connection, paths: selectedPaths)
    }

    private func accepts(_ token: Int, basis: ResultBasis) -> Bool {
        requestToken == token && currentBasis == basis
    }

    private func consume(_ update: AIProgress, token: Int, basis: ResultBasis) {
        guard accepts(token, basis: basis) else { return }
        switch update {
        case .status(let value): progress = value
        case .usage(let value): tokenUsage = value
        case .textDelta(let value):
            let remaining = Self.outputLimit - output.utf8.count
            guard remaining > 0 else { return }
            let prefix = value.utf8.prefix(remaining)
            output += String(decoding: prefix, as: UTF8.self)
        }
    }

    private func finish(_ token: Int, error: Error) {
        guard requestToken == token else { return }
        isBusy = false
        progress = "未完成"
        errorMessage = error.localizedDescription
    }

    private func clearResult() {
        isBusy = false
        output = ""
        progress = ""
        errorMessage = nil
        isStale = false
        completedSnapshotID = nil
        completedBasis = nil
        tokenUsage = nil
        hasStartedRequest = false
    }

    /// `apply` 和 `revalidate` 也会异步读取差异；用户改范围后不能让旧读取落回当前状态。
    private func invalidatePendingValidation() {
        requestToken += 1
        task?.cancel()
        task = nil
    }
}
