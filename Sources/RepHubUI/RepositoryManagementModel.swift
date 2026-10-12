import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

public struct RepositoryComparisonSeed: Equatable, Sendable {
    public let fromRevision: String?
    public let toRevision: String
    public init(fromRevision: String?, toRevision: String) {
        self.fromRevision = fromRevision
        self.toRevision = toRevision
    }
}

/// 仓库管理窗口的短生命周期状态。界面只根据适配器上下文显示能力，不自行猜测 Git 或 SVN 命令。
@MainActor
@Observable
public final class RepositoryManagementModel {
    public private(set) var context: RepositoryManagementContext?
    public private(set) var workspace: Workspace?
    public private(set) var selectedBinding: RepositoryBinding?
    public private(set) var isLoading = false
    public private(set) var isExecuting = false
    public private(set) var isCancelling = false
    public private(set) var progressMessage = ""
    public let transferProgress = TransferProgressState()
    public private(set) var result: WorkspaceManagementResult?
    public private(set) var errorMessage: String?
    public private(set) var stagedPatch: RepositoryPatch?
    public private(set) var stagedPath: String?
    public private(set) var isLoadingStagedPatch = false
    public private(set) var comparison: RepositoryComparison?
    public private(set) var comparisonPatch: RepositoryPatch?
    public private(set) var comparisonPath: String?
    public private(set) var isComparing = false
    public private(set) var isLoadingComparisonPatch = false
    public private(set) var comparisonError: String?
    public private(set) var comparisonSeed: RepositoryComparisonSeed?

    private let service: RepositoryService
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var requestID = 0
    private var previewID = 0
    private var comparisonID = 0

    public init(service: RepositoryService) { self.service = service }

    isolated deinit { task?.cancel(); previewTask?.cancel(); comparisonTask?.cancel() }

    public var isBusy: Bool { isLoading || isExecuting }

