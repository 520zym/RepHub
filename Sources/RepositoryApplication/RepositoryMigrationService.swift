import CryptoKit
import Foundation
import VersionControlCore

/// 只编排契约：源只读、目标隔离生成、逐修订核对、预览后显式发布。
public actor RepositoryMigrationService {
    private let sources: [any RepositoryMigrationSourceProvider]
    private let targets: [any RepositoryMigrationTargetProvider]
    private let prefetchEnabled: Bool
    private let writeGate: RepositoryWriteGate
    private var busy = false
    private var jobs: [UUID: Job] = [:]

    private struct Job {
        let plan: MigrationPlan
        let folder: URL
        var repository: URL
        var mappings: [MigrationMapping] = []
        var sourceTree: URL?
        var targetTree: URL?
        /// 来源清单在读取快照时生成。快速会话检查点直接复用，避免为保存检查点再读一遍全树。
        var sourceEntries: [MigrationFileEntry] = []
        var targetEntries: [MigrationFileEntry] = []
        /// true 表示中间修订由已核对对象会话完成，可能尚未落下物化 targetTree。
        var usesVerifiedSession = false
        var comparisons: [MigrationFileComparison] = []
        var omittedDirectories = Set<String>()
        var complete = false
    }

    /// 检查点不得包含凭据。它足够重建计划并重新核对磁盘上的转换对象，
    /// 但不能被移动到任意目录后拿来写入一个普通工作副本。
    private struct Report: Codable {
        let version: Int
        let planID: UUID
        let sourceURL: String
        let sourceRevision: String
        let mode: MigrationMode
        let includeCopyHistory: Bool?
        let targetURL: String
        let branch: String
        let expectedRevisionCount: Int
        let mappings: [MigrationMapping]
        let verified: Bool
        let warnings: [String]
    }

    private struct Checkpoint: Codable {
        let version: Int
        let plan: StoredPlan
        let mappings: [MigrationMapping]
        let sourceTreeName: String?
        let targetTreeName: String?
        let sourceEntries: [MigrationFileEntry]
        let targetEntries: [MigrationFileEntry]
        let omittedDirectories: [String]
        /// v2：已核对对象会话可在中间修订不保存完整 targetTree；恢复时必须重新导出核对。
        let verifiedObjectTree: Bool?
    }

    private struct StoredPlan: Codable {
        let id: UUID
        let sourceProviderID: ProviderID
        let sourceURL: String
        let anchor: String
        let mode: MigrationMode
        /// 缺失代表 v1 检查点，保持原来的跨 copy 历史范围。
        let includeCopyHistory: Bool?
        let revisions: [MigrationRevision]
        let warnings: [String]
        let targetProviderID: ProviderID
        let remoteURL: String
        let branch: String
        let destinationPath: String
        let authors: [String: MigrationAuthor]

        init(_ plan: MigrationPlan) {
            id = plan.id; sourceProviderID = plan.source.providerID; sourceURL = plan.source.location.url
            anchor = plan.source.anchor; mode = plan.source.mode; includeCopyHistory = plan.source.includeCopyHistory
            revisions = plan.source.revisions; warnings = plan.source.warnings
            targetProviderID = plan.targetProviderID; remoteURL = plan.remoteURL; branch = plan.branch
            destinationPath = plan.destination.standardizedFileURL.path; authors = plan.authors
        }

        func makePlan(credentials: RepositoryCredentials?) -> MigrationPlan {
            MigrationPlan(id: id,
                          source: MigrationSourcePlan(providerID: sourceProviderID,
                                                       location: RemoteRepositoryLocation(url: sourceURL, credentials: credentials),
                                                       anchor: anchor, mode: mode,
                                                       includeCopyHistory: includeCopyHistory ?? true,
                                                       revisions: revisions, warnings: warnings),
                          targetProviderID: targetProviderID, remoteURL: remoteURL, branch: branch,
                          destination: URL(fileURLWithPath: destinationPath), authors: authors)
        }
    }

    public init(sources: [any RepositoryMigrationSourceProvider], targets: [any RepositoryMigrationTargetProvider],
                writeGate: RepositoryWriteGate = RepositoryWriteGate()) {
        self.init(sources: sources, targets: targets, prefetchEnabled: true, writeGate: writeGate)
    }

    init(sources: [any RepositoryMigrationSourceProvider], targets: [any RepositoryMigrationTargetProvider],
         prefetchEnabled: Bool,
         writeGate: RepositoryWriteGate = RepositoryWriteGate()) {
        self.sources = sources; self.targets = targets; self.prefetchEnabled = prefetchEnabled; self.writeGate = writeGate
    }

    public func browseSource(providerID: ProviderID, location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        guard let provider = sources.first(where: { $0.id == providerID }) as? any RepositoryAcquisitionProvider else {
            throw VersionControlError.unsupported("此迁移来源不支持目录浏览。")
        }
        return try await provider.browseRemote(location)
    }

    public func plan(sourceProviderID: ProviderID, location: RemoteRepositoryLocation, mode: MigrationMode,
                     targetProviderID: ProviderID, remoteURL: String, branch: String, destination: URL,
                     authors: [String: MigrationAuthor] = [:],
                     includeCopyHistory: Bool = true,
                     progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPlan {
        try begin(); defer { busy = false }
        let destination = try validateDestination(destination)
        let source = try sourceProvider(sourceProviderID), target = try targetProvider(targetProviderID)
        let remote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectPasswordInURL(remote)
        try rejectPasswordInURL(location.url)
        await progress(RepositoryOperationProgress("检查目标仓库…"))
        try await target.checkMigrationTarget(remoteURL: remote, branch: branch)
        try Task.checkCancellation()
        await progress(RepositoryOperationProgress("正在读取固定来源历史…"))
        let sourcePlan = try await source.planMigration(from: location, mode: mode,
                                                         includeCopyHistory: includeCopyHistory, progress: progress)
        guard !sourcePlan.revisions.isEmpty, Set(sourcePlan.revisions.map(\.id)).count == sourcePlan.revisions.count else {
            throw VersionControlError.invalidData("来源没有可迁移的修订，或历史包含重复修订。")
        }
        await progress(RepositoryOperationProgress("正在整理提交人与 Git 作者映射…"))
        var mapping = authors
        for author in sourcePlan.revisions.map(\.author) where mapping[author] == nil {
            let digest = SHA256.hash(data: Data(author.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            mapping[author] = MigrationAuthor(name: author.isEmpty ? "SVN 未知作者" : author,
                                               email: "svn-\(digest)@authors.invalid")
        }
        try validateAuthors(mapping)
        await progress(RepositoryOperationProgress("只读预检完成，已读取 \(sourcePlan.revisions.count) 条来源修订。", fractionCompleted: 1))
        return MigrationPlan(source: sourcePlan, targetProviderID: targetProviderID, remoteURL: remote,
                             branch: branch, destination: destination, authors: mapping)
    }

    public func partialDirectory(for planID: UUID) -> URL? { jobs[planID]?.folder }

    public func prepare(_ plan: MigrationPlan, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPreview {
        try begin(); defer { busy = false }
        await progress(RepositoryOperationProgress("正在检查转换预览参数…"))
        let source = try sourceProvider(plan.source.providerID), target = try targetProvider(plan.targetProviderID)
        try validateAuthors(plan.authors)
        guard !plan.source.revisions.isEmpty,
              plan.source.revisions.allSatisfy({ plan.authors[$0.author] != nil }) else {
            throw VersionControlError.invalidData("迁移计划缺少历史或作者映射。")
        }
        var job: Job
        if let existing = jobs[plan.id] {
            guard samePlan(existing.plan, plan) else { throw VersionControlError.invalidData("转换参数已变化，请重新预检。") }
            job = existing
            if job.complete { try await verify(job, target: target); return preview(job) }
            // 第一次提交后、核对前中断也不能再次追加该修订，留下没有映射的隐藏根提交。
            try await target.verifyMigrationCheckpoint(at: job.repository, expectedTip: job.mappings.last?.targetCommit, branch: plan.branch)
            if !job.mappings.isEmpty {
                try await restoreVerifiedTargetTreeIfNeeded(&job, target: target)
                try await verify(job, target: target)
            }
        } else {
            let destination = try validateDestination(plan.destination)
            let folder = destination.deletingLastPathComponent().appendingPathComponent(".RepHub-migration-\(plan.id.uuidString)")
            guard !exists(folder) else { throw VersionControlError.invalidRepository("迁移暂存路径已存在，请重新预检。") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            job = Job(plan: plan, folder: folder, repository: folder.appendingPathComponent("repository"))
            // 初始化失败也保留目录供定位，重新预检会生成不同的暂存目录。
            await progress(RepositoryOperationProgress("正在初始化隔离 Git 预览仓库…"))
            try await target.initializeMigration(at: job.repository, branch: plan.branch)
            jobs[plan.id] = job
            // 空仓库也必须留下受限检查点；重启后可以安全恢复，且能识别首个提交
            // 已写入但尚未核对的窗口。
            try saveCheckpoint(job)
        }
        // 来源会话的缓存只服务于本次 prepare。恢复时重新从首个未完成修订建立会话，
        // 不相信上一次中断留下的 SVN 缓存；已经核对的 Git 检查点仍由上面的逻辑保护。
        let sourceCache = job.folder.appendingPathComponent("source-cache-\(UUID().uuidString)", isDirectory: true)
        // 缓存目录由来源适配器创建并拒绝复用；这里仅分配唯一、尚不存在的隔离路径。
        defer { try? FileManager.default.removeItem(at: sourceCache) }
        await progress(RepositoryOperationProgress("正在准备来源修订会话…"))
        let snapshotSession = try await source.makeMigrationSnapshotSession(plan: plan.source, in: sourceCache)
        let verifiedSession: (any RepositoryVerifiedMigrationSession)?
        if let verifiedTarget = target as? any RepositoryVerifiedMigrationTargetProvider {
            await progress(RepositoryOperationProgress("正在准备已核对 Git 对象会话…"))
            verifiedSession = try await verifiedTarget.makeVerifiedMigrationSession(at: job.repository)
        } else {
            verifiedSession = nil
        }
        let prefetchMux = verifiedSession != nil && prefetchEnabled ? MigrationPrefetchProgressMux(output: progress) : nil
        let prefetcher = prefetchMux.map { OnePageMigrationSnapshotPrefetcher(session: snapshotSession, workspace: job.folder, progress: $0) }
        do {
            let remaining = Array(plan.source.revisions.dropFirst(job.mappings.count))
            for (remainingIndex, revision) in remaining.enumerated() {
                try Task.checkCancellation()
                let index = job.mappings.count + 1
                let count = plan.source.revisions.count
                let sourceTree: URL
                if let prefetcher {
                    if remainingIndex > 0 {
                        await prefetchMux?.foreground(revisionProgress("正在等待预取来源修订", revision: revision, index: index, total: count))
                    }
                    if let prefetched = try await prefetcher.consume(revision) {
                        sourceTree = prefetched
                        await prefetchMux?.foreground(revisionProgress("正在使用后台预取来源修订", revision: revision, index: index, total: count))
                    } else {
                        sourceTree = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
                        let update = revisionProgress("正在准备来源修订", revision: revision, index: index, total: count)
                        if let prefetchMux { await prefetchMux.foreground(update) } else { await progress(update) }
                        try await snapshotSession.exportSnapshot(revision: revision, to: sourceTree) { update in
                            let mapped = self.revisionProgress("正在准备来源修订", revision: revision, index: index, total: count,
                                                               update: update, usesSourcePhase: true)
                            if let prefetchMux { await prefetchMux.foreground(mapped) } else { await progress(mapped) }
                        }
                    }
                } else {
                    sourceTree = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
                    let update = revisionProgress("正在准备来源修订", revision: revision, index: index, total: count)
                    if let prefetchMux { await prefetchMux.foreground(update) } else { await progress(update) }
                    try await snapshotSession.exportSnapshot(revision: revision, to: sourceTree) { update in
                        let mapped = self.revisionProgress("正在准备来源修订", revision: revision, index: index, total: count,
                                                           update: update, usesSourcePhase: true)
                        if let prefetchMux { await prefetchMux.foreground(mapped) } else { await progress(mapped) }
                    }
                }
                if let prefetcher, remaining.indices.contains(remainingIndex + 1) {
                    try await prefetcher.schedule(remaining[remainingIndex + 1])
                }
                try Task.checkCancellation()
                let scanning = revisionProgress("正在扫描来源快照", revision: revision, index: index, total: count)
                if let prefetchMux { await prefetchMux.foreground(scanning) } else { await progress(scanning) }
                let sourceFiles = try scan(sourceTree)
                try Task.checkCancellation()
                let commit: String
                let comparisons: [MigrationFileComparison]
                let targetTree: URL?
                let targetEntries: [MigrationFileEntry]
                if let verifiedSession {
                    let writing = revisionProgress("正在增量写入并核对 Git 对象", revision: revision, index: index, total: count)
                    if let prefetchMux { await prefetchMux.foreground(writing) } else { await progress(writing) }
                    commit = try await verifiedSession.appendVerifiedSnapshot(
                        from: sourceTree, files: sourceFiles, revision: revision,
                        author: plan.authors[revision.author]!
                    ) { update in
                        let mapped = self.revisionProgress("正在增量写入并核对 Git 对象", revision: revision, index: index, total: count,
                                                           update: update)
                        if let prefetchMux { await prefetchMux.foreground(mapped) } else { await progress(mapped) }
                    }
                    // 会话已完整核对 Git 树的路径、类型、权限和对象；最终修订仍会进行
                    // 一次实际导出、逐文件 SHA-256 比对，供预览和端到端校验使用。
                    comparisons = []
                    targetTree = nil
                    targetEntries = []
                } else {
                    let legacyTargetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
                    await progress(revisionProgress("正在写入 Git 快照", revision: revision, index: index, total: count))
                    commit = try await target.appendMigrationSnapshot(from: sourceTree, revision: revision,
                                                                        author: plan.authors[revision.author]!, to: job.repository) { update in
                        await progress(self.revisionProgress("正在写入 Git 快照", revision: revision, index: index, total: count,
                                                             update: update))
                    }
                    try Task.checkCancellation()
                    await progress(revisionProgress("正在读取 Git 对象树", revision: revision, index: index, total: count))
                    try await target.exportMigrationTree(at: job.repository, revision: commit, to: legacyTargetTree) { update in
                        await progress(self.revisionProgress("正在读取 Git 对象树", revision: revision, index: index, total: count,
                                                             update: update))
                    }
                    try Task.checkCancellation()
                    await progress(revisionProgress("正在扫描并核对文件", revision: revision, index: index, total: count))
                    let targetFiles = try scan(legacyTargetTree)
                    comparisons = compare(sourceFiles, targetFiles)
                    guard !comparisons.contains(where: { $0.state == .different }) else {
                        throw VersionControlError.invalidData("修订 \(revision.id) 的转换文件与源快照不一致，已停止；暂存内容保留在 \(job.folder.path)。")
                    }
                    targetTree = legacyTargetTree
                    targetEntries = targetFiles
                }
                let oldSource = job.sourceTree, oldTarget = job.targetTree
                job.sourceTree = sourceTree; job.targetTree = targetTree; job.comparisons = comparisons
                job.sourceEntries = sourceFiles
                job.targetEntries = targetEntries
                job.usesVerifiedSession = verifiedSession != nil
                job.mappings.append(MigrationMapping(source: revision, author: plan.authors[revision.author]!, targetCommit: commit))
                // Git 不保存空目录。快速会话中没有中间 targetTree，因此直接从本次
                // 完整来源清单推导所有没有文件/链接后代的目录，保留原有历史警告。
                job.omittedDirectories.formUnion(omittedDirectoryPaths(in: sourceFiles))
                // 检查点只在该修订实际对象树核对通过后推进。失败不把未核对提交算作完成。
                jobs[plan.id] = job
                try saveCheckpoint(job)
                if let oldSource { try? FileManager.default.removeItem(at: oldSource) }
                if let oldTarget { try? FileManager.default.removeItem(at: oldTarget) }
                let complete = revisionProgress("已转换来源修订", revision: revision, index: index, total: count, completed: true)
                if let prefetchMux { await prefetchMux.foreground(complete) } else { await progress(complete) }
            }
            if let prefetcher { await prefetcher.finish() }
            if verifiedSession != nil {
                try await materializeFinalVerifiedTree(&job, target: target, progress: progress)
                jobs[plan.id] = job
                try saveCheckpoint(job)
            }
            try Task.checkCancellation()
            await progress(RepositoryOperationProgress("正在核对最终隔离 Git 预览…", fractionCompleted: 1))
            try await verify(job, target: target)
            job.repository = try await moveVerifiedPreviewRepository(job.repository, to: plan.destination)
            job.complete = true
            jobs[plan.id] = job
            try saveReport(job, to: reportURL(job), verified: true)
            await progress(RepositoryOperationProgress("转换及逐修订核对完成，可以预览。", fractionCompleted: 1))
            return preview(job)
        } catch {
            if let prefetcher { await prefetcher.cancelAndDrain() }
            // 保留先前检查点。若最后一个提交未核对完成，继续前的 verify 会拒绝指针不一致。
            throw error
        }
    }

    public func filePreview(_ preview: MigrationPreview, path: String) throws -> MigrationFilePreview {
        guard let job = jobs[preview.id], job.complete, let item = job.comparisons.first(where: { $0.path == path }),
              let sourceTree = job.sourceTree, let targetTree = job.targetTree else {
            throw VersionControlError.invalidData("此路径不在已核对的转换结果中。")
        }
        let source = try readPreview(root: sourceTree, entry: item.source)
        let target = try readPreview(root: targetTree, entry: item.target)
        return MigrationFilePreview(sourceText: source.text, targetText: target.text,
                                    isBinary: source.binary || target.binary, isTruncated: source.truncated || target.truncated)
    }

    public func historyPatch(_ preview: MigrationPreview, commit: String) async throws -> RepositoryPatch {
        guard let job = jobs[preview.id], job.complete, job.mappings.contains(where: { $0.targetCommit == commit }) else {
            throw VersionControlError.invalidData("此提交不在已核对的转换结果中。")
        }
        return try await targetProvider(job.plan.targetProviderID).migrationPatch(at: job.repository, revision: commit)
    }

    public func publish(_ preview: MigrationPreview, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.publishUnlocked(preview, progress: progress)
        }
    }

    private func publishUnlocked(_ preview: MigrationPreview, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        try begin(); defer { busy = false }
        guard let job = jobs[preview.id], job.complete, preview.tip == job.mappings.last?.targetCommit,
              preview.canPublish, samePlan(job.plan, preview.plan) else {
            throw VersionControlError.invalidData("转换预览已失效，请重新核对。")
        }
        let target = try targetProvider(job.plan.targetProviderID)
        await progress(RepositoryOperationProgress("重新核对预览与实际仓库…"))
        try await verify(job, target: target)
        return try await target.publishMigration(at: job.repository, remoteURL: job.plan.remoteURL, branch: job.plan.branch,
                                                  expectedTip: preview.tip, progress: progress)
    }

    /// 只恢复本应用创建的、尚未搬到最终 destination 的迁移暂存目录。
    /// 该 API 不读取或持久化凭据；调用方在重启后按需重新提供本次会话凭据。
    public func resume(from checkpointURL: URL, credentials: RepositoryCredentials? = nil) async throws -> MigrationPlan {
        try begin(); defer { busy = false }
        let checkpointURL = checkpointURL.standardizedFileURL
        guard checkpointURL.isFileURL, checkpointURL.lastPathComponent == "checkpoint.json" else {
            throw VersionControlError.invalidRepository("只能恢复名为 checkpoint.json 的迁移检查点。")
        }
        let folder = checkpointURL.deletingLastPathComponent()
        let report = try decodeCheckpoint(at: checkpointURL)
        let plan = report.plan.makePlan(credentials: credentials)
        try validateAuthors(plan.authors)
        _ = try sourceProvider(plan.source.providerID); let target = try targetProvider(plan.targetProviderID)
        _ = try validateDestination(plan.destination) // 最终目录必须仍不存在且不位于工作副本内。
        try validateCheckpointContainer(folder: folder, checkpointURL: checkpointURL, planID: report.plan.id,
                                        destination: plan.destination)
        let repository = folder.appendingPathComponent("repository", isDirectory: true)
        try validateCheckpointChildren(folder: folder, repository: repository, checkpoint: report)
        try await target.verifyMigrationCheckpoint(at: repository, expectedTip: report.mappings.last?.targetCommit, branch: plan.branch)
        try validateMappings(report.mappings, against: plan)
        for mapping in report.mappings {
            // 除末端以外的映射也必须仍指向可读取的实际对象；不能只信任 JSON。
            _ = try await target.migrationPatch(at: repository, revision: mapping.targetCommit)
        }
        let sourceTree = try restoredTree(named: report.sourceTreeName, in: folder)
        var targetTree = try restoredTree(named: report.targetTreeName, in: folder)
        let restoredSourceEntries: [MigrationFileEntry]
        if let sourceTree {
            restoredSourceEntries = try scan(sourceTree)
            guard restoredSourceEntries == report.sourceEntries else { throw VersionControlError.invalidData("来源快照缓存已变化，不能恢复迁移。") }
        } else {
            guard report.sourceEntries.isEmpty else { throw VersionControlError.invalidData("来源快照检查点不完整。") }
            restoredSourceEntries = []
        }
        var restoredTargetEntries: [MigrationFileEntry]
        if let targetTree {
            restoredTargetEntries = try scan(targetTree)
            guard restoredTargetEntries == report.targetEntries else { throw VersionControlError.invalidData("目标快照缓存已变化，不能恢复迁移。") }
        } else {
            guard report.targetEntries.isEmpty else { throw VersionControlError.invalidData("目标快照检查点不完整。") }
            restoredTargetEntries = []
        }
        if !report.mappings.isEmpty {
            if targetTree == nil, report.verifiedObjectTree == true {
                guard sourceTree != nil,
                      let tip = report.mappings.last?.targetCommit else {
                    throw VersionControlError.invalidData("已核对对象检查点缺少可验证的来源状态。")
                }
                let restored = folder.appendingPathComponent("verified-\(UUID().uuidString)")
                try await target.exportMigrationTree(at: repository, revision: tip, to: restored)
                let actual = try scan(restored)
                let comparison = compare(restoredSourceEntries, actual)
                guard !comparison.contains(where: { $0.state == .different }) else {
                    throw VersionControlError.invalidData("恢复时 Git 实际对象树与来源清单不一致。")
                }
                targetTree = restored
                restoredTargetEntries = actual
            }
            guard targetTree != nil else { throw VersionControlError.invalidData("缺少已核对目标快照，不能恢复迁移。") }
            let current = try scan(repository, excludingRootGit: true).filter { $0.kind != .directory }
            let expected = restoredTargetEntries.filter { $0.kind != .directory }
            guard current == expected else { throw VersionControlError.invalidData("迁移仓库内容与检查点不一致，不能恢复。") }
        }
        let comparisons: [MigrationFileComparison]
        if sourceTree != nil, targetTree != nil { comparisons = compare(restoredSourceEntries, restoredTargetEntries) }
        else { comparisons = [] }
        jobs[plan.id] = Job(plan: plan, folder: folder, repository: repository, mappings: report.mappings,
                            sourceTree: sourceTree, targetTree: targetTree,
                            sourceEntries: report.sourceEntries,
                            targetEntries: restoredTargetEntries,
                            usesVerifiedSession: report.verifiedObjectTree == true,
                            comparisons: comparisons,
                            omittedDirectories: Set(report.omittedDirectories))
        return plan
    }

    private func begin() throws {
        guard !busy else { throw VersionControlError.unsupported("另一项迁移操作正在执行，请等待结束。") }
        busy = true
    }

    /// 隔离预览可以并发生成；只有把已核对的结果落到用户指定的最终目录时才占用写门禁。
    /// 目标存在性检查必须和 moveItem 位于同一临界区，防止另一窗口在检查后创建路径。
    private func moveVerifiedPreviewRepository(_ repository: URL, to destination: URL) async throws -> URL {
        try await writeGate.withExclusiveAccess { [self] in
            try await self.moveVerifiedPreviewRepositoryUnlocked(repository, to: destination)
        }
    }

    private func moveVerifiedPreviewRepositoryUnlocked(_ repository: URL, to destination: URL) throws -> URL {
        let destination = try validateDestination(destination)
        // moveItem 无覆盖；本地目标在耗时转换期间被创建也必须失败。
        try FileManager.default.moveItem(at: repository, to: destination)
        return destination
    }
    private func sourceProvider(_ id: ProviderID) throws -> any RepositoryMigrationSourceProvider {
        guard let value = sources.first(where: { $0.id == id }) else { throw VersionControlError.unsupported("尚未实现此来源的迁移。") }
        return value
    }
    private func targetProvider(_ id: ProviderID) throws -> any RepositoryMigrationTargetProvider {
        guard let value = targets.first(where: { $0.id == id }) else { throw VersionControlError.unsupported("尚未实现此目标的迁移。") }
        return value
    }

    private func validateAuthors(_ authors: [String: MigrationAuthor]) throws {
        for author in authors.values {
            guard !author.name.trimmingCharacters(in: .whitespaces).isEmpty, author.email.contains("@"),
                  !author.email.contains(" "), !author.name.contains("<"), !author.name.contains(">"),
                  !author.email.contains("<"), !author.email.contains(">"),
                  !(author.name + author.email).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VersionControlError.invalidData("作者姓名或邮箱无效，请调整作者映射。")
            }
        }
    }

    private nonisolated func revisionProgress(_ phase: String, revision: MigrationRevision, index: Int, total: Int,
                                  update: RepositoryOperationProgress? = nil, completed: Bool = false,
                                  usesSourcePhase: Bool = false) -> RepositoryOperationProgress {
        let safeTotal = max(1, total)
        let completedCount = completed ? index : max(0, index - 1)
        // SVN 会话会在首次检出、增量切换、本地导出之间切换。保留其阶段作为 UI
        // 主消息，令无传输统计的本地步骤能清掉上一个网络步骤的估算速度。
        let displayedPhase = usesSourcePhase ? (update?.message ?? phase) : phase
        return RepositoryOperationProgress("\(displayedPhase) · \(revision.id)",
                                           fractionCompleted: update?.fractionCompleted ?? (completed ? 1 : nil),
                                           detail: update?.detail ?? update?.message ?? "整体修订 \(index)/\(safeTotal)",
                                           records: update?.records ?? [],
                                           transferStatistics: update?.transferStatistics,
                                           migrationProgress: RepositoryMigrationProgress(completedRevisions: completedCount,
                                                                                          totalRevisions: safeTotal,
                                                                                          currentRevision: revision.id))
    }

    private func rejectPasswordInURL(_ text: String) throws {
        let components = URLComponents(string: text)
        let scheme = components?.scheme?.lowercased()
        guard components?.password == nil, components?.query == nil,
              !(["http", "https", "file"].contains(scheme ?? "") && components?.user != nil) else {
            throw VersionControlError.invalidData("迁移地址不能包含密码、HTTP 账号或查询令牌，请使用会话凭据或系统凭据助手。")
        }
    }

    private func validateDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0"), url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw VersionControlError.invalidRepository("请选择新的本地文件夹。")
        }
        let path = url.standardizedFileURL
        let parent = path.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(path.lastPathComponent)
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              !exists(resolved) else { throw VersionControlError.invalidRepository("本地目标必须不存在，且父目录必须已存在。") }
        var ancestor = parent
        while ancestor.path != "/" {
            if exists(ancestor.appendingPathComponent(".git")) || exists(ancestor.appendingPathComponent(".svn")) {
                throw VersionControlError.invalidRepository("请将迁移结果放在已有 Git／SVN 工作副本以外。")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return resolved
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func samePlan(_ a: MigrationPlan, _ b: MigrationPlan) -> Bool {
        a.source.providerID == b.source.providerID && a.source.location.url == b.source.location.url && a.source.anchor == b.source.anchor
        && a.source.mode == b.source.mode && a.source.includeCopyHistory == b.source.includeCopyHistory
        && a.source.revisions == b.source.revisions && a.authors == b.authors
        && a.targetProviderID == b.targetProviderID && a.remoteURL == b.remoteURL && a.branch == b.branch && a.destination == b.destination
    }

    private func omittedDirectoryPaths(in entries: [MigrationFileEntry]) -> Set<String> {
        let directories = Set(entries.lazy.filter { $0.kind == .directory }.map(\.path))
        guard !directories.isEmpty else { return [] }
        var materializedAncestors = Set<String>()
        for entry in entries where entry.kind != .directory {
            var components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            _ = components.popLast()
            var path = ""
            for component in components {
                path = path.isEmpty ? String(component) : path + "/" + component
                materializedAncestors.insert(path)
            }
        }
        return directories.subtracting(materializedAncestors)
    }

    /// 已核对对象会话的中间检查点不持久化完整 targetTree。恢复或同一服务重试时，
    /// 必须从实际 Git 提交重新导出并与已保存的来源清单逐项比对，不能只相信映射 JSON。
    private func restoreVerifiedTargetTreeIfNeeded(_ job: inout Job,
                                                   target: any RepositoryMigrationTargetProvider) async throws {
        guard job.usesVerifiedSession, job.targetTree == nil, let tip = job.mappings.last?.targetCommit else { return }
        guard let sourceTree = job.sourceTree else {
            throw VersionControlError.invalidData("已核对对象检查点缺少来源清单或快照，不能恢复。")
        }
        guard try scan(sourceTree) == job.sourceEntries else {
            throw VersionControlError.invalidData("来源快照缓存已变化，不能恢复已核对对象迁移。")
        }
        let targetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
        try await target.exportMigrationTree(at: job.repository, revision: tip, to: targetTree)
        let targetEntries = try scan(targetTree)
        let comparisons = compare(job.sourceEntries, targetEntries)
        guard !comparisons.contains(where: { $0.state == .different }) else {
            throw VersionControlError.invalidData("恢复时 Git 实际对象树与已核对来源清单不一致。")
        }
        job.targetTree = targetTree
        job.targetEntries = targetEntries
        job.comparisons = comparisons
    }

    /// 完成每修订的对象级校验后，仍以实际导出的最终 Git 树做一次字节级全树核对。
    private func materializeFinalVerifiedTree(_ job: inout Job,
                                              target: any RepositoryMigrationTargetProvider,
                                              progress: @escaping RepositoryOperationProgressHandler) async throws {
        guard let tip = job.mappings.last?.targetCommit, let sourceTree = job.sourceTree else {
            throw VersionControlError.invalidData("已核对对象迁移缺少最终来源快照。")
        }
        guard try scan(sourceTree) == job.sourceEntries else {
            throw VersionControlError.invalidData("最终来源快照在核对前已变化。")
        }
        let targetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
        await progress(RepositoryOperationProgress("正在导出最终 Git 对象树进行端到端核对…"))
        try await target.exportMigrationTree(at: job.repository, revision: tip, to: targetTree) { update in
            await progress(update)
        }
        try Task.checkCancellation()
        let targetEntries = try scan(targetTree)
        let comparisons = compare(job.sourceEntries, targetEntries)
        guard !comparisons.contains(where: { $0.state == .different }) else {
            throw VersionControlError.invalidData("最终 Git 实际对象树与来源快照不一致，已停止；暂存内容保留在 \(job.folder.path)。")
        }
        if let oldTarget = job.targetTree { try? FileManager.default.removeItem(at: oldTarget) }
        job.targetTree = targetTree
        job.targetEntries = targetEntries
        job.comparisons = comparisons
    }

    private func verify(_ job: Job, target: any RepositoryMigrationTargetProvider) async throws {
        guard let tip = job.mappings.last?.targetCommit, let targetTree = job.targetTree else {
            throw VersionControlError.invalidData("没有已核对的转换结果。")
        }
        try await target.verifyMigration(at: job.repository, expectedTip: tip, branch: job.plan.branch)
        // 检查工作副本所有文件，包括被忽略的未跟踪文件；不只依赖 git status。
        let current = try scan(job.repository, excludingRootGit: true).filter { $0.kind != .directory }
        let expected = try scan(targetTree).filter { $0.kind != .directory }
        guard current == expected else { throw VersionControlError.invalidData("本地转换结果已被修改，不能发布旧预览。") }
    }

    private func warnings(_ job: Job) -> [String] {
        var result = job.plan.source.warnings
        if job.plan.authors.values.contains(where: { $0.email.hasSuffix("@authors.invalid") }) {
            result.append("部分作者使用明确的占位邮箱 @authors.invalid，可返回调整作者映射。")
        }
        if !job.omittedDirectories.isEmpty {
            result.append("历史中有 \(job.omittedDirectories.count) 个目录路径无法作为独立空目录保存在 Git 中；目录属性也不会成为 Git 属性。")
        }
        return result
    }
    private func reportURL(_ job: Job) -> URL { job.repository.appendingPathComponent(".git/rephub-migration.json") }
    private func preview(_ job: Job) -> MigrationPreview {
        MigrationPreview(plan: job.plan, repository: job.repository, reportURL: reportURL(job), mappings: job.mappings,
                         files: job.comparisons, warnings: warnings(job))
    }
    private func saveReport(_ job: Job, to url: URL, verified: Bool) throws {
        let report = Report(version: 1, planID: job.plan.id, sourceURL: RepositoryDisplaySanitizer.redact(job.plan.source.location.url),
                            sourceRevision: job.plan.source.anchor, mode: job.plan.source.mode,
                            includeCopyHistory: job.plan.source.includeCopyHistory,
                            targetURL: RepositoryDisplaySanitizer.redact(job.plan.remoteURL), branch: job.plan.branch,
                            expectedRevisionCount: job.plan.source.revisions.count, mappings: job.mappings,
                            verified: verified, warnings: warnings(job))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func saveCheckpoint(_ job: Job) throws {
        try rejectPasswordInURL(job.plan.source.location.url)
        try rejectPasswordInURL(job.plan.remoteURL)
        let sourceEntries = job.sourceEntries.isEmpty ? (try job.sourceTree.map { try scan($0) } ?? []) : job.sourceEntries
        let targetEntries = job.targetEntries.isEmpty ? (try job.targetTree.map { try scan($0) } ?? []) : job.targetEntries
        let checkpoint = Checkpoint(version: 2, plan: StoredPlan(job.plan), mappings: job.mappings,
                                    sourceTreeName: job.sourceTree?.lastPathComponent,
                                    targetTreeName: job.targetTree?.lastPathComponent,
                                    sourceEntries: sourceEntries, targetEntries: targetEntries,
                                    omittedDirectories: job.omittedDirectories.sorted(),
                                    verifiedObjectTree: job.usesVerifiedSession)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(checkpoint).write(to: job.folder.appendingPathComponent("checkpoint.json"), options: .atomic)
    }

    private func decodeCheckpoint(at url: URL) throws -> Checkpoint {
        guard !isSymbolicLink(url) else { throw VersionControlError.invalidRepository("迁移检查点不能是符号链接。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(Checkpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == 1 || checkpoint.version == 2 else { throw VersionControlError.unsupported("此迁移检查点版本不受支持。") }
        try rejectPasswordInURL(checkpoint.plan.sourceURL); try rejectPasswordInURL(checkpoint.plan.remoteURL)
        return checkpoint
    }

    private func validateCheckpointContainer(folder: URL, checkpointURL: URL, planID: UUID, destination: URL) throws {
        guard !isSymbolicLink(folder), checkpointURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              folder.lastPathComponent == ".RepHub-migration-\(planID.uuidString)" else {
            throw VersionControlError.invalidRepository("迁移检查点不在其原始隔离目录中。")
        }
        let resolvedFolder = folder.resolvingSymlinksInPath()
        guard resolvedFolder == folder.standardizedFileURL else { throw VersionControlError.invalidRepository("迁移暂存目录不能包含符号链接。") }
        // prepare 固定把暂存目录创建在最终结果同级。只校验名称不足以防止把检查点
        // 移到另一个目录后伪造恢复目标；此处与 validateDestination 使用相同的规范化父目录。
        let expectedParent = destination.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let actualParent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard actualParent == expectedParent else {
            throw VersionControlError.invalidRepository("迁移检查点已移动，不能恢复到原目标以外的位置。")
        }
    }

    private func validateCheckpointChildren(folder: URL, repository: URL, checkpoint: Checkpoint) throws {
        guard exists(repository), !isSymbolicLink(repository), !isSymbolicLink(repository.appendingPathComponent(".git")) else {
            throw VersionControlError.invalidRepository("迁移暂存仓库无效或包含符号链接。")
        }
        for name in [checkpoint.sourceTreeName, checkpoint.targetTreeName].compactMap({ $0 }) {
            _ = try restoredTree(named: name, in: folder)
        }
    }

    private func restoredTree(named name: String?, in folder: URL) throws -> URL? {
        guard let name else { return nil }
        let sourcePrefix = "source-", targetPrefix = "verified-"
        guard (name.hasPrefix(sourcePrefix) || name.hasPrefix(targetPrefix)),
              UUID(uuidString: String(name.dropFirst(name.hasPrefix(sourcePrefix) ? sourcePrefix.count : targetPrefix.count))) != nil,
              !name.contains("/"), !name.contains("\\") else {
            throw VersionControlError.invalidRepository("迁移快照目录名称无效。")
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        guard exists(url), !isSymbolicLink(url), url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            throw VersionControlError.invalidRepository("迁移快照目录无效或包含符号链接。")
        }
        return url
    }

    private func validateMappings(_ mappings: [MigrationMapping], against plan: MigrationPlan) throws {
        guard mappings.count <= plan.source.revisions.count else { throw VersionControlError.invalidData("检查点提交映射数量无效。") }
        for (index, mapping) in mappings.enumerated() {
            guard mapping.source == plan.source.revisions[index], mapping.author == plan.authors[mapping.source.author],
                  isObjectID(mapping.targetCommit) else {
                throw VersionControlError.invalidData("检查点提交映射与固定来源历史不一致。")
            }
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isObjectID(_ value: String) -> Bool {
        let count = value.utf8.count
        return (count == 40 || count == 64) && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private func compare(_ source: [MigrationFileEntry], _ target: [MigrationFileEntry]) -> [MigrationFileComparison] {
        let left = Dictionary(uniqueKeysWithValues: source.map { ($0.path, $0) })
        let right = Dictionary(uniqueKeysWithValues: target.map { ($0.path, $0) })
        return Set(left.keys).union(right.keys).sorted().map { path in
            let s = left[path], t = right[path]
            let state: MigrationFileComparison.State = s == t ? .identical : (s?.kind == .directory && t == nil ? .omittedDirectory : .different)
            return MigrationFileComparison(path: path, source: s, target: t, state: state)
        }
    }

    private func scan(_ root: URL, excludingRootGit: Bool = false) throws -> [MigrationFileEntry] {
        let manager = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw VersionControlError.invalidData("迁移根目录不能是符号链接。")
        }
        var result: [MigrationFileEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                let name = child.lastPathComponent
                if excludingRootGit && prefix.isEmpty && name == ".git" { continue }
                guard ![".git", ".svn"].contains(name.lowercased()) else {
                    throw VersionControlError.unsupported("来源含嵌套版本控制元数据：\(prefix + name)。请调整迁移范围。")
                }
                let path = prefix + name
                let attributes = try manager.attributesOfItem(atPath: child.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    let link = try manager.destinationOfSymbolicLink(atPath: child.path)
                    result.append(MigrationFileEntry(path: path, kind: .symbolicLink, digest: hash(Data(link.utf8)), size: UInt64(link.utf8.count)))
                } else if type == .typeDirectory {
                    result.append(MigrationFileEntry(path: path, kind: .directory, digest: "", size: 0))
                    try visit(child, prefix: path + "/")
                } else if type == .typeRegular {
                    let handle = try FileHandle(forReadingFrom: child); defer { try? handle.close() }
                    var digest = SHA256()
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
                    result.append(MigrationFileEntry(path: path, kind: .file, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), size: size, executable: executable))
                } else { throw VersionControlError.unsupported("不能迁移特殊文件：\(path)") }
            }
        }
        try visit(root, prefix: "")
        return result.sorted { $0.path < $1.path }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func readPreview(root: URL, entry: MigrationFileEntry?) throws -> (text: String, binary: Bool, truncated: Bool) {
        guard let entry else { return ("此项未迁入目标", false, false) }
        if entry.kind == .directory { return ("目录", false, false) }
        let url = root.appendingPathComponent(entry.path)
        if entry.kind == .symbolicLink {
            return ("符号链接 → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)), false, false)
        }
        // 防止预览缓存被外部替换为链接，读到迁移范围之外的内容。
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw VersionControlError.invalidData("预览文件已经变化，请重新转换。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1024) ?? Data()
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return ("二进制或非 UTF-8 文件 · \(entry.size) 字节\nSHA-256: \(entry.digest)", true, entry.size > data.count)
        }
        return (text, false, entry.size > data.count)
    }
}
