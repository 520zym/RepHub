import AppKit
import Foundation
import Observation
import RepositoryApplication
import UniformTypeIdentifiers
import VersionControlCore

/// 将现有干净 SVN 工作副本转为 Git+SVN 共管目录；所有变更先在服务层暂存目录预览。
@MainActor
@Observable
public final class WorkingCopyMigrationModel {
    public enum Stage: Equatable { case form, planning, prepared, converting, preview, applying, finished }
    public enum PreviewTab: Hashable { case overview, files, history }
    public private(set) var stage: Stage = .form
    /// 迁移 sheet 收起再恢复时，继续停留在用户正在查看的预览页。
    public var previewTab: PreviewTab = .overview
    public var directory: URL?
    public var remoteURL = ""
    public var branch = "main"
    public var mode: MigrationMode = .history
    /// 首次接管默认只迁移当前目录创建/复制后的历史；补迁沿用既有迁移范围。
    public var includeCopyHistory = false
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
    /// 当前计划来自检查点，或失败时已保留检查点；继续之前仍由服务重新核验。
    public private(set) var isResumingFromCheckpoint = false
    public private(set) var result: WorkingCopyMigrationResult?
    public private(set) var isCancelling = false
    public private(set) var isInspectingRecord = false
    public let transferProgress = TransferProgressState()
    public let authorDirectory: MigrationAuthorDirectoryStore
    public private(set) var resumeRecords: [MigrationResumeStore.Record] = []
    public var isShowingResumePicker = false

    private let service: WorkingCopyMigrationService
    private let resumeStore: MigrationResumeStore
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var requestID = 0

    public init(service: WorkingCopyMigrationService, authorDirectory: MigrationAuthorDirectoryStore = .init(),
                resumeStore: MigrationResumeStore = .shared) {
        self.service = service; self.authorDirectory = authorDirectory; self.resumeStore = resumeStore
        refreshResumeRecords()
    }
    isolated deinit { task?.cancel(); previewTask?.cancel() }
    public var isBusy: Bool { isInspectingRecord || [.planning, .converting, .applying].contains(stage) }
    public var hasExistingRecord: Bool { record != nil }

