import AppKit
import Foundation
import Observation
import RepositoryApplication
import VersionControlCore

/// 将现有干净 SVN 工作副本转为 Git+SVN 共管目录；所有变更先在服务层暂存目录预览。
@MainActor
@Observable
public final class WorkingCopyMigrationModel {
    public enum Stage: Equatable { case form, planning, prepared, converting, preview, applying, finished }
    public private(set) var stage: Stage = .form
    public var directory: URL?
    public var remoteURL = ""
    public var branch = "main"
    public var mode: MigrationMode = .history
    public var action: WorkingCopyMigrationAction = .initial
    public private(set) var record: WorkingCopyMigrationRecord?
    public private(set) var plan: WorkingCopyMigrationPlan?
    public private(set) var preview: WorkingCopyMigrationPreview?
    public private(set) var filePreview: MigrationFilePreview?
    public private(set) var selectedFilePath: String?
    public private(set) var selectedCommit: String?
    public private(set) var historyPatch: RepositoryPatch?
    public private(set) var expandedDirectories = Set<String>()
    public var fileSearch = ""
    public private(set) var errorMessage: String?
    public private(set) var preservedDirectory: URL?
    public private(set) var result: WorkingCopyMigrationResult?
    public private(set) var isCancelling = false
    public private(set) var isInspectingRecord = false
    public let transferProgress = TransferProgressState()
    public let authorDirectory: MigrationAuthorDirectoryStore

    private let service: WorkingCopyMigrationService
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var requestID = 0

    public init(service: WorkingCopyMigrationService, authorDirectory: MigrationAuthorDirectoryStore = .init()) {
        self.service = service; self.authorDirectory = authorDirectory
    }
    isolated deinit { task?.cancel(); previewTask?.cancel() }
    public var isBusy: Bool { isInspectingRecord || [.planning, .converting, .applying].contains(stage) }
    public var hasExistingRecord: Bool { record != nil }

