import Foundation
import Observation
import RepositoryApplication
import VersionControlCore
import AICore

/// 提交窗口的短生命周期状态。它只保存用户此次选择，不自行解释 Git 暂存区或 SVN 工作副本。
@MainActor
@Observable
public final class RepositoryCommitModel {
    public enum Phase: Equatable { case idle, preparing, ready, committing, finished }

    public private(set) var phase: Phase = .idle
    public private(set) var preparations: [RepositoryCommitPreparation] = []
    public var selectedBindingID: String?
    public private(set) var enabledBindingIDs: Set<String> = []
    public private(set) var selectedFileIDs: [String: Set<String>] = [:]
    public private(set) var messages: [String: String] = [:]
    public private(set) var selectedFile: RepositoryCommitFile?
    public private(set) var patch: RepositoryPatch?
    public private(set) var isLoadingPreview = false
    public private(set) var previewError: String?
    public private(set) var results: [RepositoryCommitResult] = []
    public private(set) var errorMessage: String?
    public private(set) var activeBindingID: String?
    public private(set) var isCancelling = false
    public let transferProgress = TransferProgressState()
    public let ai: AIRunModel?

    private let service: RepositoryService
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var requestID = 0
    private var previewRequestID = 0

    public init(service: RepositoryService, ai: AIRunModel? = nil) { self.service = service; self.ai = ai }

    public func prepareAI() {
        guard phase == .ready, let preparation = selectedPreparation,
              enabledBindingIDs.contains(preparation.binding.id), preparation.blockingReason == nil,
              let ai else { return }
        let selected = selectedFiles(for: preparation.binding.id)
        let contexts = RepositoryAIContextService(service: service)
        ai.prepare(kind: .commitMessage, sourceLabel: "\(preparation.binding.providerName) · 待提交改动",
                   paths: preparation.files.filter { selected.contains($0.id) }.map(\.id), selectedPaths: selected) { paths in
            try await contexts.commit(in: preparation, selectedPaths: paths)
        }
    }

    isolated deinit { task?.cancel(); previewTask?.cancel() }

