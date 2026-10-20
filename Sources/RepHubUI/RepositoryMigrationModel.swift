import AppKit
import Foundation
import Observation
import RepositoryApplication
import UniformTypeIdentifiers
import VersionControlCore

/// 仓库迁移是一次性的受控作业：先做只读计划，再在独立目录生成可检查的 Git 预览。
@MainActor
@Observable
public final class RepositoryMigrationModel {
    public enum Stage: Equatable { case form, planning, prepared, converting, preview, publishing, published }
    public enum PreviewTab: Hashable { case overview, files, history }

    public private(set) var stage: Stage = .form
    /// 迁移 sheet 收起再恢复时，继续停留在用户正在查看的预览页。
    public var previewTab: PreviewTab = .overview
    public var sourceURL = ""
    public var username = ""
    public var password = ""
    public var sourceProviderID: ProviderID = .svn
    public var targetURL = ""
    public var branch = "main"
    public var destinationParent: URL?
    public var directoryName = "migrated-repository"
    public var mode: MigrationMode = .history
    /// 默认只迁移当前目录在最近一次复制/创建之后的历史，避免无意追溯庞大的祖先目录。
    public var includeCopyHistory = false
    public private(set) var listings: [String: RemoteDirectoryListing] = [:]
    public private(set) var rootListingURL: String?
    public private(set) var expandedURLs = Set<String>()
    public private(set) var selectedSourceURL: String?
    public private(set) var plan: MigrationPlan?
    public private(set) var preview: MigrationPreview?
    public private(set) var filePreview: MigrationFilePreview?
    public private(set) var selectedFilePath: String?
    public private(set) var expandedFileDirectories = Set<String>()
    public private(set) var selectedCommit: String?
    public private(set) var historyPatch: RepositoryPatch?
    public private(set) var isBrowsing = false
    public private(set) var isCancelling = false
    public private(set) var errorMessage: String?
    public private(set) var publication: MigrationPublicationResult?
    public private(set) var preservedDirectory: URL?
    public let transferProgress = TransferProgressState()
    public let authorDirectory: MigrationAuthorDirectoryStore
    public private(set) var resumeRecords: [MigrationResumeStore.Record] = []
    public var isShowingResumePicker = false
    public var fileSearch = ""

    private let service: RepositoryMigrationService
    private let resumeStore: MigrationResumeStore
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var requestID = 0

    public init(service: RepositoryMigrationService, authorDirectory: MigrationAuthorDirectoryStore = .init(),
                resumeStore: MigrationResumeStore = .shared) {
        self.service = service; self.authorDirectory = authorDirectory; self.resumeStore = resumeStore
        refreshResumeRecords()
    }
    isolated deinit { task?.cancel(); previewTask?.cancel() }

    public var isBusy: Bool { [.planning, .converting, .publishing].contains(stage) || isBrowsing }
    public var sourceLocation: RemoteRepositoryLocation {
        .init(url: selectedSourceURL ?? sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
              credentials: username.isEmpty && password.isEmpty ? nil : .init(username: username, password: password))
    }
    public var destination: URL? {
        guard let destinationParent else { return nil }
        let name = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : destinationParent.appendingPathComponent(name, isDirectory: true)
    }
    public var warnings: [String] { preview?.warnings ?? plan?.source.warnings ?? [] }

    public func reset() {
        guard !isBusy else { return }
        requestID += 1
        task?.cancel(); previewTask?.cancel()
        stage = .form; previewTab = .overview; sourceURL = ""; username = ""; password = ""; targetURL = ""; branch = "main"
        destinationParent = nil; directoryName = "migrated-repository"; mode = .history; includeCopyHistory = false
        listings = [:]; rootListingURL = nil; expandedURLs = []; selectedSourceURL = nil
        plan = nil; preview = nil; filePreview = nil; selectedFilePath = nil; expandedFileDirectories = []; selectedCommit = nil; historyPatch = nil
        errorMessage = nil; publication = nil; transferProgress.clear()
        preservedDirectory = nil
        isShowingResumePicker = false; refreshResumeRecords()
    }