    public func prepare(in workspace: Workspace, binding: RepositoryBinding, comparisonSeed: RepositoryComparisonSeed? = nil) {
        guard !isExecuting else { return }
        requestID += 1
        previewID += 1
        comparisonID += 1
        let token = requestID
        task?.cancel()
        previewTask?.cancel()
        comparisonTask?.cancel()
        self.workspace = workspace
        selectedBinding = binding
        context = nil
        result = nil
        errorMessage = nil
        stagedPatch = nil
        stagedPath = nil
        comparison = nil
        comparisonPatch = nil
        comparisonPath = nil
        comparisonError = nil
        self.comparisonSeed = comparisonSeed
        isLoading = true
        isLoadingStagedPatch = false
        isComparing = false
        isLoadingComparisonPatch = false
        isCancelling = false
        transferProgress.clear()
        task = Task { [weak self, service] in
            do {
                let context = try await service.managementContext(in: binding)
                guard !Task.isCancelled, let self, self.requestID == token, self.selectedBinding?.id == binding.id else { return }
                self.context = context
                self.isLoading = false
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isLoading = false
            } catch {
                guard let self, self.requestID == token else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func execute(_ action: RepositoryManagementAction,
                        completed: @escaping @MainActor @Sendable (WorkspaceManagementResult) -> Void) {
        guard !isBusy, let workspace, let binding = selectedBinding, let context else { return }
        requestID += 1
        previewID += 1
        comparisonID += 1
        let token = requestID
        previewTask?.cancel()
        comparisonTask?.cancel()
        isExecuting = true
        isCancelling = false
        result = nil
        errorMessage = nil
        progressMessage = "正在准备\(action.title)…"
        transferProgress.begin(progressMessage)
        task = Task { [weak self, service] in
            do {
                let response = try await service.manage(
                    RepositoryManagementRequest(action: action, stateToken: context.stateToken),
                    bindingID: binding.id,
                    in: workspace
                ) { progress in
                    await MainActor.run {
                        guard let self, self.requestID == token else { return }
                        self.progressMessage = progress.message
                        self.transferProgress.consume(progress)
                    }
                }
                // 写操作的适配器会在收到取消请求后核对仓库再返回最终状态。
                // 此时 Task 已被标记取消，但仍必须消费这份状态，结束执行态并让用户
                // 看到实际结果；只有新的请求才可以使旧结果失效。
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.result = response
                self.progressMessage = response.result.summary
                self.transferProgress.finish(response.result.summary)
                self.workspace = response.workspace
                self.selectedBinding = response.workspace.bindings.first { $0.id == binding.id }
                self.context = nil
                completed(response)
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.errorMessage = "操作已取消，请检查刷新后的仓库状态。"
                self.transferProgress.finish("操作已取消")
            } catch {
                guard let self, self.requestID == token else { return }
                self.isExecuting = false
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
                self.transferProgress.finish("操作未完成")
            }
        }
    }

    public func loadStagedDiff(path: String) {
        guard !isBusy, let binding = selectedBinding else { return }
        previewID += 1
        let token = previewID
        previewTask?.cancel()
        stagedPath = path
        stagedPatch = nil
        isLoadingStagedPatch = true
        previewTask = Task { [weak self, service] in
            do {
                let patch = try await service.stagedDiff(in: binding, path: path)
                guard !Task.isCancelled, let self, self.previewID == token, self.stagedPath == path,
                      self.selectedBinding?.id == binding.id else { return }
                self.stagedPatch = patch
                self.isLoadingStagedPatch = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.previewID == token, self.stagedPath == path,
                      self.selectedBinding?.id == binding.id else { return }
                self.isLoadingStagedPatch = false
                self.errorMessage = "无法读取暂存差异：\(error.localizedDescription)"
            }
        }
    }

    public func compare(from: String, to: String) {
        guard !isBusy, let binding = selectedBinding else { return }
        comparisonID += 1
        let token = comparisonID
        comparisonTask?.cancel()
        comparison = nil
        comparisonPatch = nil
        comparisonPath = nil
        comparisonError = nil
        comparisonSeed = nil
        isComparing = true
        comparisonTask = Task { [weak self, service] in
            do {
                let value = try await service.compare(in: binding, from: from, to: to)
                guard !Task.isCancelled, let self, self.comparisonID == token, self.selectedBinding?.id == binding.id else { return }
                self.comparison = value
                self.isComparing = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.comparisonID == token, self.selectedBinding?.id == binding.id else { return }
                self.isComparing = false
                self.comparisonError = error.localizedDescription
            }
        }
    }

    public func loadComparisonDiff(path: String) {
        guard !isBusy, let binding = selectedBinding, let comparison else { return }
        comparisonID += 1
        let token = comparisonID
        comparisonTask?.cancel()
        comparisonPath = path
        comparisonPatch = nil
        isLoadingComparisonPatch = true
        comparisonTask = Task { [weak self, service] in
            do {
                let patch = try await service.comparisonDiff(in: binding, comparison: comparison, path: path)
                guard !Task.isCancelled, let self, self.comparisonID == token, self.comparisonPath == path,
                      self.selectedBinding?.id == binding.id else { return }
                self.comparisonPatch = patch
                self.isLoadingComparisonPatch = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.comparisonID == token, self.comparisonPath == path,
                      self.selectedBinding?.id == binding.id else { return }
                self.isLoadingComparisonPatch = false
                self.comparisonError = "无法读取比较差异：\(error.localizedDescription)"
            }
        }
    }

    public func cancel() {
        guard (isExecuting || isLoading), !isCancelling else { return }
        isCancelling = true
        progressMessage = "正在取消并等待仓库状态核对…"
        transferProgress.consume(RepositoryOperationProgress(progressMessage))
        task?.cancel()
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    public func dismiss() {
        guard !isExecuting else { return }
        requestID += 1
        previewID += 1
        comparisonID += 1
        task?.cancel()
        previewTask?.cancel()
        comparisonTask?.cancel()
        context = nil
        workspace = nil
        selectedBinding = nil
        result = nil
        errorMessage = nil
        stagedPatch = nil
        stagedPath = nil
        comparison = nil
        comparisonPatch = nil
        comparisonPath = nil
        comparisonError = nil
        comparisonSeed = nil
        isLoading = false
        isLoadingStagedPatch = false
        isComparing = false
        isLoadingComparisonPatch = false
        isCancelling = false
        progressMessage = ""
        transferProgress.clear()
    }
}
