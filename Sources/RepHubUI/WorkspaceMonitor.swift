import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 应用运行期间的本地工作区变化提示。
///
/// 此对象只读取各适配器的本地 `stateToken`，不会联网、执行更新或修改工作区。
@MainActor
@Observable
public final class WorkspaceMonitor {
    private static let intervalKey = "rephub.workspaceMonitor.intervalSeconds.v1"
    private static let allowedIntervals: Set<Int> = [0, 15, 30, 60]

    public var intervalSeconds: Int {
        didSet {
            let normalized = Self.normalizedInterval(intervalSeconds)
            guard normalized == intervalSeconds else {
                intervalSeconds = normalized
                return
            }
            defaults?.set(intervalSeconds, forKey: Self.intervalKey)
            schedulePollingIfNeeded()
        }
    }
    public private(set) var pendingBindingIDs: Set<String> = []
    public private(set) var lastCheckedAt: Date?
    public private(set) var errorMessage: String?
    /// 按来源保存最近一次读取错误；一个来源失败不会伪造其他来源无变化。
    public private(set) var errorsByBindingID: [String: String] = [:]
    public private(set) var isChecking = false

    private let service: RepositoryService
    private let defaults: UserDefaults?
    private let clock: @MainActor @Sendable () -> Date
    private var workspace: Workspace?
    private var shouldPoll: (@MainActor @Sendable () -> Bool)?
    private var baselineTokens: [String: String] = [:]
    private var pollingTask: Task<Void, Never>?
    private var checkingTask: Task<Void, Never>?
    private var generation = 0

    public init(
        service: RepositoryService,
        defaults: UserDefaults? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.defaults = defaults
        self.clock = clock
        self.intervalSeconds = Self.normalizedInterval(defaults?.object(forKey: Self.intervalKey) as? Int ?? 30)
    }

    isolated deinit {
        pollingTask?.cancel()
        checkingTask?.cancel()
    }

    /// 开始监控一个已打开工作区。首轮仅读取基线，后续 token 改变才提示刷新。
    public func start(
        workspace: Workspace,
        shouldPoll: @escaping @MainActor @Sendable () -> Bool
    ) {
        stop()
        self.workspace = workspace
        self.shouldPoll = shouldPoll
        baselineTokens = [:]
        pendingBindingIDs = []
        errorsByBindingID = [:]
        errorMessage = nil
        lastCheckedAt = nil
        schedulePollingIfNeeded()
        checkNow()
    }

    /// 停止后，任何已经发出的本地读取结果都会因代次失效而被丢弃。
    public func stop() {
        generation &+= 1
        pollingTask?.cancel()
        checkingTask?.cancel()
        pollingTask = nil
        checkingTask = nil
        workspace = nil
        shouldPoll = nil
        baselineTokens = [:]
        pendingBindingIDs = []
        lastCheckedAt = nil
        errorsByBindingID = [:]
        errorMessage = nil
        isChecking = false
    }

    /// 用户已看到刷新提示；不触发读取，也不会清空本次读取错误。
    public func acknowledge() {
        pendingBindingIDs = []
    }

    /// 手动请求一次本地 token 检查。被锁定、后台或已有检查时安静跳过。
    public func checkNow() {
        guard !isChecking, let workspace, let shouldPoll, shouldPoll() else { return }
        let runGeneration = generation
        let workspaceID = workspace.id
        isChecking = true
        checkingTask?.cancel()
        checkingTask = Task { [weak self, service] in
            defer {
                if let self,
                   self.generation == runGeneration,
                   self.workspace?.id == workspaceID {
                    self.isChecking = false
                    self.checkingTask = nil
                }
            }
            var tokens: [String: String] = [:]
            var errors: [String: String] = [:]
            for binding in workspace.bindings {
                guard !Task.isCancelled else { return }
                do {
                    let context = try await service.managementContext(in: binding)
                    tokens[binding.id] = context.stateToken
                } catch is CancellationError {
                    return
                } catch {
                    errors[binding.id] = RepositoryDisplaySanitizer.redact(error.localizedDescription)
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == runGeneration,
                  self.workspace?.id == workspaceID else { return }
            self.finishCheck(tokens: tokens, errors: errors)
        }
    }

    private func finishCheck(tokens: [String: String], errors: [String: String]) {
        let bindingIDs = Set(workspace?.bindings.map(\.id) ?? [])
        errorsByBindingID = errors
        errorMessage = errors.isEmpty ? nil : errors
            .sorted { $0.key < $1.key }
            .map { "\($0.key)：\($0.value)" }
            .joined(separator: "\n")

        for (bindingID, token) in tokens {
            if let baseline = baselineTokens[bindingID], baseline != token {
                pendingBindingIDs.insert(bindingID)
            }
            baselineTokens[bindingID] = token
        }
        baselineTokens = baselineTokens.filter { bindingIDs.contains($0.key) }
        lastCheckedAt = clock()
    }

    private func schedulePollingIfNeeded() {
        pollingTask?.cancel()
        pollingTask = nil
        guard intervalSeconds > 0, workspace != nil else { return }
        let scheduledGeneration = generation
        let interval = intervalSeconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, self.generation == scheduledGeneration, !Task.isCancelled else { return }
                self.checkNow()
            }
        }
    }

    private static func normalizedInterval(_ value: Int) -> Int {
        allowedIntervals.contains(value) ? value : 30
    }
}