    public func reset() {
        guard !isBusy else { return }
        requestID += 1; task?.cancel(); previewTask?.cancel()
        stage = .form; previewTab = .overview; directory = nil; remoteURL = ""; branch = "main"; mode = .history; includeCopyHistory = false; action = .initial
        record = nil; plan = nil; clearPreview(); errorMessage = nil; preservedDirectory = nil; isResumingFromCheckpoint = false; result = nil; transferProgress.clear(); isShowingResumePicker = false; refreshResumeRecords()
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
    public func invalidatePlan() { guard !isBusy else { return }; isResumingFromCheckpoint = false; plan = nil; clearPreview(); result = nil; errorMessage = nil; if stage != .form { stage = .form } }
    public func setAction(_ value: WorkingCopyMigrationAction) { guard !isBusy else { return }; action = value; invalidatePlan() }
    public func updateAuthor(_ source: String, name: String, email: String) {
        guard let plan, !isBusy else { return }
        var authors = plan.authors; authors[source] = .init(name: name, email: email)
        self.plan = WorkingCopyMigrationPlan(action: plan.action, workingCopy: plan.workingCopy, source: plan.source,
            remoteURL: plan.remoteURL, branch: plan.branch, expectedGitTip: plan.expectedGitTip,
            previousRecord: plan.previousRecord, authors: authors)
        clearPreview(); preservedDirectory = nil; isResumingFromCheckpoint = false; stage = .prepared
    }
    public func toggleDirectory(_ path: String) { if expandedDirectories.contains(path) { expandedDirectories.remove(path) } else { expandedDirectories.insert(path) } }
    public func revealPreservedDirectory() { if let preservedDirectory { NSWorkspace.shared.activateFileViewerSelecting([preservedDirectory]) } }

    public func makePlan() {
        guard !isBusy, let directory else { errorMessage = "请选择本地 SVN 工作副本。"; return }
        guard !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "请填写目标 Git 地址。"; return }
        let remote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : branch
        let requestedMode = mode, requestedAction = action, handler = progressHandler
        let requestedCopyHistory = requestedAction == .initial && requestedMode == .history && includeCopyHistory
        start(.planning, message: "正在检查本地 SVN 工作副本与 Git 目标…") { [service] in
            try await service.plan(at: directory, remoteURL: remote, branch: requestedBranch, mode: requestedMode,
                                   action: requestedAction, includeCopyHistory: requestedCopyHistory, progress: handler)
        } receive: { model, plan in
            var resolvedPlan = plan
            resolvedPlan.authors = model.authorDirectory.resolve(authors: plan.authors, sourceURL: plan.source.location.url)
            model.plan = resolvedPlan; model.isResumingFromCheckpoint = false; model.stage = .prepared; model.transferProgress.finish("迁移计划已生成")
        }
    }
    public func preparePreview() {
        preparePreview(checkSourceUpdates: isResumingFromCheckpoint || preview != nil)
    }
    private func preparePreview(checkSourceUpdates: Bool) {
        guard let plan, !isBusy else { return }
        do { try authorDirectory.save(authors: plan.authors, sourceURL: plan.source.location.url) }
        catch { errorMessage = "无法保存作者映射：\(error.localizedDescription)"; return }
        let handler = progressHandler
        let isResuming = isResumingFromCheckpoint || preview != nil
        start(.converting, message: isResuming ? "正在从检查点继续生成工作副本转换预览…" : "正在在隔离目录准备工作副本转换预览…") { [service] in try await service.prepare(plan, progress: handler) } receive: { model, preview in
            model.plan = preview.plan; model.preview = preview; model.isResumingFromCheckpoint = false
            model.stage = .preview; model.transferProgress.finish("转换预览已就绪")
            if checkSourceUpdates { model.checkAndContinueSourceUpdates() }
        }
    }
    public func checkAndContinueSourceUpdates() {
        guard let plan, preview != nil, result == nil, !isBusy else { return }
        let handler = progressHandler
        start(.planning, message: "正在检查后续 SVN 提交，已完成历史会保留…") { [service] in
            try await service.planContinuation(plan, progress: handler)
        } receive: { model, next in
            guard var next else {
                model.stage = .preview
                model.transferProgress.finish("已恢复预览，当前工作副本没有后续待迁提交")
                if model.preview?.applicationIssue != nil { model.preparePreview(checkSourceUpdates: false) }
                return
            }
            let newAuthors = next.authors.filter { plan.authors[$0.key] == nil }
            let resolved = model.authorDirectory.resolve(authors: newAuthors, sourceURL: next.source.location.url)
            next.authors.merge(resolved) { _, saved in saved }
            model.plan = next
            model.clearPreview()
            model.stage = .prepared
            model.preparePreview(checkSourceUpdates: false)
        }
    }
    /// 工作副本迁移只接受服务层写出的新版 checkpoint；不会从 SVN/Git 历史反推范围或凭据。
    public func resumeExistingMigration() {
        guard !isBusy else { return }
        refreshResumeRecords(); isShowingResumePicker = true
    }
    public func dismissResumePicker() { guard !isBusy else { return }; isShowingResumePicker = false }
    public func refreshResumeRecords() { resumeRecords = resumeStore.records(kind: .workingCopy) }
    public func removeResumeRecord(_ record: MigrationResumeStore.Record) { resumeStore.remove(id: record.id, kind: .workingCopy); refreshResumeRecords() }
    public func chooseResumeCheckpoint() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择迁移保留目录或检查点"
        panel.message = "可选择 RepHub-working-copy-migration-… 保留目录，或其中的 checkpoint.json。已显示隐藏文件；不会读取或保存 SVN 凭据。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = preservedDirectory ?? resumeRecords.first?.checkpointURL.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        resume(from: MigrationResumeStore.checkpointURL(for: selected))
    }
    public func resume(from record: MigrationResumeStore.Record) { resume(from: record.checkpointURL) }
    private func resume(from checkpoint: URL) {
        plan = nil; clearPreview(); result = nil; errorMessage = nil; preservedDirectory = nil; isResumingFromCheckpoint = false
        isShowingResumePicker = false
        let handler = progressHandler
        start(.planning, message: "正在恢复已保存的迁移结果…") { [service] in
            try await service.resume(from: checkpoint, progress: handler)
        } receive: { model, restored in
            model.directory = restored.workingCopy.directory
            model.remoteURL = restored.remoteURL
            model.branch = restored.branch
            model.mode = restored.source.mode
            model.includeCopyHistory = restored.source.includeCopyHistory
            model.action = restored.action
            model.record = restored.previousRecord
            model.plan = restored
            model.preservedDirectory = checkpoint.deletingLastPathComponent().standardizedFileURL
            model.isResumingFromCheckpoint = true
            model.stage = .prepared
            model.refreshResumeRecords()
            model.transferProgress.finish("已恢复检查点，正在继续到预览")
            model.preparePreview()
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
        guard let preview, !isBusy else { return }
        guard preview.applicationIssue == nil else { errorMessage = preview.applicationIssue; return }
        let handler = progressHandler
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
        self.directory = directory; record = nil; plan = nil; clearPreview(); result = nil; errorMessage = nil; preservedDirectory = nil; isResumingFromCheckpoint = false; stage = .form
        inspectRecord()
    }
    private func inspectRecord() {
        guard let directory else { return }; requestID += 1; let token = requestID; errorMessage = nil; isInspectingRecord = true
        task = Task { [weak self, service] in do { let record = try await service.readRecord(at: directory); guard let self, self.requestID == token else { return }; self.record = record; if let record { self.remoteURL = record.remoteURL; self.branch = record.branch; self.action = .supplement } else { self.action = .initial }; self.isInspectingRecord = false } catch { guard let self, self.requestID == token else { return }; self.record = nil; self.isInspectingRecord = false; self.errorMessage = "无法读取迁移记录：\(error.localizedDescription)" } }
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
                if stage == .converting {
                    self.isResumingFromCheckpoint = self.action == .initial && self.preservedDirectory.map {
                        FileManager.default.fileExists(atPath: $0.appendingPathComponent("checkpoint.json").path)
                    } == true
                }
                self.isCancelling = false
                self.stage = self.preview != nil ? .preview : (self.plan == nil ? .form : .prepared)
                if error is CancellationError {
                    self.errorMessage = stage == .converting
                        ? (self.isResumingFromCheckpoint ? "已取消；检查点已保留，继续前会重新核验。" : "已取消；暂存目录已保留，尚无可继续的初迁检查点，请重新预检。")
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
