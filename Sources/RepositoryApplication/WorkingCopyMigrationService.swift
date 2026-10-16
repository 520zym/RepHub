import CryptoKit
import Foundation
import VersionControlCore

/// 把已经存在的 SVN 工作副本安全地迁入 Git，或在 Git 继续演进后补迁 SVN 新修订。
/// 业务层只编排契约和文件校验，绝不执行或解析版本控制命令。
public actor WorkingCopyMigrationService {
    private let source: any RepositoryWorkingCopyMigrationSourceProvider
    private let target: any RepositoryWorkingCopyMigrationTargetProvider
    private let prefetchEnabled: Bool
    private var busy = false
    private var jobs: [UUID: Job] = [:]

    private struct Job {
        let plan: WorkingCopyMigrationPlan
        let folder: URL
        let repository: URL
        var mappings: [MigrationMapping]
        var leftTree: URL?
        var rightTree: URL?
        var files: [MigrationFileComparison] = []
        /// 调用 apply 前立即置位。若 apply 在 Git 已快进、记录尚未落盘时中断，
        /// 同一会话重试只能补全记录/发布，绝不重新导入差异。
        var applyStarted = false
        var applied = false
        var complete = false
    }

    /// 工作副本迁移预览只在隔离目录中写入。检查点不含凭据、来源缓存或用户工作副本
    /// 内容；它只记录已经由 Git 会话确认的提交，供同一固定计划安全续跑。
    private struct Checkpoint: Codable {
        let version: Int
        let plan: StoredPlan
        let mappings: [MigrationMapping]
        let repositoryName: String
    }

    private struct StoredPlan: Codable {
        let id: UUID
        let action: WorkingCopyMigrationAction
        let workingCopyPath: String
        let sourceURL: String
        let repositoryUUID: String
        let baseRevision: String
        let sourceProviderID: ProviderID
        let anchor: String
        let mode: MigrationMode
        let includeCopyHistory: Bool
        let revisions: [MigrationRevision]
        let warnings: [String]
        let remoteURL: String
        let branch: String
        let expectedGitTip: String?
        let previousRecord: WorkingCopyMigrationRecord?
        let authors: [String: MigrationAuthor]

        init(_ plan: WorkingCopyMigrationPlan) {
            id = plan.id; action = plan.action
            workingCopyPath = plan.workingCopy.directory.standardizedFileURL.path
            sourceURL = plan.workingCopy.sourceURL; repositoryUUID = plan.workingCopy.repositoryUUID
            baseRevision = plan.workingCopy.baseRevision
            sourceProviderID = plan.source.providerID; anchor = plan.source.anchor; mode = plan.source.mode
            includeCopyHistory = plan.source.includeCopyHistory; revisions = plan.source.revisions; warnings = plan.source.warnings
            remoteURL = plan.remoteURL; branch = plan.branch; expectedGitTip = plan.expectedGitTip
            previousRecord = plan.previousRecord; authors = plan.authors
        }

        func makePlan() -> WorkingCopyMigrationPlan {
            WorkingCopyMigrationPlan(id: id, action: action,
                                     workingCopy: MigrationWorkingCopyInfo(directory: URL(fileURLWithPath: workingCopyPath),
                                                                          sourceURL: sourceURL, repositoryUUID: repositoryUUID,
                                                                          baseRevision: baseRevision),
                                     source: MigrationSourcePlan(providerID: sourceProviderID,
                                                                 location: RemoteRepositoryLocation(url: sourceURL), anchor: anchor,
                                                                 mode: mode, includeCopyHistory: includeCopyHistory,
                                                                 revisions: revisions, warnings: warnings),
                                     remoteURL: remoteURL, branch: branch, expectedGitTip: expectedGitTip,
                                     previousRecord: previousRecord, authors: authors)
        }
    }

    public init(source: any RepositoryWorkingCopyMigrationSourceProvider,
                target: any RepositoryWorkingCopyMigrationTargetProvider) {
        self.init(source: source, target: target, prefetchEnabled: true)
    }

    init(source: any RepositoryWorkingCopyMigrationSourceProvider,
         target: any RepositoryWorkingCopyMigrationTargetProvider,
         prefetchEnabled: Bool) {
        self.source = source; self.target = target; self.prefetchEnabled = prefetchEnabled
    }

    public func partialDirectory(for planID: UUID) -> URL? { jobs[planID]?.folder }

    /// 只恢复新版持久检查点。旧临时目录没有可核对的固定计划，不能从 Git 提交说明
    /// 自动推断后续范围；调用方应将返回的计划交给 `prepare` 继续执行。
    public func resume(from checkpointURL: URL) async throws -> WorkingCopyMigrationPlan {
        try begin(); defer { busy = false }
        let checkpoint = try decodeCheckpoint(at: checkpointURL)
        let plan = checkpoint.plan.makePlan()
        guard plan.action == .initial else {
            throw VersionControlError.unsupported("补迁暂不支持断点恢复；请重新预检，避免重复应用 Git 差异。")
        }
        try validatePlan(plan)
        guard plan.source.providerID == source.id else {
            throw VersionControlError.invalidData("迁移检查点的 SVN 来源类型与当前服务不一致。")
        }
        let folder = checkpointURL.deletingLastPathComponent().standardizedFileURL
        try validateCheckpointContainer(folder: folder, checkpointURL: checkpointURL, planID: plan.id)
        let repository = folder.appendingPathComponent(checkpoint.repositoryName, isDirectory: true)
        guard repository.standardizedFileURL.deletingLastPathComponent() == folder,
              !isLink(repository) else { throw VersionControlError.invalidRepository("迁移检查点的预览仓库路径无效。") }
        let current = try await source.inspectMigrationWorkingCopy(at: plan.workingCopy.directory, requireClean: true)
        try validateWorkingCopy(current, against: plan.workingCopy)
        try await source.verifyWorkingCopyMigrationSource(plan.source.location, repositoryUUID: plan.workingCopy.repositoryUUID,
                                                           revision: plan.source.anchor)
        let expected = try await target.inspectWorkingCopyMigrationTarget(at: plan.workingCopy.directory,
                                                                            branch: plan.branch, previousMigrationTip: nil)
        guard expected == plan.expectedGitTip else { throw VersionControlError.invalidRepository("当前工作副本 Git 状态已变化，不能恢复迁移。") }
        try validateCheckpointMappings(checkpoint.mappings, against: plan)
        try await target.verifyMigrationCheckpoint(at: repository, expectedTip: checkpoint.mappings.last?.targetCommit,
                                                   branch: plan.branch)
        try await verifyRecoveredCheckpointContent(plan: plan, mappings: checkpoint.mappings,
                                                   repository: repository)
        jobs[plan.id] = Job(plan: plan, folder: folder, repository: repository, mappings: checkpoint.mappings)
        return plan
    }

    public func readRecord(at directory: URL) throws -> WorkingCopyMigrationRecord? {
        let root = try validatedWorkingCopyDirectory(directory)
        let metadata = root.appendingPathComponent(".git", isDirectory: true)
        guard !isLink(metadata) else { throw VersionControlError.invalidRepository("Git 元数据不能是符号链接。") }
        let file = metadata.appendingPathComponent("rephub-svn-migration.json")
        guard exists(file) else { return nil }
        guard !isLink(file) else { throw VersionControlError.invalidRepository("迁移记录不能是符号链接。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkingCopyMigrationRecord.self, from: Data(contentsOf: file))
        guard record.version == 1, !record.sourceURL.isEmpty, !record.repositoryUUID.isEmpty,
              !record.startRevision.isEmpty, !record.cutoverRevision.isEmpty, !record.lastRevision.isEmpty, !record.remoteURL.isEmpty,
              !record.branch.isEmpty, !record.mappings.isEmpty,
              validRecordRevisions(record) else {
            throw VersionControlError.invalidData("本地 SVN 迁移记录无效。")
        }
        try rejectCredentialURL(record.sourceURL); try rejectCredentialURL(record.remoteURL)
        return record
    }

    /// 只读检查 SVN 源端是否出现了尚未补迁的修订。没有迁移记录时绝不访问网络。
    /// 检查开始与结束都会重新核对本地记录，避免迁移过程中把旧结论提示给用户。
    public func checkForSourceUpdates(at directory: URL) async throws -> MigrationSourceUpdateCheck {
        guard !busy else { return .skippedBusy }
        try begin(); defer { busy = false }
        let root = try validatedWorkingCopyDirectory(directory)
        guard let before = try readRecord(at: root) else { return .noMigrationRecord }
        let current = try await source.inspectMigrationWorkingCopy(at: root, requireClean: false)
        guard current.sourceURL == before.sourceURL, current.repositoryUUID == before.repositoryUUID else {
            throw VersionControlError.invalidData("当前 SVN 工作副本与迁移记录的来源地址或仓库 UUID 不一致。")
        }
        try await source.verifyWorkingCopyMigrationSource(
            RemoteRepositoryLocation(url: before.sourceURL),
            repositoryUUID: before.repositoryUUID,
            revision: before.lastRevision
        )
        guard let historyProvider = source as? any VersionControlProvider else {
            throw VersionControlError.unsupported("当前 SVN 迁移来源不支持只读历史检查。")
        }
        let binding = RepositoryBinding(
            providerID: historyProvider.id,
            providerName: historyProvider.displayName,
            root: root,
            remoteURL: before.sourceURL,
            capabilities: [.history]
        )
        guard let latest = try await historyProvider.history(in: binding, limit: 1, reference: nil).first else {
            throw VersionControlError.invalidData("源 SVN 未返回可比较的最新修订。")
        }
        guard let migratedNumber = revisionNumber(before.lastRevision),
              let latestNumber = revisionNumber(latest.id) else {
            throw VersionControlError.invalidData("SVN 修订号无法按数值比较。")
        }
        guard let after = try readRecord(at: root), sameRecord(before, after) else {
            throw VersionControlError.invalidData("检查期间迁移记录已变化，请重新检查。")
        }
        // 记录的 lastRevision 是全仓库截止版本；目录的最后变更可能更早。
        // 上面已验证该截止版本仍存在，倒退检测以实际迁入的目录提交为下界。
        guard let importedNumber = before.mappings.last.flatMap({ revisionNumber($0.source.id) }) else {
            throw VersionControlError.invalidData("迁移记录缺少可比较的末端目录修订。")
        }
        if latestNumber < importedNumber {
            throw VersionControlError.invalidData("源 SVN 最新修订早于已迁移修订，无法确认来源历史连续性。")
        }
        if latestNumber > migratedNumber {
            return .update(MigrationSourceUpdate(
                directory: root, sourceURL: before.sourceURL, repositoryUUID: before.repositoryUUID,
                migratedRevision: before.lastRevision, latestRevision: latest.id
            ))
        }
        return .current(migratedRevision: before.lastRevision, checkedAt: Date())
    }

    public func plan(at directory: URL, remoteURL: String, branch: String, mode: MigrationMode,
                     action: WorkingCopyMigrationAction,
                     includeCopyHistory: Bool = true,
                     progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkingCopyMigrationPlan {
        try begin(); defer { busy = false }
        await progress(RepositoryOperationProgress("正在读取当前工作副本迁移记录…"))
        let root = try validatedWorkingCopyDirectory(directory)
        let remote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectCredentialURL(remote)
        let previous = try readRecord(at: root)
        switch action {
        case .initial:
            guard previous == nil else { throw VersionControlError.invalidRepository("此目录已有 SVN→Git 迁移记录，请使用补迁。") }
        case .supplement:
            guard let previous else { throw VersionControlError.invalidRepository("未找到初次迁移记录，不能补迁。") }
            guard previous.remoteURL == remote, previous.branch == branch else {
                throw VersionControlError.invalidData("补迁必须使用初次迁移记录中的 Git 地址和分支。")
            }
        }
        await progress(RepositoryOperationProgress("正在核对 SVN 工作副本状态…"))
        let info = try await source.inspectMigrationWorkingCopy(at: root, requireClean: action == .initial)
        try rejectCredentialURL(info.sourceURL)
        if let previous {
            guard previous.sourceURL == info.sourceURL, previous.repositoryUUID == info.repositoryUUID else {
                throw VersionControlError.invalidData("当前 SVN 工作副本与初次迁移来源不一致。")
            }
        }
        if action == .supplement, let previous {
            await progress(RepositoryOperationProgress("正在核对已有 SVN→Git 迁移记录…"))
            try await target.verifyWorkingCopyMigrationRecord(at: root, record: previous)
        }
        await progress(RepositoryOperationProgress("正在核对本地 Git 工作区和目标分支…"))
        let expected = try await target.inspectWorkingCopyMigrationTarget(at: root, branch: branch,
                                                                            previousMigrationTip: previous?.mappings.last?.targetCommit)
        if action == .initial, expected != nil { throw VersionControlError.invalidRepository("首次迁移要求目录尚未由 Git 管理。") }
        // 补迁允许 Git 在上次迁移后继续提交；目标适配器负责确认旧迁移末端仍是
        // 当前 HEAD 的祖先，并返回当前 HEAD 作为这次三方应用的基线。
        await progress(RepositoryOperationProgress("正在确认目标 Git 仓库状态…"))
        try await target.checkWorkingCopyMigrationRemote(remoteURL: remote, branch: branch, expectedTip: expected)
        // 首次迁移严格以当前 SVN BASE 为接管点；补迁必须读取远端 HEAD，不能要求
        // 用户先 update 本地 SVN 工作副本，否则会遗漏远端后来新增的修订。
        let through = action == .initial ? info.baseRevision : nil
        await progress(RepositoryOperationProgress("正在读取固定 SVN 历史范围…"))
        let sourcePlan = try await source.planWorkingCopyHistory(from: RemoteRepositoryLocation(url: info.sourceURL), mode: mode,
                                                                  through: through, after: previous?.lastRevision,
                                                                  includeCopyHistory: includeCopyHistory,
                                                                  progress: progress)
        guard sourcePlan.providerID == source.id, sourcePlan.location.url == info.sourceURL,
              (action == .supplement || sourcePlan.anchor == info.baseRevision),
              !sourcePlan.revisions.isEmpty,
              Set(sourcePlan.revisions.map(\.id)).count == sourcePlan.revisions.count else {
            throw VersionControlError.invalidData("没有可迁移的 SVN 修订，或历史修订重复。")
        }
        await progress(RepositoryOperationProgress("正在复核固定 SVN 来源身份…"))
        try await source.verifyWorkingCopyMigrationSource(sourcePlan.location, repositoryUUID: info.repositoryUUID,
                                                           revision: sourcePlan.anchor)
        if let previous, sourcePlan.revisions.contains(where: { $0.id == previous.lastRevision }) {
            throw VersionControlError.invalidData("补迁历史包含已经迁入的末端修订。")
        }
        await progress(RepositoryOperationProgress("正在整理 SVN 提交人与 Git 作者映射…"))
        var authors: [String: MigrationAuthor] = [:]
        for name in sourcePlan.revisions.map(\.author) {
            let digest = SHA256.hash(data: Data(name.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            authors[name] = MigrationAuthor(name: name.isEmpty ? "SVN 未知作者" : name,
                                            email: "svn-\(digest)@authors.invalid")
        }
        try validateAuthors(authors)
        await progress(RepositoryOperationProgress("只读预检完成，已读取 \(sourcePlan.revisions.count) 条 SVN 修订。", fractionCompleted: 1))
        return WorkingCopyMigrationPlan(action: action, workingCopy: info, source: sourcePlan, remoteURL: remote,
                                        branch: branch, expectedGitTip: expected, previousRecord: previous, authors: authors)
    }

    public func prepare(_ plan: WorkingCopyMigrationPlan,
                        progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkingCopyMigrationPreview {
        try begin(); defer { busy = false }
        await progress(RepositoryOperationProgress("正在检查转换预览参数…"))
        try validatePlan(plan)
        await progress(RepositoryOperationProgress("正在复核本地 SVN 工作副本状态…"))
        let root = try validatedWorkingCopyDirectory(plan.workingCopy.directory)
        let current = try await source.inspectMigrationWorkingCopy(at: root, requireClean: plan.action == .initial)
        try validateWorkingCopy(current, against: plan.workingCopy)
        await progress(RepositoryOperationProgress("正在复核固定 SVN 来源身份…"))
        try await source.verifyWorkingCopyMigrationSource(plan.source.location, repositoryUUID: plan.workingCopy.repositoryUUID,
                                                           revision: plan.source.anchor)
        if plan.action == .supplement, let previous = plan.previousRecord {
            await progress(RepositoryOperationProgress("正在复核上次迁移记录…"))
            try await target.verifyWorkingCopyMigrationRecord(at: root, record: previous)
        }
        await progress(RepositoryOperationProgress("正在复核本地 Git 基线…"))
        let expected = try await target.inspectWorkingCopyMigrationTarget(at: root, branch: plan.branch,
                                                                            previousMigrationTip: plan.previousRecord?.mappings.last?.targetCommit)
        guard expected == plan.expectedGitTip else { throw VersionControlError.invalidRepository("工作副本 Git 状态已变化，请重新预检。") }
        if var existing = jobs[plan.id] {
            guard same(existing.plan, plan) else { throw VersionControlError.invalidData("迁移计划与已保留的隔离检查点不一致。") }
            if existing.complete { return try await existingPreview(existing, plan: plan) }
            guard plan.action == .initial else {
                throw VersionControlError.unsupported("补迁暂不支持断点恢复；请重新预检，避免重复应用 Git 差异。")
            }
            // 第一次 prepare 在目标适配器创建隔离仓库前失败时，folder 虽已登记但
            // repository 尚不存在；此时没有任何 Git 写入，可在同一隔离目录安全重试。
            // 一旦 repository 已存在却没有映射检查点，不能猜测其中是否有未核对提交。
            if existing.mappings.isEmpty && !exists(existing.repository) {
                await progress(RepositoryOperationProgress("正在重新准备隔离 Git 预览仓库…"))
                try await target.prepareWorkingCopyMigrationTarget(from: root, expectedTip: plan.expectedGitTip,
                                                                    to: existing.repository, branch: plan.branch)
            } else {
                guard exists(checkpointURL(existing)) else {
                    throw VersionControlError.invalidRepository("隔离 Git 预览缺少可信检查点，不能继续迁移。")
                }
                await progress(RepositoryOperationProgress("正在核对已验证的 Git 迁移检查点…"))
                try await target.verifyMigrationCheckpoint(at: existing.repository,
                                                           expectedTip: existing.mappings.last?.targetCommit,
                                                           branch: plan.branch)
            }
            await progress(RepositoryOperationProgress("正在从已验证的 \(existing.mappings.count) 条提交继续迁移…"))
            do {
                try await prepareInitial(&existing, progress: progress)
                existing.complete = true; jobs[plan.id] = existing
                try saveCheckpoint(existing)
                return preview(existing)
            } catch {
                jobs[plan.id] = existing
                throw error
            }
        }
        // 预览仅为应用内部临时状态，不在用户工程父目录累积隐藏工作目录。
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-working-copy-migration-\(plan.id.uuidString)", isDirectory: true)
        guard !exists(folder) else { throw VersionControlError.invalidRepository("迁移暂存路径已存在，请重新预检。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let repository = folder.appendingPathComponent("repository", isDirectory: true)
        var job = Job(plan: plan, folder: folder, repository: repository, mappings: plan.previousRecord?.mappings ?? [])
        // 即使预览仓库准备、导出、冲突或核对失败，也让调用方能定位隔离结果；但不把它当作可用预览。
        jobs[plan.id] = job
        do {
            await progress(RepositoryOperationProgress("正在准备隔离 Git 预览仓库…"))
            try await target.prepareWorkingCopyMigrationTarget(from: root, expectedTip: plan.expectedGitTip, to: repository, branch: plan.branch)
            if plan.action == .initial {
                try await prepareInitial(&job, progress: progress)
            } else {
                try await prepareSupplement(&job, progress: progress)
            }
            job.complete = true; jobs[plan.id] = job
            if plan.action == .initial { try saveCheckpoint(job) }
            return preview(job)
        } catch { jobs[plan.id] = job; throw error }
    }

    public func filePreview(_ preview: WorkingCopyMigrationPreview, path: String) throws -> MigrationFilePreview {
        guard let job = jobs[preview.id], job.complete, preview.tip == job.mappings.last?.targetCommit,
              let item = job.files.first(where: { $0.path == path }), let left = job.leftTree, let right = job.rightTree else {
            throw VersionControlError.invalidData("此文件不在当前迁移预览中。")
        }
        let first = try previewFile(root: left, entry: item.source)
        let second = try previewFile(root: right, entry: item.target)
        return MigrationFilePreview(sourceText: first.text, targetText: second.text,
                                    isBinary: first.binary || second.binary, isTruncated: first.truncated || second.truncated)
    }

    public func historyPatch(_ preview: WorkingCopyMigrationPreview, commit: String) async throws -> RepositoryPatch {
        guard let job = jobs[preview.id], job.complete, job.mappings.contains(where: { $0.targetCommit == commit }) else {
            throw VersionControlError.invalidData("此提交不属于当前迁移预览。")
        }
        return try await target.migrationPatch(at: job.repository, revision: commit)
    }

    public func applyAndPublish(_ preview: WorkingCopyMigrationPreview,
                                progress: @escaping RepositoryOperationProgressHandler) async throws -> WorkingCopyMigrationResult {
        try begin(); defer { busy = false }
        guard var job = jobs[preview.id], job.complete, same(job.plan, preview.plan), preview.tip == job.mappings.last?.targetCommit,
              !preview.tip.isEmpty else { throw VersionControlError.invalidData("迁移预览已失效，请重新生成。") }
        try validatePreview(job)
        let root = try validatedWorkingCopyDirectory(job.plan.workingCopy.directory)
        let current = try await source.inspectMigrationWorkingCopy(at: root, requireClean: job.plan.action == .initial)
        try validateWorkingCopy(current, against: job.plan.workingCopy)
        try await source.verifyWorkingCopyMigrationSource(job.plan.source.location, repositoryUUID: job.plan.workingCopy.repositoryUUID,
                                                           revision: job.plan.source.anchor)
        if !job.applied {
            if job.plan.action == .initial { try validateInitialWorkingTree(job) }
            let record = WorkingCopyMigrationRecord(sourceURL: job.plan.workingCopy.sourceURL,
                                                    repositoryUUID: job.plan.workingCopy.repositoryUUID,
                                                    startRevision: job.plan.previousRecord?.startRevision ?? job.plan.source.revisions[0].id,
                                                    lastRevision: job.plan.source.anchor, remoteURL: job.plan.remoteURL,
                                                    branch: job.plan.branch, mappings: job.mappings,
                                                    cutoverRevision: job.plan.previousRecord?.cutoverRevision ?? job.plan.workingCopy.baseRevision)
            // 首次安装是原子的：仅在 .git 已出现时检查已应用末端；安装之前的失败
            // 仍走未受 Git 管理的检查，允许重试。
            let inspectionAnchor: String? = job.applyStarted && job.plan.action == .initial && exists(root.appendingPathComponent(".git"))
                ? preview.tip : job.plan.previousRecord?.mappings.last?.targetCommit
            let expected = try await target.inspectWorkingCopyMigrationTarget(at: root, branch: job.plan.branch,
                                                                                previousMigrationTip: inspectionAnchor)
            let localAlreadyApplied = job.applyStarted && expected == preview.tip
            guard expected == job.plan.expectedGitTip || localAlreadyApplied else {
                throw VersionControlError.invalidRepository("应用前 Git 指针已变化，请重新预检。")
            }
            // 仅当 Git 尚处于应用前状态时验证旧记录。若上次 apply 已写入新 HEAD，
            // Git 适配器会在下面补写新记录，不能把它错误地当作旧记录损坏。
            if !localAlreadyApplied, job.plan.action == .supplement, let previous = job.plan.previousRecord {
                try await target.verifyWorkingCopyMigrationRecord(at: root, record: previous)
            }
            // 先确保远端仍是预检时的状态；失败时不可先把本地工作副本写入 Git。
            try await target.checkWorkingCopyMigrationRemote(remoteURL: job.plan.remoteURL, branch: job.plan.branch,
                                                              expectedTip: job.plan.expectedGitTip)
            if localAlreadyApplied && job.plan.action == .initial {
                // 首次安装已把记录随 .git 一起移入；补迁则仍交给适配器补写记录，
                // 因为快进与记录写入之间可能发生中断。
                guard let installed = try readRecord(at: root), installed.lastRevision == record.lastRevision,
                      installed.sourceURL == record.sourceURL, installed.repositoryUUID == record.repositoryUUID,
                      installed.remoteURL == record.remoteURL, installed.branch == record.branch,
                      installed.mappings.map(\.targetCommit) == record.mappings.map(\.targetCommit) else {
                    throw VersionControlError.invalidData("首次迁移已安装的 Git 记录与预览不一致。")
                }
                try await target.verifyWorkingCopyMigrationRecord(at: root, record: record)
                job.applied = true; jobs[preview.id] = job
                let publication = try await target.publishWorkingCopyMigration(at: root, remoteURL: job.plan.remoteURL,
                                                                                 branch: job.plan.branch, expectedBeforeTip: job.plan.expectedGitTip,
                                                                                 expectedTip: preview.tip, progress: progress)
                return WorkingCopyMigrationResult(directory: root, publication: publication)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            job.applyStarted = true; jobs[preview.id] = job
            try await target.applyWorkingCopyMigration(from: job.repository, to: root, expectedBeforeTip: job.plan.expectedGitTip,
                                                       expectedTip: preview.tip, branch: job.plan.branch,
                                                       record: try encoder.encode(record))
            // 当前工作副本允许保留 SVN 未跟踪文件，不能使用要求零 status 的通用 Git
            // 校验；改为迁移专用的 HEAD/分支/记录检查。
            let confirmed = try await target.inspectWorkingCopyMigrationTarget(at: root, branch: job.plan.branch,
                                                                                previousMigrationTip: preview.tip)
            guard confirmed == preview.tip else { throw VersionControlError.invalidRepository("本地 Git 未确认到迁移末端。") }
            try await target.verifyWorkingCopyMigrationRecord(at: root, record: record)
            job.applied = true; jobs[preview.id] = job
        }
        let publication = try await target.publishWorkingCopyMigration(at: root, remoteURL: job.plan.remoteURL,
                                                                         branch: job.plan.branch, expectedBeforeTip: job.plan.expectedGitTip,
                                                                         expectedTip: preview.tip, progress: progress)
        return WorkingCopyMigrationResult(directory: root, publication: publication)
    }
}

private extension WorkingCopyMigrationService {
    private func prepareInitial(_ job: inout Job, progress: @escaping RepositoryOperationProgressHandler) async throws {
        let sourceCache = job.folder.appendingPathComponent("source-cache-\(UUID().uuidString)", isDirectory: true)
        // 缓存目录由来源适配器创建并拒绝复用；业务层只分配唯一隔离路径。
        defer { try? FileManager.default.removeItem(at: sourceCache) }
        await progress(RepositoryOperationProgress("正在准备来源修订会话…"))
        let snapshotSession = try await source.makeMigrationSnapshotSession(
            plan: job.plan.source,
            in: sourceCache,
            seedWorkingCopy: job.plan.workingCopy.directory
        )
        let verifiedSession: (any RepositoryVerifiedMigrationSession)?
        if let verifiedTarget = target as? any RepositoryVerifiedMigrationTargetProvider {
            await progress(RepositoryOperationProgress("正在准备已核对 Git 对象会话…"))
            verifiedSession = try await verifiedTarget.makeVerifiedMigrationSession(at: job.repository)
        } else {
            verifiedSession = nil
        }
        let plan = job.plan
        let totalRevisions = plan.source.revisions.count
        guard job.mappings.count <= totalRevisions else {
            throw VersionControlError.invalidData("迁移检查点的已完成提交数超出固定 SVN 计划。")
        }
        let revisions = Array(plan.source.revisions.dropFirst(job.mappings.count))
        let prefetchMux = verifiedSession != nil && prefetchEnabled ? MigrationPrefetchProgressMux(output: progress) : nil
        let prefetcher = prefetchMux.map { OnePageMigrationSnapshotPrefetcher(session: snapshotSession, workspace: job.folder, progress: $0) }
        do {
        for (offset, revision) in revisions.enumerated() {
            try Task.checkCancellation()
            let index = job.mappings.count + 1
            let sourceTree: URL
            if let prefetcher, let prefetchMux {
                if offset > 0 {
                    await prefetchMux.foreground(revisionProgress("正在等待预取来源修订", revision: revision, index: index, total: totalRevisions))
                }
                if let prefetched = try await prefetcher.consume(revision) {
                    sourceTree = prefetched
                    await prefetchMux.foreground(revisionProgress("正在使用后台预取来源修订", revision: revision, index: index, total: totalRevisions))
                } else {
                    sourceTree = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
                    let update = revisionProgress("正在准备来源修订", revision: revision, index: index, total: totalRevisions)
                    await prefetchMux.foreground(update)
                    try await snapshotSession.exportSnapshot(revision: revision, to: sourceTree) { update in
                        await prefetchMux.foreground(self.revisionProgress("正在准备来源修订", revision: revision, index: index, total: totalRevisions,
                                                                            update: update, usesSourcePhase: true))
                    }
                }
            } else {
                sourceTree = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
                await progress(revisionProgress("正在准备来源修订", revision: revision, index: index, total: totalRevisions))
                try await snapshotSession.exportSnapshot(revision: revision, to: sourceTree) { update in
                    await progress(self.revisionProgress("正在准备来源修订", revision: revision, index: index, total: totalRevisions,
                                                         update: update, usesSourcePhase: true))
                }
            }
            if let prefetcher, revisions.indices.contains(offset + 1) {
                try Task.checkCancellation()
                try await prefetcher.schedule(revisions[offset + 1])
            }
            try Task.checkCancellation()
            let imported = decorated(revision, plan: plan)
            let sourceFiles = try scan(sourceTree)
            let commit: String
            let targetTree: URL?
            let files: [MigrationFileComparison]
            if let verifiedSession {
                let update = revisionProgress("正在增量写入并核对 Git 对象", revision: revision, index: index, total: totalRevisions)
                if let prefetchMux { await prefetchMux.foreground(update) } else { await progress(update) }
                commit = try await verifiedSession.appendVerifiedSnapshot(
                    from: sourceTree, files: sourceFiles, revision: imported,
                    author: try author(for: revision, plan: plan)
                ) { update in
                    let mapped = self.revisionProgress("正在增量写入并核对 Git 对象", revision: revision, index: index, total: totalRevisions,
                                                       update: update)
                    if let prefetchMux { await prefetchMux.foreground(mapped) } else { await progress(mapped) }
                }
                targetTree = nil
                files = []
            } else {
                let legacyTargetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
                await progress(revisionProgress("正在写入 Git 快照", revision: revision, index: index, total: totalRevisions))
                commit = try await target.appendMigrationSnapshot(from: sourceTree, revision: imported,
                                                                       author: try author(for: revision, plan: plan), to: job.repository) { update in
                    await progress(self.revisionProgress("正在写入 Git 快照", revision: revision, index: index, total: totalRevisions,
                                                         update: update))
                }
                try Task.checkCancellation()
                await progress(revisionProgress("正在读取 Git 对象树", revision: revision, index: index, total: totalRevisions))
                try await target.exportMigrationTree(at: job.repository, revision: commit, to: legacyTargetTree) { update in
                    await progress(self.revisionProgress("正在读取 Git 对象树", revision: revision, index: index, total: totalRevisions,
                                                         update: update))
                }
                try Task.checkCancellation()
                await progress(revisionProgress("正在扫描并核对文件", revision: revision, index: index, total: totalRevisions))
                files = compare(sourceFiles, try scan(legacyTargetTree))
                guard !files.contains(where: { $0.state == .different }) else { throw VersionControlError.invalidData("修订 \(revision.id) 与 Git 实际对象树不一致。") }
                targetTree = legacyTargetTree
            }
            let oldLeft = job.leftTree
            let oldRight = job.rightTree
            job.mappings.append(MigrationMapping(source: revision, author: try author(for: revision, plan: plan), targetCommit: commit))
            job.leftTree = sourceTree; job.rightTree = targetTree; job.files = files
            // 只有目标会话返回提交、并完成其对象核对后才写入映射。检查点在删除
            // 临时来源快照之前原子保存，因此崩溃后可从下一份固定修订继续。
            try saveCheckpoint(job)
            // 预览只需保留当前已核对的前后树。较早修订已经写入 Git 对象库并被独立
            // 核对，继续保留全树会在长历史中无界占用临时磁盘。
            if let oldLeft { try? FileManager.default.removeItem(at: oldLeft) }
            if let oldRight { try? FileManager.default.removeItem(at: oldRight) }
            let completed = revisionProgress("已转换 SVN 修订", revision: revision, index: index, total: totalRevisions, completed: true)
            if let prefetchMux { await prefetchMux.foreground(completed) } else { await progress(completed) }
        }
        if let prefetcher { await prefetcher.finish() }
        } catch {
            if let prefetcher { await prefetcher.cancelAndDrain() }
            throw error
        }
        // 若刚好在末次提交检查点后中断，恢复时没有留下来源快照。重新导出固定末端
        // 只用于最终端到端核对，绝不追加新的 Git 提交。
        if job.leftTree == nil, let last = plan.source.revisions.last, !job.mappings.isEmpty {
            let sourceTree = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
            await progress(RepositoryOperationProgress("正在重建最终 SVN 快照用于恢复核对…"))
            try await snapshotSession.exportSnapshot(revision: last, to: sourceTree, progress: progress)
            job.leftTree = sourceTree
        }
        if revisions.isEmpty, verifiedSession == nil,
           let tip = job.mappings.last?.targetCommit, let sourceTree = job.leftTree {
            let targetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
            await progress(RepositoryOperationProgress("正在导出恢复后的 Git 对象树进行端到端核对…"))
            try await target.exportMigrationTree(at: job.repository, revision: tip, to: targetTree, progress: progress)
            let files = compare(try scan(sourceTree), try scan(targetTree))
            guard !files.contains(where: { $0.state == .different }) else {
                throw VersionControlError.invalidData("恢复后的 Git 实际对象树与 SVN 快照不一致。")
            }
            job.rightTree = targetTree
            job.files = files
        }
        if verifiedSession != nil {
            guard let tip = job.mappings.last?.targetCommit, let sourceTree = job.leftTree else {
                throw VersionControlError.invalidData("缺少最终 SVN 快照，不能完成 Git 端到端核对。")
            }
            let targetTree = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
            await progress(RepositoryOperationProgress("正在导出最终 Git 对象树进行端到端核对…"))
            try await target.exportMigrationTree(at: job.repository, revision: tip, to: targetTree, progress: progress)
            let files = compare(try scan(sourceTree), try scan(targetTree))
            guard !files.contains(where: { $0.state == .different }) else {
                throw VersionControlError.invalidData("最终 Git 实际对象树与 SVN 快照不一致。")
            }
            if let oldRight = job.rightTree { try? FileManager.default.removeItem(at: oldRight) }
            job.rightTree = targetTree
            job.files = files
        }
        await progress(RepositoryOperationProgress("正在确认最终 SVN 快照仍与当前工作副本一致…"))
        try validateInitialWorkingTree(job)
    }

    private func prepareSupplement(_ job: inout Job, progress: @escaping RepositoryOperationProgressHandler) async throws {
        guard let beforeTip = job.plan.expectedGitTip, let previous = job.plan.previousRecord else { throw VersionControlError.invalidData("补迁缺少上次迁移末端。") }
        let baseline = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
        await progress(RepositoryOperationProgress("正在导出当前 Git 基线用于补迁核对…"))
        try await target.exportMigrationTree(at: job.repository, revision: beforeTip, to: baseline, progress: progress)
        let before = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
        // 上次迁移记录保留了旧修订的真实作者、时间与说明。把它和新增修订放进同一
        // 来源会话，适配器即可从旧锚点一次检出后逐次切换，而不是重复远端导出整棵树。
        let old = previous.mappings.last?.source
            ?? MigrationRevision(id: previous.lastRevision, author: "", date: .distantPast, message: "")
        let sessionPlan = MigrationSourcePlan(providerID: job.plan.source.providerID,
                                              location: job.plan.source.location,
                                              anchor: job.plan.source.anchor,
                                              mode: job.plan.source.mode,
                                              revisions: [old] + job.plan.source.revisions,
                                              warnings: job.plan.source.warnings)
        let sourceCache = job.folder.appendingPathComponent("source-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sourceCache) }
        await progress(RepositoryOperationProgress("正在准备来源修订会话…"))
        let snapshotSession = try await source.makeMigrationSnapshotSession(plan: sessionPlan, in: sourceCache)
        let supplementRevisionCount = max(1, job.plan.source.revisions.count)
        await progress(RepositoryOperationProgress("正在准备来源修订 · \(old.id)"))
        try await snapshotSession.exportSnapshot(revision: old, to: before) { update in
            await progress(self.revisionProgress("正在准备来源修订", revision: old, index: 1,
                                                 total: supplementRevisionCount,
                                                 update: update, usesSourcePhase: true))
        }
        var prior = before
        for (offset, revision) in job.plan.source.revisions.enumerated() {
            try Task.checkCancellation()
            let index = offset + 1
            let total = job.plan.source.revisions.count
            let after = job.folder.appendingPathComponent("source-\(UUID().uuidString)")
            await progress(revisionProgress("正在准备来源修订", revision: revision, index: index, total: total))
            try await snapshotSession.exportSnapshot(revision: revision, to: after) { update in
                await progress(self.revisionProgress("正在准备来源修订", revision: revision, index: index, total: total,
                                                     update: update, usesSourcePhase: true))
            }
            try Task.checkCancellation()
            await progress(revisionProgress("正在写入 Git 差异", revision: revision, index: index, total: total))
            let commit = try await target.appendWorkingCopyMigrationDelta(before: prior, after: after,
                                                                            revision: decorated(revision, plan: job.plan),
                                                                            author: try author(for: revision, plan: job.plan), to: job.repository) { update in
                await progress(self.revisionProgress("正在写入 Git 差异", revision: revision, index: index, total: total,
                                                     update: update))
            }
            job.mappings.append(MigrationMapping(source: revision, author: try author(for: revision, plan: job.plan), targetCommit: commit))
            if prior != before { try? FileManager.default.removeItem(at: prior) }
            prior = after
            await progress(revisionProgress("已转换 SVN 修订", revision: revision, index: index, total: total, completed: true))
        }
        let final = job.folder.appendingPathComponent("verified-\(UUID().uuidString)")
        guard let tip = job.mappings.last?.targetCommit else { throw VersionControlError.invalidData("补迁未生成 Git 提交。") }
        await progress(RepositoryOperationProgress("正在导出补迁后的 Git 结果并核对…"))
        try await target.exportMigrationTree(at: job.repository, revision: tip, to: final, progress: progress)
        try Task.checkCancellation()
        await progress(RepositoryOperationProgress("正在扫描补迁前后文件差异…"))
        job.leftTree = baseline; job.rightTree = final; job.files = compare(try scan(baseline), try scan(final))
        if prior != before { try? FileManager.default.removeItem(at: prior) }
        try? FileManager.default.removeItem(at: before)
    }

    private func existingPreview(_ job: Job, plan: WorkingCopyMigrationPlan) async throws -> WorkingCopyMigrationPreview {
        guard job.complete, same(job.plan, plan), let tip = job.mappings.last?.targetCommit else {
            throw VersionControlError.invalidData("迁移尚未完成；隔离目录仅用于排查，请重新预检。")
        }
        try await target.verifyMigration(at: job.repository, expectedTip: tip, branch: plan.branch)
        return preview(job)
    }

    private func preview(_ job: Job) -> WorkingCopyMigrationPreview {
        WorkingCopyMigrationPreview(plan: job.plan, repository: job.repository, mappings: job.mappings, files: job.files,
                                    warnings: job.plan.source.warnings + (job.plan.authors.values.contains { $0.email.hasSuffix("@authors.invalid") } ? ["部分作者使用 @authors.invalid 占位邮箱。"] : []))
    }

    private func validatePreview(_ job: Job) throws {
        guard let tip = job.mappings.last?.targetCommit, let right = job.rightTree else { throw VersionControlError.invalidData("迁移预览不完整。") }
        let current = try scan(job.repository, excludingRootMetadata: true).filter { $0.kind != .directory }
        let expected = try scan(right).filter { $0.kind != .directory }
        guard current == expected, !tip.isEmpty else { throw VersionControlError.invalidData("迁移预览已被修改。") }
    }

    /// 初次迁移只验证 SVN 最终快照中已有的路径。工作副本的额外未跟踪文件（包括
    /// 构建产物和其中可能出现的嵌套元数据）不是迁移对象，不能导致递归扫描或阻断。
    private func validateInitialWorkingTree(_ job: Job) throws {
        guard let last = job.leftTree else { throw VersionControlError.invalidData("缺少最终 SVN 快照。") }
        for entry in try scan(last) {
            guard try workingEntry(at: job.plan.workingCopy.directory, path: entry.path) == entry else {
                throw VersionControlError.invalidData("当前 SVN 工作副本与最终快照不一致，不能应用迁移。")
            }
        }
    }

    func workingEntry(at root: URL, path: String) throws -> MigrationFileEntry? {
        try Task.checkCancellation()
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(path)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == resolvedRoot ||
                url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else { return nil }
        guard exists(url) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return MigrationFileEntry(path: path, kind: .symbolicLink, digest: digest(Data(link.utf8)), size: UInt64(link.utf8.count))
        }
        if type == .typeDirectory { return MigrationFileEntry(path: path, kind: .directory, digest: "", size: 0) }
        guard type == .typeRegular else { return nil }
        let executable = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        return MigrationFileEntry(path: path, kind: .file, digest: try digestFile(at: url),
                                  size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0, executable: executable)
    }

    func decorated(_ revision: MigrationRevision, plan: WorkingCopyMigrationPlan) -> MigrationRevision {
        let start = plan.previousRecord?.startRevision ?? plan.source.revisions.first!.id
        let cutover = plan.previousRecord?.cutoverRevision ?? plan.workingCopy.baseRevision
        let suffix = "\n\nRepHub-SVN-URL: \(plan.workingCopy.sourceURL)\nRepHub-SVN-UUID: \(plan.workingCopy.repositoryUUID)\nRepHub-SVN-Revision: \(revision.id)\nRepHub-SVN-Start: \(start)\nRepHub-SVN-End: \(plan.source.anchor)\nRepHub-SVN-Cutover: \(cutover)"
        return MigrationRevision(id: revision.id, author: revision.author, date: revision.date, message: revision.message + suffix)
    }

    func author(for revision: MigrationRevision, plan: WorkingCopyMigrationPlan) throws -> MigrationAuthor {
        guard let value = plan.authors[revision.author] else { throw VersionControlError.invalidData("缺少 SVN 作者映射。") }
        return value
    }

    nonisolated func revisionProgress(_ phase: String, revision: MigrationRevision, index: Int, total: Int,
                          update: RepositoryOperationProgress? = nil, completed: Bool = false,
                          usesSourcePhase: Bool = false) -> RepositoryOperationProgress {
        let safeTotal = max(1, total)
        let completedCount = completed ? index : max(0, index - 1)
        // 仅来源会话透传自身阶段；Git 写入/读取沿用业务层阶段，避免改变既有语义。
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

    func validatePlan(_ plan: WorkingCopyMigrationPlan) throws {
        guard !plan.source.revisions.isEmpty, Set(plan.source.revisions.map(\.id)).count == plan.source.revisions.count else { throw VersionControlError.invalidData("迁移计划没有有效历史。") }
        guard plan.source.providerID == source.id else { throw VersionControlError.invalidData("迁移计划的 SVN 来源类型不匹配。") }
        var previous: Int?
        for revision in plan.source.revisions {
            guard let value = revisionNumber(revision.id), previous.map({ $0 < value }) ?? true else {
                throw VersionControlError.invalidData("迁移计划的 SVN 修订必须严格递增。")
            }
            previous = value
        }
        // SVN 修订号属于整个仓库；所选目录在固定 BASE 之前可能已经停止变化。
        // 日志末端只需不晚于固定锚点，不能为相等而伪造该目录没有发生的提交。
        guard let anchor = revisionNumber(plan.source.anchor), let lastRevision = previous,
              lastRevision <= anchor else {
            throw VersionControlError.invalidData("迁移计划的末端修订超出固定锚点。")
        }
        if plan.action == .initial {
            guard plan.previousRecord == nil, plan.expectedGitTip == nil,
                  plan.source.location.url == plan.workingCopy.sourceURL,
                  plan.source.anchor == plan.workingCopy.baseRevision else {
                throw VersionControlError.invalidData("首次迁移计划与当前 SVN 工作副本基线不一致。")
            }
        }
        try validateAuthors(plan.authors); try rejectCredentialURL(plan.workingCopy.sourceURL); try rejectCredentialURL(plan.remoteURL)
    }

    private func checkpointURL(_ job: Job) -> URL { job.folder.appendingPathComponent("checkpoint.json", isDirectory: false) }

    private func saveCheckpoint(_ job: Job) throws {
        guard job.plan.action == .initial else { return }
        try rejectCredentialURL(job.plan.workingCopy.sourceURL)
        try rejectCredentialURL(job.plan.remoteURL)
        try validateCheckpointMappings(job.mappings, against: job.plan)
        let checkpoint = Checkpoint(version: 1, plan: StoredPlan(job.plan), mappings: job.mappings,
                                    repositoryName: job.repository.lastPathComponent)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(checkpoint).write(to: checkpointURL(job), options: .atomic)
    }

    private func decodeCheckpoint(at url: URL) throws -> Checkpoint {
        let file = url.standardizedFileURL
        guard file.lastPathComponent == "checkpoint.json", exists(file), !isLink(file) else {
            throw VersionControlError.invalidRepository("工作副本迁移检查点无效。")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(Checkpoint.self, from: Data(contentsOf: file))
        guard checkpoint.version == 1, checkpoint.repositoryName == "repository" else {
            throw VersionControlError.unsupported("此工作副本迁移检查点版本不受支持。")
        }
        let plan = checkpoint.plan.makePlan()
        try rejectCredentialURL(plan.workingCopy.sourceURL); try rejectCredentialURL(plan.remoteURL)
        return checkpoint
    }

    private func validateCheckpointContainer(folder: URL, checkpointURL: URL, planID: UUID) throws {
        guard !isLink(folder), !isLink(checkpointURL),
              checkpointURL.deletingLastPathComponent().standardizedFileURL == folder,
              folder.lastPathComponent == "RepHub-working-copy-migration-\(planID.uuidString)" else {
            throw VersionControlError.invalidRepository("工作副本迁移检查点不在原始隔离目录中。")
        }
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTemporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFolder.deletingLastPathComponent() == resolvedTemporary else {
            throw VersionControlError.invalidRepository("工作副本迁移检查点不在系统临时目录中。")
        }
    }

    private func validateCheckpointMappings(_ mappings: [MigrationMapping], against plan: WorkingCopyMigrationPlan) throws {
        guard mappings.count <= plan.source.revisions.count else {
            throw VersionControlError.invalidData("迁移检查点包含计划外的提交。")
        }
        for (index, mapping) in mappings.enumerated() {
            guard mapping.source == plan.source.revisions[index], mapping.author == plan.authors[mapping.source.author],
                  isGitObjectID(mapping.targetCommit) else {
                throw VersionControlError.invalidData("迁移检查点的提交映射与固定计划不一致。")
            }
        }
    }

    /// 跨进程恢复不能只信任检查点中的 commit ID。Git 适配器先验证末端 trailer，
    /// 这里再将该末端真实对象树与固定 SVN 修订完整比对一次；通过后才允许跳过
    /// 已完成的修订并继续追加。
    private func verifyRecoveredCheckpointContent(plan: WorkingCopyMigrationPlan,
                                                  mappings: [MigrationMapping], repository: URL) async throws {
        guard let mapping = mappings.last else { return }
        let record = WorkingCopyMigrationRecord(
            sourceURL: plan.workingCopy.sourceURL,
            repositoryUUID: plan.workingCopy.repositoryUUID,
            startRevision: plan.source.revisions[0].id,
            lastRevision: plan.source.anchor,
            remoteURL: plan.remoteURL,
            branch: plan.branch,
            mappings: mappings,
            cutoverRevision: plan.workingCopy.baseRevision
        )
        try await target.verifyWorkingCopyMigrationRecord(at: repository, record: record)
        let cache = repository.deletingLastPathComponent()
            .appendingPathComponent("source-cache-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let sourceTree = repository.deletingLastPathComponent()
            .appendingPathComponent("source-restore-\(UUID().uuidString)", isDirectory: true)
        let targetTree = repository.deletingLastPathComponent()
            .appendingPathComponent("verified-restore-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceTree)
            try? FileManager.default.removeItem(at: targetTree)
        }
        let session = try await source.makeMigrationSnapshotSession(plan: plan.source, in: cache,
                                                                     seedWorkingCopy: plan.workingCopy.directory)
        try await session.exportSnapshot(revision: mapping.source, to: sourceTree, progress: { _ in })
        try await target.exportMigrationTree(at: repository, revision: mapping.targetCommit, to: targetTree, progress: { _ in })
        guard !compare(try scan(sourceTree), try scan(targetTree)).contains(where: { $0.state == .different }) else {
            throw VersionControlError.invalidData("迁移检查点末端 Git 对象树与固定 SVN 修订不一致，不能恢复。")
        }
    }

    func validateAuthors(_ authors: [String: MigrationAuthor]) throws {
        guard authors.values.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.email.contains("@") && !$0.email.contains(" ") && !$0.name.contains("<") && !$0.email.contains("<") }) else { throw VersionControlError.invalidData("作者映射无效。") }
    }

    func validRecordRevisions(_ record: WorkingCopyMigrationRecord) -> Bool {
        guard let start = revisionNumber(record.startRevision), let cutover = revisionNumber(record.cutoverRevision),
              let last = revisionNumber(record.lastRevision), start <= cutover, cutover <= last else { return false }
        var previous: Int?
        for mapping in record.mappings {
            guard let revision = revisionNumber(mapping.source.id), revision >= start, revision <= last,
                  isGitObjectID(mapping.targetCommit), previous.map({ $0 < revision }) ?? true else { return false }
            previous = revision
        }
        return record.mappings.first?.source.id == record.startRevision
    }

    func revisionNumber(_ text: String) -> Int? {
        let value = text.hasPrefix("r") ? String(text.dropFirst()) : text
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(value)
    }

    func isGitObjectID(_ value: String) -> Bool {
        let count = value.utf8.count
        return (count == 40 || count == 64) && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    func validateWorkingCopy(_ value: MigrationWorkingCopyInfo, against expected: MigrationWorkingCopyInfo) throws {
        guard value.directory.standardizedFileURL == expected.directory.standardizedFileURL,
              value.sourceURL == expected.sourceURL, value.repositoryUUID == expected.repositoryUUID,
              value.baseRevision == expected.baseRevision else { throw VersionControlError.invalidData("SVN 工作副本身份或基线修订已变化。") }
    }

    func same(_ a: WorkingCopyMigrationPlan, _ b: WorkingCopyMigrationPlan) -> Bool {
        a.id == b.id && a.action == b.action && a.workingCopy == b.workingCopy && a.source.revisions == b.source.revisions &&
        a.source.anchor == b.source.anchor && a.source.mode == b.source.mode &&
        a.source.includeCopyHistory == b.source.includeCopyHistory && a.remoteURL == b.remoteURL && a.branch == b.branch &&
        a.expectedGitTip == b.expectedGitTip && a.authors == b.authors && a.previousRecord?.lastRevision == b.previousRecord?.lastRevision
    }

    func sameRecord(_ a: WorkingCopyMigrationRecord, _ b: WorkingCopyMigrationRecord) -> Bool {
        a.version == b.version && a.sourceURL == b.sourceURL && a.repositoryUUID == b.repositoryUUID &&
        a.startRevision == b.startRevision && a.cutoverRevision == b.cutoverRevision &&
        a.lastRevision == b.lastRevision && a.remoteURL == b.remoteURL && a.branch == b.branch &&
        a.mappings.count == b.mappings.count &&
        zip(a.mappings, b.mappings).allSatisfy { left, right in
            left.source == right.source && left.author == right.author && left.targetCommit == right.targetCommit
        }
    }

    func begin() throws { guard !busy else { throw VersionControlError.unsupported("另一项迁移操作正在执行。") }; busy = true }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }
    func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    func validatedWorkingCopyDirectory(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL
        guard root.isFileURL, exists(root), !isLink(root) else { throw VersionControlError.invalidRepository("工作副本目录无效。") }
        return root
    }
    func rejectCredentialURL(_ value: String) throws {
        let c = URLComponents(string: value); let scheme = c?.scheme?.lowercased()
        guard c?.password == nil, c?.query == nil, !(["http", "https", "file"].contains(scheme ?? "") && c?.user != nil) else { throw VersionControlError.invalidData("迁移地址不能包含凭据或查询令牌。") }
    }
}

private extension WorkingCopyMigrationService {
    func compare(_ source: [MigrationFileEntry], _ target: [MigrationFileEntry]) -> [MigrationFileComparison] {
        let left = Dictionary(uniqueKeysWithValues: source.map { ($0.path, $0) }); let right = Dictionary(uniqueKeysWithValues: target.map { ($0.path, $0) })
        return Set(left.keys).union(right.keys).sorted().map { path in
            let a = left[path], b = right[path]
            return MigrationFileComparison(path: path, source: a, target: b,
                                           state: a == b ? .identical : (a?.kind == .directory && b == nil ? .omittedDirectory : .different))
        }
    }
    func scan(_ root: URL, excludingRootMetadata: Bool = false) throws -> [MigrationFileEntry] {
        guard !isLink(root) else { throw VersionControlError.invalidData("迁移目录不能是符号链接。") }
        let manager = FileManager.default; var result: [MigrationFileEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                let name = child.lastPathComponent; if excludingRootMetadata && prefix.isEmpty && [".git", ".svn"].contains(name) { continue }
                guard ![".git", ".svn"].contains(name.lowercased()) else { throw VersionControlError.unsupported("迁移范围包含嵌套版本控制元数据。") }
                let path = prefix + name; let attributes = try manager.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink:
                    let link = try manager.destinationOfSymbolicLink(atPath: child.path); result.append(MigrationFileEntry(path: path, kind: .symbolicLink, digest: digest(Data(link.utf8)), size: UInt64(link.utf8.count)))
                case .typeDirectory:
                    result.append(MigrationFileEntry(path: path, kind: .directory, digest: "", size: 0)); try visit(child, prefix: path + "/")
                case .typeRegular:
                    let mode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
                    result.append(MigrationFileEntry(path: path, kind: .file, digest: try digestFile(at: child),
                                                     size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, executable: mode))
                default: throw VersionControlError.unsupported("不能迁移特殊文件：\(path)")
                }
            }
        }
        try visit(root, prefix: ""); return result.sorted { $0.path < $1.path }
    }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// 迁移核对会处理数百 MiB 的 SQL/二进制文件；固定 1 MiB 块计算摘要，避免把
    /// 单个文件整体映射或读入内存。每块之间检查取消，使取消不会等待读完整文件。
    func digestFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func previewFile(root: URL, entry: MigrationFileEntry?) throws -> (text: String, binary: Bool, truncated: Bool) {
        guard let entry else { return ("此项未出现在该版本", false, false) }; if entry.kind == .directory { return ("目录", false, false) }
        let url = root.appendingPathComponent(entry.path); guard !isLink(root), url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw VersionControlError.invalidData("预览文件已变化。") }
        if entry.kind == .symbolicLink { return ("符号链接 → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)), false, false) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe]); let clipped = Data(data.prefix(256 * 1024))
        guard !clipped.contains(0), let text = String(data: clipped, encoding: .utf8) else { return ("二进制文件 · \(entry.size) 字节\nSHA-256: \(entry.digest)", true, data.count > clipped.count) }
        return (text, false, data.count > clipped.count)
    }
}