    public func reset() {
        guard !isBusy else { return }
        requestID += 1; task?.cancel(); previewTask?.cancel()
        stage = .form; directory = nil; remoteURL = ""; branch = "main"; mode = .history; action = .initial
        record = nil; plan = nil; clearPreview(); errorMessage = nil; preservedDirectory = nil; result = nil; transferProgress.clear()
    }
    public func dismiss() { guard !isBusy else { return }; reset() }
    public func prefill(directory: URL) { guard !isBusy else { return }; selectDirectory(directory.standardizedFileURL) }
    public func chooseDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.title = "选择 SVN 工作副本"; panel.message = "首次迁移会检查 SVN 工作副本干净；补迁只检查 Git 工作区干净。不会更新或提交 SVN。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        selectDirectory(selected.standardizedFileURL)
    }
    public func invalidatePlan() { guard !isBusy else { return }; plan = nil; clearPreview(); result = nil; errorMessage = nil; if stage != .form { stage = .form } }
    public func setAction(_ value: WorkingCopyMigrationAction) { guard !isBusy else { return }; action = value; invalidatePlan() }
    public func updateAuthor(_ source: String, name: String, email: String) {
        guard let plan, !isBusy else { return }
        var authors = plan.authors; authors[source] = .init(name: name, email: email)
        self.plan = WorkingCopyMigrationPlan(action: plan.action, workingCopy: plan.workingCopy, source: plan.source,
            remoteURL: plan.remoteURL, branch: plan.branch, expectedGitTip: plan.expectedGitTip,
            previousRecord: plan.previousRecord, authors: authors)
        clearPreview(); preservedDirectory = nil; stage = .prepared
    }
    public func toggleDirectory(_ path: String) { if expandedDirectories.contains(path) { expandedDirectories.remove(path) } else { expandedDirectories.insert(path) } }
    public func revealPreservedDirectory() { if let preservedDirectory { NSWorkspace.shared.activateFileViewerSelecting([preservedDirectory]) } }

    public func makePlan() {
        guard !isBusy, let directory else { errorMessage = "请选择本地 SVN 工作副本。"; return }
        guard !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "请填写目标 Git 地址。"; return }
        let remote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : branch
        let requestedMode = mode, requestedAction = action, handler = progressHandler
        start(.planning, message: "正在检查本地 SVN 工作副本与 Git 目标…") { [service] in
            try await service.plan(at: directory, remoteURL: remote, branch: requestedBranch, mode: requestedMode, action: requestedAction, progress: handler)
        } receive: { model, plan in
            var resolvedPlan = plan
            resolvedPlan.authors = model.authorDirectory.resolve(authors: plan.authors, sourceURL: plan.source.location.url)
            model.plan = resolvedPlan; model.stage = .prepared; model.transferProgress.finish("迁移计划已生成")
        }
    }
    public func preparePreview() {
        guard let plan, !isBusy else { return }
        do { try authorDirectory.save(authors: plan.authors, sourceURL: plan.source.location.url) }
        catch { errorMessage = "无法保存作者映射：\(error.localizedDescription)"; return }
        let handler = progressHandler
        start(.converting, message: "正在在隔离目录准备工作副本转换预览…") { [service] in try await service.prepare(plan, progress: handler) } receive: { model, preview in
            model.preview = preview; model.stage = .preview; model.transferProgress.finish("转换预览已就绪")
        }
    }
    public func loadFile(_ path: String) {
        guard let preview, !isBusy else { return }; selectedFilePath = path; filePreview = nil; previewTask?.cancel(); let token = requestID
        previewTask = Task { [weak self, service] in do { let item = try await service.filePreview(preview, path: path); guard let self, self.requestID == token, self.selectedFilePath == path else { return }; self.filePreview = item } catch is CancellationError {} catch { guard let self, self.requestID == token else { return }; self.errorMessage = "无法读取文件预览：\(error.localizedDescription)" } }
    }
    public func loadHistoryPatch(_ commit: String) {
        guard let preview, !isBusy else { return }; selectedCommit = commit; historyPatch = nil; previewTask?.cancel(); let token = requestID
        previewTask = Task { [weak self, service] in do { let patch = try await service.historyPatch(preview, commit: commit); guard let self, self.requestID == token, self.selectedCommit == commit else { return }; self.historyPatch = patch } catch is CancellationError {} catch { guard let self, self.requestID == token else { return }; self.errorMessage = "无法读取提交差异：\(error.localizedDescription)" } }
    }
    public func applyAndPublish() {
        guard let preview, !isBusy else { return }; let handler = progressHandler
        start(.applying, message: "正在应用预览到当前目录并发布…") { [service] in try await service.applyAndPublish(preview, progress: handler) } receive: { model, result in
            model.result = result
            model.stage = result.publication.state == .published ? .finished : .preview
            model.transferProgress.finish(result.publication.message)
        }
    }
    public func cancel() { guard isBusy, !isCancelling else { return }; isCancelling = true; task?.cancel(); previewTask?.cancel(); transferProgress.consume(.init("正在请求停止，暂存结果会保留…")) }
    private func clearPreview() { preview = nil; filePreview = nil; selectedFilePath = nil; selectedCommit = nil; historyPatch = nil; expandedDirectories = [] }
    private var progressHandler: RepositoryOperationProgressHandler { { [weak self] update in await MainActor.run { self?.transferProgress.consume(update) } } }
    private func selectDirectory(_ directory: URL) {
        requestID += 1; task?.cancel(); previewTask?.cancel()
        self.directory = directory; record = nil; plan = nil; clearPreview(); result = nil; errorMessage = nil; preservedDirectory = nil; stage = .form
        inspectRecord()
    }
    private func inspectRecord() {
        guard let directory else { return }; requestID += 1; let token = requestID; errorMessage = nil; isInspectingRecord = true
        task = Task { [weak self, service] in do { let record = try await service.readRecord(at: directory); guard let self, self.requestID == token else { return }; self.record = record; if let record { self.remoteURL = record.remoteURL; self.branch = record.branch; self.action = .supplement } else { self.action = .initial }; self.isInspectingRecord = false } catch { guard let self, self.requestID == token else { return }; self.record = nil; self.isInspectingRecord = false; self.errorMessage = "无法读取迁移记录：\(error.localizedDescription)" } }
    }
    /// 工作副本模式没有未完成作业的断点恢复；重试必须使用新的隔离目录，
    /// 不能再次拿同一未完成 job 当成已验证预览。
    private func renewPlanForRetry() {
        guard preview == nil, let plan else { return }
        self.plan = WorkingCopyMigrationPlan(action: plan.action, workingCopy: plan.workingCopy, source: plan.source,
            remoteURL: plan.remoteURL, branch: plan.branch, expectedGitTip: plan.expectedGitTip,
            previousRecord: plan.previousRecord, authors: plan.authors)
    }

    private func start<T: Sendable>(_ stage: Stage, message: String,
                                    work: @escaping @Sendable () async throws -> T,
                                    receive: @escaping @MainActor (WorkingCopyMigrationModel, T) -> Void) {
        requestID += 1
        let token = requestID
        self.stage = stage; errorMessage = nil; isCancelling = false; transferProgress.begin(message)
        task = Task { [weak self] in
            do {
                let value = try await work()
                guard let self, self.requestID == token else { return }
                self.isCancelling = false; receive(self, value)
            } catch {
                guard let self, self.requestID == token else { return }
                if let plan = self.plan { self.preservedDirectory = await self.service.partialDirectory(for: plan.id) }
                if stage == .converting { self.renewPlanForRetry() }
                self.isCancelling = false
                self.stage = self.preview != nil ? .preview : (self.plan == nil ? .form : .prepared)
                if error is CancellationError {
                    self.errorMessage = stage == .converting
                        ? "已取消；暂存目录已保留，可重新从头生成预览。"
                        : "操作已取消。"
                    self.transferProgress.finish("已取消")
                } else {
                    self.errorMessage = error.localizedDescription
                    self.transferProgress.finish("未完成")
                }
            }
        }
    }
}