    public func prefillSource(url: String) {
        guard !isBusy else { return }
        sourceURL = url
        selectedSourceURL = url
    }

    public func sourceURLChanged() {
        guard !isBusy else { return }
        selectedSourceURL = nil; listings = [:]; rootListingURL = nil; expandedURLs = []
        invalidatePlan()
    }

    /// 来源、目标或策略改变后，旧计划绝不能继续发布。
    public func invalidatePlan() {
        guard !isBusy else { return }
        plan = nil; clearPreview(); publication = nil; errorMessage = nil
        if stage != .form { stage = .form }
    }

    public func chooseDestinationParent() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择迁移结果保存位置"
        panel.message = "将在此位置创建一个新的 Git 工作副本；不会修改原 SVN 工作副本。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        if let destinationParent { panel.directoryURL = destinationParent }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationParent = url.standardizedFileURL.resolvingSymlinksInPath(); invalidatePlan()
    }

    public func browseRoot() {
        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isBusy else { errorMessage = "请先填写 SVN 来源地址。"; return }
        listings = [:]; rootListingURL = nil; expandedURLs = []; selectedSourceURL = nil
        browse(url: url, makesSelection: true)
    }

    public func toggleDirectory(_ entry: RemoteDirectoryEntry) {
        guard entry.isDirectory, !isBusy else { return }
        selectedSourceURL = entry.url; invalidatePlan()
        if expandedURLs.contains(entry.url) { expandedURLs.remove(entry.url) }
        else if listings[entry.url] != nil { expandedURLs.insert(entry.url) }
        else { browse(url: entry.url, makesSelection: true) }
    }
    public func toggleRoot() { guard let rootListingURL else { return }; if expandedURLs.contains(rootListingURL) { expandedURLs.remove(rootListingURL) } else { expandedURLs.insert(rootListingURL) } }
    public func selectDirectory(_ url: String) { guard !isBusy else { return }; selectedSourceURL = url; invalidatePlan() }

    public func updateAuthor(_ source: String, name: String, email: String) {
        guard let plan, !isBusy else { return }
        var authors = plan.authors; authors[source] = .init(name: name, email: email)
        self.plan = .init(source: plan.source, targetProviderID: plan.targetProviderID, remoteURL: plan.remoteURL,
                          branch: plan.branch, destination: plan.destination, authors: authors)
        clearPreview(); stage = .prepared; publication = nil
    }

    public func makePlan() {
        guard !isBusy else { return }
        let source = selectedSourceURL ?? sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { errorMessage = "请选择 SVN 仓库或其中一个目录。"; return }
        guard !targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "请填写目标 Git 地址。"; return }
        guard let destination else { errorMessage = "请选择本地父目录并填写新目录名。"; return }
        let location = sourceLocation, requestedMode = mode
        let requestedCopyHistory = requestedMode == .history && includeCopyHistory
        let remoteURL = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : branch
        let handler = progressHandler
        begin(.planning, message: "正在只读检查来源与目标…") { [service] in
            try await service.plan(sourceProviderID: .svn, location: location, mode: requestedMode,
                                   targetProviderID: .git, remoteURL: remoteURL, branch: requestedBranch,
                                   destination: destination, authors: [:], includeCopyHistory: requestedCopyHistory,
                                   progress: handler)
        } receive: { model, plan in
            let authors = model.authorDirectory.resolve(authors: plan.authors, sourceURL: plan.source.location.url)
            model.plan = MigrationPlan(id: plan.id, source: plan.source, targetProviderID: plan.targetProviderID,
                remoteURL: plan.remoteURL, branch: plan.branch, destination: plan.destination, authors: authors)
            model.clearPreview(); model.stage = .prepared; model.transferProgress.finish("迁移计划已生成")
        }
    }

    public func preparePreview() {
        guard let plan, !isBusy else { return }
        do { try authorDirectory.save(authors: plan.authors, sourceURL: plan.source.location.url) }
        catch { errorMessage = "无法保存作者映射：\(error.localizedDescription)"; return }
        let handler = progressHandler
        begin(.converting, message: "正在在隔离目录生成转换预览…") { [service] in
            try await service.prepare(plan, progress: handler)
        } receive: { model, preview in
            model.preview = preview; model.stage = .preview; model.transferProgress.finish("转换预览已就绪")
        }
    }

    /// 打开本机受限索引中的未完成作业；实际恢复仍交给服务层重新核验。
    public func resumeExistingMigration() {
        guard !isBusy else { return }
        refreshResumeRecords(); isShowingResumePicker = true
    }
    public func dismissResumePicker() { guard !isBusy else { return }; isShowingResumePicker = false }
    public func refreshResumeRecords() {
        resumeRecords = resumeStore.records(kind: .repository,
                                            searchRoots: [destinationParent, preservedDirectory?.deletingLastPathComponent()].compactMap { $0 })
    }
    /// 仅从列表移除索引，不删除保留目录或检查点。
    public func removeResumeRecord(_ record: MigrationResumeStore.Record) { resumeStore.remove(id: record.id, kind: .repository); refreshResumeRecords() }
    public func chooseResumeCheckpoint() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择迁移保留目录或检查点"
        panel.message = "可选择 .RepHub-migration-… 保留目录，或其中的 checkpoint.json。已显示隐藏文件；不会读取 SVN 凭据。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = preservedDirectory ?? resumeRecords.first?.checkpointURL.deletingLastPathComponent() ?? destinationParent
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        resume(from: MigrationResumeStore.checkpointURL(for: selected))
    }
    public func resume(from record: MigrationResumeStore.Record) { resume(from: record.checkpointURL) }
    private func resume(from checkpoint: URL) {
        let credentials = username.isEmpty && password.isEmpty ? nil : RepositoryCredentials(username: username, password: password)
        requestID += 1; let token = requestID
        stage = .planning; isCancelling = false; errorMessage = nil; isShowingResumePicker = false; transferProgress.begin("正在读取迁移检查点…")
        task = Task { [weak self, service] in
            do {
                let restored = try await service.resume(from: checkpoint, credentials: credentials)
                guard let self, self.requestID == token else { return }
                self.plan = restored; self.sourceURL = restored.source.location.url; self.selectedSourceURL = restored.source.location.url
                self.targetURL = restored.remoteURL; self.branch = restored.branch; self.mode = restored.source.mode
                self.includeCopyHistory = restored.source.includeCopyHistory
                self.destinationParent = restored.destination.deletingLastPathComponent(); self.directoryName = restored.destination.lastPathComponent
                self.preservedDirectory = await service.partialDirectory(for: restored.id)
                self.stage = .prepared; self.refreshResumeRecords(); self.transferProgress.finish("已恢复迁移计划，可继续生成预览")
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }; self.stage = .form; self.transferProgress.finish("恢复已取消")
            } catch {
                guard let self, self.requestID == token else { return }
                self.stage = .form; self.errorMessage = "无法恢复迁移：\(error.localizedDescription)"; self.refreshResumeRecords(); self.transferProgress.finish("无法恢复迁移")
            }
        }
    }

    public func loadFile(path: String) {
        guard let preview, !isBusy else { return }
        selectedFilePath = path; filePreview = nil
        previewTask?.cancel(); let token = requestID
        previewTask = Task { [weak self, service] in
            do {
                let item = try await service.filePreview(preview, path: path)
                guard let self, self.requestID == token, self.selectedFilePath == path else { return }
                self.filePreview = item
            } catch is CancellationError { } catch {
                guard let self, self.requestID == token, self.selectedFilePath == path else { return }
                self.errorMessage = "无法读取文件预览：\(error.localizedDescription)"
            }
        }
    }

    public func loadHistoryPatch(commit: String) {
        guard let preview, !isBusy else { return }
        selectedCommit = commit; historyPatch = nil
        previewTask?.cancel(); let token = requestID
        previewTask = Task { [weak self, service] in
            do {
                let patch = try await service.historyPatch(preview, commit: commit)
                guard let self, self.requestID == token, self.selectedCommit == commit else { return }
                self.historyPatch = patch
            } catch is CancellationError { } catch {
                guard let self, self.requestID == token, self.selectedCommit == commit else { return }
                self.errorMessage = "无法读取提交差异：\(error.localizedDescription)"
            }
        }
    }

    public func toggleFileDirectory(_ path: String) {
        if expandedFileDirectories.contains(path) { expandedFileDirectories.remove(path) }
        else { expandedFileDirectories.insert(path) }
    }

    public func publish() {
        guard let preview, preview.canPublish, !isBusy else { return }
        let handler = progressHandler
        begin(.publishing, message: "正在发布到目标 Git 远端…") { [service] in
            try await service.publish(preview, progress: handler)
        } receive: { model, result in
            model.publication = result; model.stage = result.state == .published ? .published : .preview
            model.transferProgress.finish(result.message)
        }
    }

    public func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true; task?.cancel(); previewTask?.cancel()
        transferProgress.consume(.init("正在请求停止，已生成的本地转换结果会保留…"))
    }

    public func dismiss() { guard !isBusy else { return }; reset() }
    public func revealPreservedDirectory() {
        guard let preservedDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([preservedDirectory])
    }
    public func clearPreview() { preview = nil; filePreview = nil; selectedFilePath = nil; selectedCommit = nil; historyPatch = nil }
    public func returnToPlan() {
        guard !isBusy, plan != nil else { return }
        clearPreview(); publication = nil; plan = nil; stage = .form
        errorMessage = "已保留上一份本地转换结果。调整后请换一个新的本地文件夹名称，再重新预检。"
    }

    private var progressHandler: RepositoryOperationProgressHandler {
        { [weak self] update in await MainActor.run { self?.transferProgress.consume(update) } }
    }

    private func browse(url: String, makesSelection: Bool) {
        requestID += 1; let token = requestID; isBrowsing = true; errorMessage = nil
        let credentials = sourceLocation.credentials
        task?.cancel()
        task = Task { [weak self, service] in
            do {
                let listing = try await service.browseSource(providerID: .svn, location: .init(url: url, credentials: credentials))
                guard let self, self.requestID == token else { return }
                self.listings[listing.url] = listing; if self.rootListingURL == nil { self.rootListingURL = listing.url }
                self.expandedURLs.insert(listing.url); if makesSelection { self.selectedSourceURL = listing.url }; self.isBrowsing = false
            } catch is CancellationError { guard let self, self.requestID == token else { return }; self.isBrowsing = false }
            catch { guard let self, self.requestID == token else { return }; self.isBrowsing = false; self.errorMessage = error.localizedDescription }
        }
    }

    private func begin<T: Sendable>(_ next: Stage, message: String,
                                    work: @escaping @Sendable () async throws -> T,
                                    receive: @escaping @MainActor (RepositoryMigrationModel, T) -> Void) {
        requestID += 1; let token = requestID; stage = next; isCancelling = false; errorMessage = nil; publication = nil; transferProgress.begin(message)
        task = Task { [weak self] in
            do {
                let result = try await work()
                guard let self, self.requestID == token else { return }
                self.isCancelling = false; receive(self, result)
            } catch is CancellationError {
                guard let self, self.requestID == token else { return }
                if let plan = self.plan { self.preservedDirectory = await self.service.partialDirectory(for: plan.id) }
                self.isCancelling = false; self.stage = self.preview == nil ? (self.plan == nil ? .form : .prepared) : .preview; self.errorMessage = "已取消。已生成的隔离目录会保留，可继续转换或检查。"; self.transferProgress.finish("迁移已取消")
            } catch {
                guard let self, self.requestID == token else { return }
                if let plan = self.plan { self.preservedDirectory = await self.service.partialDirectory(for: plan.id) }
                self.isCancelling = false; self.stage = self.preview == nil ? (self.plan == nil ? .form : .prepared) : .preview; self.errorMessage = error.localizedDescription; self.transferProgress.finish("迁移未完成")
            }
        }
    }
}