    public var isBusy: Bool { phase == .preparing || phase == .committing }
    public var selectedPreparation: RepositoryCommitPreparation? {
        preparations.first { $0.binding.id == selectedBindingID }
    }
    public var selectedTargets: [RepositoryCommitPreparation] {
        preparations.filter { enabledBindingIDs.contains($0.binding.id) && !selectedFiles(for: $0.binding.id).isEmpty && $0.blockingReason == nil }
    }
    public var canCommit: Bool {
        phase == .ready && selectedTargets.allSatisfy { !message(for: $0.binding.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !selectedTargets.isEmpty
    }

    public func prepare(in workspace: Workspace, initialTargets: Set<String>, initialMessage: String,
                        initialPathsByBinding: [String: Set<String>]? = nil,
                        initialMessages: [String: String]? = nil) {
        guard !isBusy else { return }
        requestID += 1
        previewTask?.cancel()
        let request = requestID
        phase = .preparing
        preparations = []
        selectedBindingID = nil
        enabledBindingIDs = []
        selectedFileIDs = [:]
        messages = [:]
        selectedFile = nil
        patch = nil
        isLoadingPreview = false
        previewError = nil
        results = []
        errorMessage = nil
        activeBindingID = nil
        transferProgress.clear()
        task = Task { [weak self, service] in
            do {
                let prepared = try await service.prepareCommits(in: workspace)
                guard let self, self.requestID == request else { return }
                self.preparations = prepared
                for preparation in prepared {
                    self.messages[preparation.binding.id] = initialMessages?[preparation.binding.id] ?? initialMessage
                    guard initialTargets.contains(preparation.binding.id), preparation.blockingReason == nil else { continue }
                    self.enabledBindingIDs.insert(preparation.binding.id)
                    self.selectedFileIDs[preparation.binding.id] = Self.initiallySelectedFiles(
                        in: preparation,
                        explicitPaths: initialPathsByBinding.map { $0[preparation.binding.id] ?? [] }
                    )
                }
                self.selectedBindingID = prepared.first { preparation in
                    self.enabledBindingIDs.contains(preparation.binding.id)
                        && preparation.blockingReason == nil
                        && !(self.selectedFileIDs[preparation.binding.id] ?? []).isEmpty
                }?.binding.id ?? prepared.first(where: { initialTargets.contains($0.binding.id) })?.binding.id ?? prepared.first?.binding.id
                self.phase = .ready
            } catch is CancellationError {
                guard let self, self.requestID == request else { return }
                self.phase = .idle
            } catch {
                guard let self, self.requestID == request else { return }
                self.phase = .idle
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func dismiss() {
        guard !isBusy else { return }
        reset()
    }

    public func reset() {
        ai?.reset()
        requestID += 1
        task?.cancel()
        previewTask?.cancel()
        phase = .idle
        preparations = []
        selectedBindingID = nil
        enabledBindingIDs = []
        selectedFileIDs = [:]
        messages = [:]
        selectedFile = nil
        patch = nil
        isLoadingPreview = false
        previewError = nil
        isCancelling = false
        results = []
        errorMessage = nil
        activeBindingID = nil
        transferProgress.clear()
    }

    public func message(for bindingID: String) -> String { messages[bindingID] ?? "" }
    public func setMessage(_ value: String, for bindingID: String) { messages[bindingID] = value }
    public func selectedFiles(for bindingID: String) -> Set<String> { selectedFileIDs[bindingID] ?? [] }

    public func selectBinding(_ bindingID: String?) {
        guard selectedBindingID != bindingID else { return }
        selectedBindingID = bindingID
        invalidatePreview()
    }

    public func setBindingEnabled(_ enabled: Bool, for preparation: RepositoryCommitPreparation) {
        guard phase == .ready, preparation.blockingReason == nil else { return }
        if enabled { enabledBindingIDs.insert(preparation.binding.id) }
        else { enabledBindingIDs.remove(preparation.binding.id) }
        invalidatePreview()
    }

    public func toggleFile(_ file: RepositoryCommitFile, in preparation: RepositoryCommitPreparation) {
        guard phase == .ready, preparation.blockingReason == nil, file.restriction == nil else { return }
        var selected = selectedFiles(for: preparation.binding.id)
        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
        selectedFileIDs[preparation.binding.id] = selected
    }

    public func selectAll(in preparation: RepositoryCommitPreparation) {
        guard phase == .ready, preparation.blockingReason == nil else { return }
        selectedFileIDs[preparation.binding.id] = Set(preparation.files.filter { $0.restriction == nil }.map(\.id))
    }

    public func clearSelection(in preparation: RepositoryCommitPreparation) {
        guard phase == .ready, preparation.blockingReason == nil else { return }
        selectedFileIDs[preparation.binding.id] = []
    }

    public func selectFileForPreview(_ file: RepositoryCommitFile, in preparation: RepositoryCommitPreparation) {
        guard phase == .ready else { return }
        previewTask?.cancel()
        previewRequestID += 1
        let previewRequest = previewRequestID
        selectedFile = file
        patch = nil
        isLoadingPreview = true
        previewError = nil
        errorMessage = nil
        previewTask = Task { [weak self, service] in
            do {
                let patch = try await service.commitDiff(in: preparation.binding, file: file)
                guard let self, self.previewRequestID == previewRequest, self.selectedBindingID == preparation.binding.id, self.selectedFile?.id == file.id else { return }
                self.patch = patch
                self.isLoadingPreview = false
            } catch is CancellationError {
            } catch {
                guard let self, self.previewRequestID == previewRequest, self.selectedBindingID == preparation.binding.id, self.selectedFile?.id == file.id else { return }
                self.isLoadingPreview = false
                self.previewError = "无法读取提交差异：\(error.localizedDescription)"
            }
        }
    }

    public func commit(in workspace: Workspace, completed: @escaping @MainActor (WorkspaceCommitResult) -> Void) {
        guard canCommit else { return }
        let requests = selectedTargets.compactMap { preparation -> RepositoryCommitRequest? in
            let files = preparation.files.filter { selectedFiles(for: preparation.binding.id).contains($0.id) }
            guard !files.isEmpty else { return nil }
            return RepositoryCommitRequest(bindingID: preparation.binding.id, baseRevision: preparation.baseRevision,
                                           files: files, message: message(for: preparation.binding.id))
        }
        guard !requests.isEmpty else { return }
        requestID += 1
        let request = requestID
        phase = .committing
        isCancelling = false
        results = []
        errorMessage = nil
        activeBindingID = nil
        transferProgress.begin("正在准备提交…")
        task = Task { [weak self, service] in
            do {
                let response = try await service.commit(requests, in: workspace) { progress in
                    await MainActor.run {
                        guard let self, self.requestID == request else { return }
                        self.activeBindingID = progress.bindingID
                        self.transferProgress.consume(progress.progress)
                    }
                }
                guard let self, self.requestID == request else { return }
                self.results = response.results
                self.phase = .finished
                self.activeBindingID = nil
                self.isCancelling = false
                let outcome = Self.completionMessage(for: response.results)
                self.transferProgress.finish(outcome)
                completed(response)
            } catch is CancellationError {
                guard let self, self.requestID == request else { return }
                self.phase = .finished
                self.activeBindingID = nil
                self.isCancelling = false
                self.errorMessage = "提交已取消；请重新准备后确认各目标状态。"
                self.transferProgress.finish("提交已取消")
            } catch {
                guard let self, self.requestID == request else { return }
                self.phase = .finished
                self.activeBindingID = nil
                self.isCancelling = false
                self.errorMessage = error.localizedDescription
                self.transferProgress.finish("提交未完成")
            }
        }
    }

    public func cancel() {
        guard phase == .committing, !isCancelling else { return }
        isCancelling = true
        transferProgress.consume(RepositoryOperationProgress("正在取消提交…"))
        task?.cancel()
    }

    private func invalidatePreview() {
        previewTask?.cancel()
        previewRequestID += 1
        selectedFile = nil
        patch = nil
        isLoadingPreview = false
        previewError = nil
    }

    /// 显式范围来自工作区树，路径均相对各自工作副本。准备结果确认的未跟踪目录会包含后代；
    /// 已跟踪目录仍只匹配自身，保留 SVN 非递归提交语义。末尾 `/` 保留为显式递归范围的兼容形式。
    private static func initiallySelectedFiles(in preparation: RepositoryCommitPreparation,
                                               explicitPaths: Set<String>?) -> Set<String> {
        let eligible = preparation.files.filter { $0.restriction == nil }
        guard let explicitPaths else { return Set(eligible.map(\.id)) }
        let normalized = explicitPaths.compactMap { path -> (path: String, includesDescendants: Bool)? in
            let includesDescendants = path.hasSuffix("/")
            let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !value.isEmpty else { return nil }
            return (value, includesDescendants)
        }
        let selectedUntrackedDirectories = Set(eligible.lazy.filter { file in
            file.isDirectory && file.change.kind == .untracked && normalized.contains { $0.path == file.change.path }
        }.map { $0.change.path })
        return Set(eligible.lazy.filter { file in
            normalized.contains { selected in
                file.change.path == selected.path
                    || (selected.includesDescendants && file.change.path.hasPrefix(selected.path + "/"))
                    || (selectedUntrackedDirectories.contains(selected.path) && file.change.path.hasPrefix(selected.path + "/"))
            }
        }.map(\.id))
    }

    private static func completionMessage(for results: [RepositoryCommitResult]) -> String {
        if results.allSatisfy({ $0.outcome == .succeeded }) { return "提交完成" }
        if results.contains(where: { $0.outcome == .unknown }) { return "存在待核实的提交结果" }
        if results.contains(where: { $0.outcome == .cancelled }) { return "提交已取消" }
        return "部分目标未提交"
    }
}
