import Foundation
import ToolExecution
import VersionControlCore

/// Git 迁移目标。它只接收已经由来源适配器导出的隔离快照；不会读取来源工作区，
/// 也不会在预览阶段配置或推送任何远端。
public final class GitMigrationTargetProvider: RepositoryMigrationTargetProvider, @unchecked Sendable {
    public let id: ProviderID = .git

    private let runner: CommandRunner
    private let localRunner: CommandRunner
    private let fileManager: FileManager
    private let localHome: URL
    private let patchLimit = 2 * 1024 * 1024

    public init(runner: CommandRunner = CommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
        let home = fileManager.temporaryDirectory.appendingPathComponent("RepHub-MigrationGit-\(UUID().uuidString)", isDirectory: true)
        // 迁移预览不应继承用户的 global/system Git 配置；远端命令仍通过注入
        // runner 运行，以保留用户明确配置的 SSH Agent 或凭据助手。
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: home.appendingPathComponent("empty-template", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.localHome = home
        self.localRunner = CommandRunner(isolatedHome: home)
    }

    public func checkMigrationTarget(remoteURL: String, branch: String) async throws {
        let remote = try validatedRemote(remoteURL)
        try await validateBranch(branch)
        let result = try await git(["ls-remote", "--refs", "--", remote], timeout: 45, remote: true)
        let output = try requireSuccess(result, tool: "git")
        guard output.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VersionControlError.invalidRepository("目标 Git 仓库已经包含引用；迁移只允许发布到空仓库，避免覆盖已有提交。")
        }
    }

    public func initializeMigration(at directory: URL, branch: String) async throws {
        try await validateBranch(branch)
        let target = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw VersionControlError.invalidRepository("迁移预览位置不是目录。") }
        } else {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        guard try fileManager.contentsOfDirectory(atPath: target.path).isEmpty else {
            throw VersionControlError.invalidRepository("迁移预览目录必须为空，不能覆盖现有文件。")
        }
        _ = try requireSuccess(try await git(["init", "--template=\(localHome.appendingPathComponent("empty-template").path)", "--initial-branch=\(branch)", "--", target.path], in: target), tool: "git")
    }

    public func appendMigrationSnapshot(
        from snapshot: URL,
        revision: MigrationRevision,
        author: MigrationAuthor,
        to directory: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> String {
        let repository = try validatedRepository(directory)
        try validateAuthor(author)
        let entries = try snapshotEntries(at: snapshot)
        await progress(RepositoryOperationProgress("正在写入 \(revision.id) 的 Git 快照…"))

        // 永远从空索引构造树：这同时表达来源中已删除的文件，且不让 .gitignore、
        // clean filter 或用户现有暂存内容介入迁移。
        _ = try requireSuccess(try await git(["read-tree", "--empty"], in: repository), tool: "git")
        var indexRecords = Data()
        for entry in entries {
            guard entry.kind != .directory else { continue }
            let objectID: String
            switch entry.kind {
            case .directory:
                continue
            case .regular:
                let hashed = try await git(["hash-object", "-w", "--no-filters", "--", entry.url.path], in: repository, timeout: 180)
                objectID = try requireSuccess(hashed, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
            case .symbolicLink:
                let target = try fileManager.destinationOfSymbolicLink(atPath: entry.url.path)
                let hashed = try await git(
                    ["hash-object", "-w", "--stdin"], in: repository,
                    standardInput: Data(target.utf8), maximumStandardInputBytes: 64 * 1024
                )
                objectID = try requireSuccess(hashed, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard isObjectID(objectID) else { throw VersionControlError.invalidData("Git 未返回有效对象 ID。") }
            let record = Data("\(entry.mode) \(objectID)\t\(entry.path)\u{0}".utf8)
            if indexRecords.count + record.count > 1_000_000 {
                try await updateIndex(indexRecords, in: repository)
                indexRecords.removeAll(keepingCapacity: true)
            }
            indexRecords.append(record)
        }
        try await updateIndex(indexRecords, in: repository)

        // SVN 目录创建修订可能只有空目录。显式保存空树对象，避免 Git 的空索引
        // 优化只引用内置空树 ID，却没有可供 fsck / 远端接收校验的对象。
        if entries.allSatisfy({ $0.kind == .directory }) {
            _ = try requireSuccess(try await git(["hash-object", "-t", "tree", "-w", "--stdin"],
                                                in: repository, standardInput: Data()), tool: "git")
        }

        let date = ISO8601DateFormatter().string(from: revision.date)
        let commit = try await git([
            "-c", "user.name=RepHub Migration", "-c", "user.email=rephub@local", "-c", "commit.gpgSign=false",
            "commit", "--no-verify", "--no-gpg-sign", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim",
            "--author=\(author.name) <\(author.email)>", "--date=\(date)", "-m", revision.message
        ], in: repository, timeout: 180)
        _ = try requireSuccess(commit, tool: "git")
        let tip = try await currentTip(in: repository)
        try materialize(entries, into: repository)
        await progress(RepositoryOperationProgress("已生成 Git 提交 \(tip.prefix(12))。"))
        return tip
    }

    public func verifyMigration(at directory: URL, expectedTip: String, branch: String) async throws {
        let repository = try validatedRepository(directory)
        try await validateBranch(branch)
        guard isObjectID(expectedTip), try await currentTip(in: repository) == expectedTip else {
            throw VersionControlError.invalidData("迁移预览仓库的末端提交已变化，请重新生成预览。")
        }
        let currentBranch = try requireSuccess(try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository), tool: "git")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else { throw VersionControlError.invalidRepository("迁移预览当前不在目标分支。") }
        let status = try requireSuccess(try await git(["status", "--porcelain=v1", "-z"], in: repository), tool: "git")
        guard status.data.isEmpty else { throw VersionControlError.invalidRepository("迁移预览工作区已被修改，不能发布。") }
        _ = try requireSuccess(try await git(["fsck", "--no-dangling", "--no-reflogs", expectedTip], in: repository, timeout: 120), tool: "git")
    }

    public func verifyMigrationCheckpoint(at directory: URL, expectedTip: String?, branch: String) async throws {
        if let expectedTip {
            try await verifyMigration(at: directory, expectedTip: expectedTip, branch: branch)
            return
        }
        let repository = try validatedRepository(directory)
        try await validateBranch(branch)
        let currentBranch = try requireSuccess(try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository), tool: "git")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else { throw VersionControlError.invalidRepository("迁移预览当前不在目标分支。") }
        let head = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository)
        if head.exitCode == 0 {
            throw VersionControlError.invalidRepository("未核对提交已生成，请返回重新预检。")
        }
        guard head.exitCode == 1 || head.exitCode == 128 else { _ = try requireSuccess(head, tool: "git"); return }
        let status = try requireSuccess(try await git(["status", "--porcelain=v1", "-z"], in: repository), tool: "git")
        guard status.data.isEmpty else { throw VersionControlError.invalidRepository("未核对提交已生成，请返回重新预检。") }
        let contents = try fileManager.contentsOfDirectory(atPath: repository.path)
        guard contents.allSatisfy({ $0 == ".git" }) else { throw VersionControlError.invalidRepository("未核对提交已生成，请返回重新预检。") }
    }

    public func exportMigrationTree(at directory: URL, revision: String, to destination: URL) async throws {
        let repository = try validatedRepository(directory)
        guard isObjectID(revision), try await resolveCommit(revision, in: repository) == revision else {
            throw VersionControlError.invalidData("要导出的 Git 提交不存在。")
        }
        try prepareEmptyDirectory(destination)
        // archive 会应用 export-subst 属性，不能作为“真实对象树”校验。这里逐 blob
        // 读取对象并保留 Git 的可执行位与符号链接内容。
        let listing = try requireSuccess(try await git(["ls-tree", "-r", "-z", "--full-tree", revision], in: repository), tool: "git")
        for field in listing.data.split(separator: 0, omittingEmptySubsequences: true) {
            let parts = field.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw VersionControlError.invalidData("Git 树记录格式错误。") }
            let metadata = parts[0].split(separator: 32)
            guard metadata.count == 3, String(decoding: metadata[1], as: UTF8.self) == "blob" else { throw VersionControlError.invalidData("Git 树包含不支持的对象。") }
            let mode = String(decoding: metadata[0], as: UTF8.self)
            let objectID = String(decoding: metadata[2], as: UTF8.self)
            let path = String(decoding: parts[1], as: UTF8.self)
            let output = try validatedExportPath(path, under: destination)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let blob: Data
            do {
                blob = try requireSuccess(try await git(["cat-file", "blob", objectID], in: repository, timeout: 180), tool: "git").data
            } catch VersionControlError.outputTooLarge {
                throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象树预览校验。")
            }
            if mode == "120000" {
                guard let link = String(data: blob, encoding: .utf8), !link.contains("\0") else { throw VersionControlError.invalidData("Git 符号链接内容无效。") }
                try fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: link)
            } else {
                try blob.write(to: output, options: .atomic)
                if mode == "100755" { try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
            }
        }
    }

    public func migrationPatch(at directory: URL, revision: String) async throws -> RepositoryPatch {
        let repository = try validatedRepository(directory)
        guard isObjectID(revision), try await resolveCommit(revision, in: repository) == revision else {
            throw VersionControlError.invalidData("要预览的 Git 提交不存在。")
        }
        do {
            let result = try await git(["show", "--format=", "--patch", "--no-ext-diff", "--no-textconv", "--root", "--first-parent", revision], in: repository, timeout: 120)
            let patch = try requireSuccess(result, tool: "git").output
            if patch.utf8.count > patchLimit {
                return RepositoryPatch(text: String(patch.prefix(patchLimit)) + "\n\n[差异预览已截断]\n", isTruncated: true)
            }
            return RepositoryPatch(text: patch)
        } catch VersionControlError.outputTooLarge {
            return RepositoryPatch(text: "[差异预览超过读取上限，未能完整显示]\n", isTruncated: true)
        }
    }

    public func publishMigration(
        at directory: URL,
        remoteURL: String,
        branch: String,
        expectedTip: String,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> MigrationPublicationResult {
        let repository = try validatedRepository(directory)
        let remote = try validatedRemote(remoteURL)
        try await verifyMigration(at: repository, expectedTip: expectedTip, branch: branch)
        var writeStarted = false
        do {
            // 上次推送可能在网络中断后实际成功；先仅读取目标分支，命中本次固定
            // 末端提交时不重推，也不因空仓库规则而误报失败。
            if let existing = try await probeRemoteBranch(remote, branch: branch, in: repository), existing == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已确认目标 Git 已包含本次迁移提交。")
            }
            await progress(RepositoryOperationProgress("正在确认目标 Git 仓库为空…"))
            try await checkMigrationTarget(remoteURL: remote, branch: branch)
            await progress(RepositoryOperationProgress("正在发布迁移后的 Git 历史…"))
            writeStarted = true
            let push = try await git([
                "push", "--porcelain", "--force-with-lease=refs/heads/\(branch):",
                "--", remote, "\(expectedTip):refs/heads/\(branch)"
            ], in: repository, timeout: 600, remote: true)
            guard push.exitCode == 0 else {
                do {
                    let check = try await probeRemoteBranch(remote, branch: branch, in: repository)
                    if check == expectedTip { return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "目标 Git 分支已确认到迁移末端提交。") }
                    return MigrationPublicationResult(state: check == nil ? .notPublished : .unknown, message: check == nil ? "目标 Git 未接受迁移提交。" : "推送结果不明确，请先核对目标 Git。")
                } catch { return MigrationPublicationResult(state: .unknown, message: "推送未完成且无法读取目标 Git，请先核对。") }
            }
            let confirmed = try await remoteBranch(remote, branch: branch, in: repository)
            guard confirmed == expectedTip else { return MigrationPublicationResult(state: .unknown, message: "推送已返回成功，但未能确认目标 Git 分支。") }
            return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已发布迁移历史并确认目标 Git 分支。")
        } catch is CancellationError {
            guard writeStarted else { return MigrationPublicationResult(state: .notPublished, message: "发布已取消，尚未写入目标 Git。") }
            if let check = try? await probeRemoteBranch(remote, branch: branch, in: repository), check == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "发布被取消后仍确认目标 Git 已收到迁移提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "发布被取消，结果需要核对。")
        } catch {
            if writeStarted {
                if let check = try? await probeRemoteBranch(remote, branch: branch, in: repository), check == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "发布出现异常后仍确认目标 Git 已收到迁移提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "发布过程异常，结果需要核对：\(error.localizedDescription)")
            }
            throw error
        }
    }
}

extension GitMigrationTargetProvider: RepositoryWorkingCopyMigrationTargetProvider {
    public func verifyWorkingCopyMigrationRecord(at directory: URL, record: WorkingCopyMigrationRecord) async throws {
        guard record.version == 1, !record.sourceURL.isEmpty, !record.repositoryUUID.isEmpty,
              !record.startRevision.isEmpty, !record.cutoverRevision.isEmpty, !record.lastRevision.isEmpty,
              let mapping = record.mappings.last, isObjectID(mapping.targetCommit) else {
            throw VersionControlError.invalidData("SVN 迁移记录缺少末端映射或字段无效。")
        }
        let repository = try validatedRepository(directory)
        guard try await resolveCommit(mapping.targetCommit, in: repository) == mapping.targetCommit else {
            throw VersionControlError.invalidRepository("SVN 迁移记录对应的 Git 提交不存在。")
        }
        let message = try requireSuccess(try await git(["show", "-s", "--format=%B", mapping.targetCommit], in: repository), tool: "git").output
        let trailers = "\n\nRepHub-SVN-URL: \(record.sourceURL)\nRepHub-SVN-UUID: \(record.repositoryUUID)\nRepHub-SVN-Revision: \(mapping.source.id)\nRepHub-SVN-Start: \(record.startRevision)\nRepHub-SVN-End: \(record.lastRevision)\nRepHub-SVN-Cutover: \(record.cutoverRevision)\n"
        guard message.trimmingCharacters(in: .newlines).hasSuffix(trailers.trimmingCharacters(in: .newlines)) else {
            throw VersionControlError.invalidRepository("SVN 迁移记录与最后一个 Git 提交的来源标记不一致，不能据此跳过修订。")
        }
    }

    public func inspectWorkingCopyMigrationTarget(at directory: URL, branch: String, previousMigrationTip: String?) async throws -> String? {
        let root = directory.standardizedFileURL
        try await validateBranch(branch)
        if previousMigrationTip == nil {
            try ensureNoGitMetadata(above: root)
            return nil
        }
        guard let previousMigrationTip else { throw VersionControlError.invalidData("上一迁移提交缺失。") }
        let repository = try validatedRepository(root)
        try await rejectUnsafeWorkingCopyConfiguration(in: repository)
        let currentBranch = try requireSuccess(try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else { throw VersionControlError.invalidRepository("当前 Git 不在迁移目标分支 \(branch)。") }
        let head = try await currentTip(in: repository)
        guard isObjectID(previousMigrationTip), try await resolveCommit(previousMigrationTip, in: repository) == previousMigrationTip else { throw VersionControlError.invalidData("上一迁移提交在当前 Git 中不存在。") }
        let ancestor = try await git(["merge-base", "--is-ancestor", previousMigrationTip, head], in: repository)
        guard ancestor.exitCode == 0 else { throw VersionControlError.invalidRepository("当前 Git 历史不包含上一迁移提交，不能补迁。") }
        try await ensureNoTrackedWorkingTreeChanges(in: repository)
        return head
    }

    public func checkWorkingCopyMigrationRemote(remoteURL: String, branch: String, expectedTip: String?) async throws {
        let remote = try validatedRemote(remoteURL)
        try await validateBranch(branch)
        guard let expectedTip else { try await checkMigrationTarget(remoteURL: remote, branch: branch); return }
        guard isObjectID(expectedTip) else { throw VersionControlError.invalidData("当前 Git 提交无效。") }
        let remoteTip = try await remoteBranch(remote, branch: branch, in: localHome)
        guard remoteTip == expectedTip else { throw VersionControlError.invalidRepository("目标 Git 分支不是当前本地提交；请先获取或处理远端变化，避免夹带未推送或落后历史。") }
    }

    public func prepareWorkingCopyMigrationTarget(from directory: URL, expectedTip: String?, to preview: URL, branch: String) async throws {
        let source = directory.standardizedFileURL
        let target = preview.standardizedFileURL
        try prepareEmptyDirectory(target)
        if expectedTip == nil {
            try await initializeMigration(at: target, branch: branch)
            return
        }
        _ = try await inspectWorkingCopyMigrationTarget(at: source, branch: branch, previousMigrationTip: expectedTip)
        // 原 Git 工作区已在上一步要求干净。复制其 .git 和工作区到隔离预览，不执行 checkout，
        // 因而不会运行来源 .gitattributes 关联的过滤器。
        try fileManager.copyItem(at: source.appendingPathComponent(".git"), to: target.appendingPathComponent(".git"))
        let tree = fileManager.temporaryDirectory.appendingPathComponent("RepHub-WorkingCopyTree-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tree) }
        try await exportMigrationTree(at: source, revision: expectedTip!, to: tree)
        try copyWorkingTree(from: tree, to: target, excludingGitMetadata: true)
        try await verifyMigration(at: target, expectedTip: expectedTip!, branch: branch)
    }

    public func appendWorkingCopyMigrationDelta(before: URL, after: URL, revision: MigrationRevision, author: MigrationAuthor, to preview: URL, progress: @escaping RepositoryOperationProgressHandler) async throws -> String {
        let repository = try validatedRepository(preview)
        try validateAuthor(author)
        let existingHead = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository)
        if existingHead.exitCode == 1 || existingHead.exitCode == 128 {
            // 首次接入的预览尚无 Git 基线，直接由完整 SVN 当前快照创建首个提交；
            // 后续补迁才必须以三方方式应用增量，避免覆盖 Git 独立修改。
            return try await appendMigrationSnapshot(from: after, revision: revision, author: author, to: repository, progress: progress)
        }
        _ = try requireSuccess(existingHead, tool: "git")
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("RepHub-WorkingCopyDelta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try await initializeMigration(at: scratch, branch: "migration-delta")
        let baseline = MigrationRevision(id: "baseline", author: revision.author, date: revision.date, message: "RepHub SVN migration base")
        _ = try await appendMigrationSnapshot(from: before, revision: baseline, author: author, to: scratch, progress: { _ in })
        let deltaCommit = try await appendMigrationSnapshot(from: after, revision: revision, author: author, to: scratch, progress: { _ in })
        await progress(RepositoryOperationProgress("正在三方应用 SVN 修订 \(revision.id)…"))
        _ = try requireSuccess(try await git(["fetch", "--no-tags", "--", scratch.path, deltaCommit], in: repository, timeout: 180), tool: "git")
        let picked = try await git(["cherry-pick", "--no-commit", "--strategy=ort", deltaCommit], in: repository, timeout: 180)
        guard picked.exitCode == 0 else {
            // 保留隔离预览中的冲突文件和 CHERRY_PICK_HEAD，供界面展示或用户返回调整；原工作副本未写入。
            throw VersionControlError.executionFailed("SVN 修订 \(revision.id) 与当前 Git 独立修改发生冲突；冲突仅保留在迁移预览目录，原工作副本未改变。")
        }
        let date = ISO8601DateFormatter().string(from: revision.date)
        _ = try requireSuccess(try await git([
            "-c", "user.name=RepHub Migration", "-c", "user.email=rephub@local", "-c", "commit.gpgSign=false",
            "commit", "--no-verify", "--no-gpg-sign", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim",
            "--author=\(author.name) <\(author.email)>", "--date=\(date)", "-m", revision.message
        ], in: repository, timeout: 180), tool: "git")
        let tip = try await currentTip(in: repository)
        await progress(RepositoryOperationProgress("已在迁移预览中生成 Git 提交 \(tip.prefix(12))。"))
        return tip
    }

    public func applyWorkingCopyMigration(from preview: URL, to directory: URL, expectedBeforeTip: String?, expectedTip: String, branch: String, record: Data) async throws {
        let source = directory.standardizedFileURL
        let previewRepository = try validatedRepository(preview)
        try await verifyMigration(at: previewRepository, expectedTip: expectedTip, branch: branch)
        guard isObjectID(expectedTip) else { throw VersionControlError.invalidData("迁移预览末端提交无效。") }
        if expectedBeforeTip == nil {
            try ensureNoGitMetadata(above: source)
            // 首次仅把已核对的 .git 放入原 SVN 工作副本；不复制预览工作区内容，
            // 所以不会改动任何 SVN 文件或 .svn 元数据。
            let temporaryRoot = source.deletingLastPathComponent().appendingPathComponent(".rephub-git-install-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stagedRepository = temporaryRoot
            try fileManager.copyItem(at: previewRepository.appendingPathComponent(".git"), to: stagedRepository.appendingPathComponent(".git"))
            try writeMigrationRecord(record, into: stagedRepository)
            try ensureSVNExcluded(in: stagedRepository.appendingPathComponent(".git"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decodedRecord = try decoder.decode(WorkingCopyMigrationRecord.self, from: record)
            let remote = try validatedRemote(decodedRecord.remoteURL)
            try await validateBranch(decodedRecord.branch)
            try await configureOrigin(in: stagedRepository, remote: remote, branch: decodedRecord.branch)
            // 同一父目录内 rename，失败时原 SVN 工作副本没有 .git 半成品。
            try fileManager.moveItem(at: stagedRepository.appendingPathComponent(".git"), to: source.appendingPathComponent(".git"))
            return
        }
        let originalTip = try await inspectWorkingCopyMigrationTarget(at: source, branch: branch, previousMigrationTip: expectedBeforeTip)
        if originalTip == expectedTip {
            // 上次快进已完成但记录写入中断：只补写元数据，不重复 merge 或要求回退 HEAD。
            try writeMigrationRecord(record, into: source)
            try ensureSVNExcluded(in: source.appendingPathComponent(".git"))
            return
        }
        guard originalTip == expectedBeforeTip else { throw VersionControlError.invalidRepository("原 Git 已出现独立提交，请重新预览后再应用补迁。") }
        _ = try requireSuccess(try await git(["fetch", "--no-tags", "--", previewRepository.path, expectedTip], in: source, timeout: 180), tool: "git")
        let merged = try await git(["merge", "--ff-only", "--no-overwrite-ignore", "--no-verify", expectedTip], in: source, timeout: 180)
        guard merged.exitCode == 0 else { throw VersionControlError.executionFailed("补迁无法快进应用；原 Git 未被覆盖，请重新预览并处理冲突。") }
        try writeMigrationRecord(record, into: source)
        try ensureSVNExcluded(in: source.appendingPathComponent(".git"))
    }

    public func publishWorkingCopyMigration(at directory: URL, remoteURL: String, branch: String, expectedBeforeTip: String?, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        let repository = try validatedRepository(directory)
        let remote = try validatedRemote(remoteURL)
        try await verifyWorkingCopyMigration(at: repository, expectedTip: expectedTip, branch: branch)
        if let expectedBeforeTip {
            guard isObjectID(expectedBeforeTip) else { throw VersionControlError.invalidData("上一迁移提交无效。") }
            let ancestor = try await git(["merge-base", "--is-ancestor", expectedBeforeTip, expectedTip], in: repository)
            guard ancestor.exitCode == 0 else { throw VersionControlError.invalidRepository("补迁结果不是上一迁移提交的后代，拒绝发布。") }
            let currentRemote = try await probeRemoteBranch(remote, branch: branch, in: repository)
            if currentRemote == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已确认目标 Git 已包含本次补迁提交。")
            }
            guard currentRemote == expectedBeforeTip else { throw VersionControlError.invalidRepository("目标 Git 已变化，拒绝补迁发布。") }
            try Task.checkCancellation()
            do {
                await progress(RepositoryOperationProgress("正在发布补迁提交…"))
                let pushed = try await git(["push", "--porcelain", "--force-with-lease=refs/heads/\(branch):\(expectedBeforeTip)", "--", remote, "\(expectedTip):refs/heads/\(branch)"], in: repository, timeout: 600, remote: true)
                if pushed.exitCode != 0 {
                    if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                        return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "补迁推送返回异常后仍确认目标 Git 已收到提交。")
                    }
                    return MigrationPublicationResult(state: .unknown, message: "补迁推送结果不明确，请先核对目标 Git。")
                }
                let confirmed = try await probeRemoteBranch(remote, branch: branch, in: repository)
                if confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已发布补迁提交并确认目标 Git 分支。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁推送已返回成功，但远端分支尚未确认。")
            } catch is CancellationError {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "补迁发布取消后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁发布被取消，结果需要核对。")
            } catch {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "补迁发布异常后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁发布异常，结果需要核对。")
            }
        }
        return try await publishInitialWorkingCopyMigration(at: repository, remote: remote, branch: branch, expectedTip: expectedTip, progress: progress)
    }
}

private extension GitMigrationTargetProvider {
    struct SnapshotEntry {
        enum Kind: Equatable { case directory, regular, symbolicLink }
        let url: URL
        let path: String
        let kind: Kind
        let mode: String
    }

    func git(_ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 30, remote: Bool = false, standardInput: Data? = nil, maximumStandardInputBytes: Int = 4 * 1024) async throws -> CommandResult {
        let safeguards = ["--no-optional-locks", "-c", "core.pager=cat", "-c", "core.quotepath=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false"]
        let protocols = ["-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-c", "protocol.http.allow=always", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always"]
        guard fileManager.fileExists(atPath: localHome.path) else { throw VersionControlError.executionFailed("无法建立 Git 迁移隔离配置目录。") }
        let selectedRunner = remote ? runner : localRunner
        return try await selectedRunner.run(executable: "git", arguments: safeguards + (remote ? protocols : []) + arguments, directory: directory, timeout: timeout, standardInput: standardInput, maximumStandardInputBytes: maximumStandardInputBytes)
    }

    func validatedRemote(_ value: String) throws -> String {
        let remote = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, remote == value, !remote.hasPrefix("-"), !remote.contains("::"), !remote.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VersionControlError.invalidRepository("Git 目标地址格式无效。") }
        if remote.hasPrefix("/") { return remote }
        if let parts = URLComponents(string: remote), let scheme = parts.scheme?.lowercased() {
            guard ["https", "http", "ssh", "file"].contains(scheme), parts.password == nil, parts.query == nil, parts.fragment == nil else { throw VersionControlError.unsupported("不支持该 Git 目标地址。") }
            guard scheme == "ssh" || parts.user == nil else {
                throw VersionControlError.invalidRepository("Git HTTP 地址不能携带账号或令牌，请使用系统凭据助手。")
            }
            guard scheme == "file" ? parts.path.hasPrefix("/") : parts.host?.isEmpty == false else { throw VersionControlError.invalidRepository("Git 目标地址缺少有效主机或路径。") }
            return remote
        }
        guard remote.range(of: "^[^@/:\\s]+@[^@/:\\s]+:[^\\s]+$", options: .regularExpression) != nil else { throw VersionControlError.invalidRepository("Git 目标地址格式无效。") }
        return remote
    }

    func validateBranch(_ branch: String) async throws {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == branch, !name.isEmpty else { throw VersionControlError.invalidRepository("目标分支不能为空。") }
        _ = try requireSuccess(try await git(["check-ref-format", "--branch", name]), tool: "git")
    }

    func validatedRepository(_ directory: URL) throws -> URL {
        let root = directory.standardizedFileURL
        let metadata = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              fileManager.fileExists(atPath: metadata.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !fileManager.fileExists(atPath: metadata.appendingPathComponent("commondir").path) else {
            throw VersionControlError.invalidRepository("迁移预览必须使用自己的 Git 元数据目录，不能重定向到其他工作副本。")
        }
        return root
    }

    func validateAuthor(_ author: MigrationAuthor) throws {
        guard !author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, author.email.contains("@"), !author.name.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }), !author.email.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }) else { throw VersionControlError.invalidData("迁移作者姓名或邮箱无效。") }
    }

    func currentTip(in repository: URL) async throws -> String {
        let value = try requireSuccess(try await git(["rev-parse", "--verify", "HEAD"], in: repository), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isObjectID(value) else { throw VersionControlError.invalidData("Git 未返回有效末端提交。") }
        return value
    }

    func resolveCommit(_ value: String, in repository: URL) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(value)^{commit}"], in: repository)
        if result.exitCode == 1 || result.exitCode == 128 { return nil }
        return try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteBranch(_ remote: String, branch: String, in repository: URL) async throws -> String? {
        let result = try await git(["ls-remote", "--heads", "--", remote, "refs/heads/\(branch)"], in: repository, timeout: 45, remote: true)
        let text = try requireSuccess(result, tool: "git").output
        return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// 脱离调用任务的取消上下文执行只读确认；发布结果不明确时绝不据此重推。
    func probeRemoteBranch(_ remote: String, branch: String, in repository: URL) async throws -> String? {
        try await Task.detached(priority: .utility) { [self] in
            try await remoteBranch(remote, branch: branch, in: repository)
        }.value
    }

    /// 这只写入刚生成的本地预览仓库；不改远端 HEAD、默认分支或任何远端设置。
    /// 远端已确认成功后才调用，因此本地配置失败也不能否定已完成的发布。
    func publishedResult(repository: URL, remote: String, branch: String, prefix: String) async -> MigrationPublicationResult {
        do {
            try await configureOrigin(in: repository, remote: remote, branch: branch)
            return MigrationPublicationResult(state: .published, message: "\(prefix) 已为本地仓库设置 origin 和 \(branch) 上游；如远端是空裸仓库，必要时仍需在服务端将默认分支设为 \(branch)。")
        } catch {
            return MigrationPublicationResult(state: .published, message: "\(prefix) 远端发布已确认；但本地 origin/上游配置失败（\(error.localizedDescription)），可在仓库设置中重试。空裸远端的默认分支仍可能需要在服务端设为 \(branch)。")
        }
    }

    /// 仅写入本地迁移仓库的 remote/upstream 配置；不 fetch、不推送，也不改远端 HEAD。
    func configureOrigin(in repository: URL, remote: String, branch: String) async throws {
        let origin = try await git(["remote", "get-url", "origin"], in: repository)
        if origin.exitCode == 0 {
            _ = try requireSuccess(try await git(["remote", "set-url", "origin", remote], in: repository), tool: "git")
        } else if origin.exitCode == 2 || origin.exitCode == 128 {
            _ = try requireSuccess(try await git(["remote", "add", "origin", remote], in: repository), tool: "git")
        } else {
            _ = try requireSuccess(origin, tool: "git")
        }
        _ = try requireSuccess(try await git(["config", "branch.\(branch).remote", "origin"], in: repository), tool: "git")
        _ = try requireSuccess(try await git(["config", "branch.\(branch).merge", "refs/heads/\(branch)"], in: repository), tool: "git")
    }

    func updateIndex(_ records: Data, in repository: URL) async throws {
        guard !records.isEmpty else { return }
        _ = try requireSuccess(try await git(
            ["update-index", "-z", "--add", "--index-info"], in: repository,
            standardInput: records, maximumStandardInputBytes: 1_048_576
        ), tool: "git")
    }

    func materialize(_ entries: [SnapshotEntry], into repository: URL) throws {
        let children = try fileManager.contentsOfDirectory(at: repository, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent != ".git" { try fileManager.removeItem(at: child) }
        for entry in entries where entry.kind == .directory {
            try fileManager.createDirectory(at: repository.appendingPathComponent(entry.path), withIntermediateDirectories: true)
        }
        for entry in entries where entry.kind != .directory {
            let output = try validatedExportPath(entry.path, under: repository)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch entry.kind {
            case .regular:
                try fileManager.copyItem(at: entry.url, to: output)
                if entry.mode == "100755" { try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
            case .symbolicLink:
                try fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: try fileManager.destinationOfSymbolicLink(atPath: entry.url.path))
            case .directory: break
            }
        }
    }

    func snapshotEntries(at snapshot: URL) throws -> [SnapshotEntry] {
        let root = snapshot.standardizedFileURL
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw VersionControlError.invalidRepository("来源快照目录不存在。") }
        // 使用枚举器返回的相对路径，避免 macOS 临时目录 /var 与 /private/var
        // 的规范化差异被误判为越界。子项的符号链接本身不能被解析为目标路径。
        guard let enumerator = fileManager.enumerator(atPath: root.path) else { throw VersionControlError.executionFailed("无法读取来源快照。") }
        var entries: [SnapshotEntry] = []
        for case let relative as String in enumerator {
            guard !relative.isEmpty else { continue }
            _ = try validatedRelativePath(relative)
            let item = root.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                entries.append(SnapshotEntry(url: item, path: relative, kind: .symbolicLink, mode: "120000")); continue
            }
            if values.isDirectory == true {
                entries.append(SnapshotEntry(url: item, path: relative, kind: .directory, mode: "040000")); continue
            }
            guard values.isRegularFile == true else { throw VersionControlError.unsupported("迁移快照包含不支持的文件类型：\(relative)") }
            let attributes = try fileManager.attributesOfItem(atPath: item.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let executable = (permissions & 0o111) != 0
            entries.append(SnapshotEntry(url: item, path: relative, kind: .regular, mode: executable ? "100755" : "100644"))
        }
        return entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    func prepareEmptyDirectory(_ destination: URL) throws {
        let directory = destination.standardizedFileURL
        if fileManager.fileExists(atPath: directory.path) {
            let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard children.isEmpty else { throw VersionControlError.invalidRepository("导出目录必须为空，不能覆盖现有文件。") }
        } else { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    func validatedExportPath(_ path: String, under root: URL) throws -> URL {
        let components = try validatedRelativePath(path)
        return components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    func validatedRelativePath(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame || $0.caseInsensitiveCompare(".svn") == .orderedSame || $0.contains("\0") }) else { throw VersionControlError.invalidData("迁移路径无效或包含版本控制元数据：\(path)") }
        return parts
    }

    func isObjectID(_ value: String) -> Bool { (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }

    func ensureNoGitMetadata(above directory: URL) throws {
        var path = directory.standardizedFileURL.path
        while true {
            let metadata = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: metadata.path) || (try? fileManager.attributesOfItem(atPath: metadata.path)) != nil {
                throw VersionControlError.invalidRepository("该目录或父目录已受 Git 管理，首次迁移不会覆盖现有 Git 元数据。")
            }
            // Foundation 的 URL 删除根路径组件后可能变为相对路径；路径必须逐层
            // 缩短并在 / 终止，不能继续生成 ../.. 造成无界循环。
            if path == "/" { break }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent.hasPrefix("/"), parent.count < path.count else { break }
            path = parent
        }
    }

    func copyWorkingTree(from source: URL, to destination: URL, excludingGitMetadata: Bool) throws {
        guard let enumerator = fileManager.enumerator(atPath: source.path) else { throw VersionControlError.executionFailed("无法读取 Git 工作区。") }
        for case let relative as String in enumerator {
            let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first == ".svn" || (excludingGitMetadata && first == ".git") {
                enumerator.skipDescendants(); continue
            }
            _ = try validatedRelativePath(relative)
            let input = source.appendingPathComponent(relative)
            let output = destination.appendingPathComponent(relative)
            let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: fileManager.destinationOfSymbolicLink(atPath: input.path))
            } else if values.isDirectory == true {
                try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: input, to: output)
            }
        }
    }

    func writeMigrationRecord(_ data: Data, into repository: URL) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw VersionControlError.invalidData("迁移记录过大，拒绝写入 Git 元数据。") }
        let file = repository.appendingPathComponent(".git/rephub-svn-migration.json")
        try data.write(to: file, options: .atomic)
    }

    func ensureSVNExcluded(in metadata: URL) throws {
        let info = metadata.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(whereSeparator: \.isNewline).contains(where: { $0 == ".svn" || $0 == ".svn/" }) else { return }
        let appended = current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".svn/\n"
        try appended.write(to: exclude, atomically: true, encoding: .utf8)
    }

    func rejectUnsafeWorkingCopyConfiguration(in repository: URL) async throws {
        let result = try requireSuccess(try await git(["config", "--local", "--list", "--name-only", "--null"], in: repository), tool: "git")
        let names = result.data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self).lowercased() }
        let unsafe = names.first { name in
            name == "core.worktree" || name == "core.attributesfile" || name.hasPrefix("include.") || name.hasPrefix("includeif.")
                || name.hasPrefix("filter.") || (name.hasPrefix("merge.") && name.hasSuffix(".driver"))
        }
        if let unsafe { throw VersionControlError.unsupported("当前 Git 本地配置包含可能执行外部转换或重定向工作区的 \(unsafe)，请移除后再进行原地补迁。") }
    }

    func ensureNoTrackedWorkingTreeChanges(in repository: URL) async throws {
        let result = try requireSuccess(try await git(["status", "--porcelain=v1", "-z", "--untracked-files=no"], in: repository), tool: "git")
        let records = result.data.split(separator: 0, omittingEmptySubsequences: true)
        for record in records {
            guard record.count >= 2 else { throw VersionControlError.invalidData("Git 状态记录格式错误。") }
            let status = String(decoding: record.prefix(2), as: UTF8.self)
            if status != "??" { throw VersionControlError.invalidRepository("当前 Git 有已跟踪文件修改，补迁前请先提交或处理。") }
        }
    }

    func verifyWorkingCopyMigration(at directory: URL, expectedTip: String, branch: String) async throws {
        let repository = try validatedRepository(directory)
        try await validateBranch(branch)
        guard isObjectID(expectedTip), try await currentTip(in: repository) == expectedTip else {
            throw VersionControlError.invalidData("当前 Git 末端提交已变化，请重新预览。")
        }
        let currentBranch = try requireSuccess(try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else { throw VersionControlError.invalidRepository("当前 Git 不在迁移目标分支。") }
        try await rejectUnsafeWorkingCopyConfiguration(in: repository)
        try await ensureNoTrackedWorkingTreeChanges(in: repository)
    }

    func publishInitialWorkingCopyMigration(at repository: URL, remote: String, branch: String, expectedTip: String, progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationPublicationResult {
        try await verifyWorkingCopyMigration(at: repository, expectedTip: expectedTip, branch: branch)
        if let existing = try await probeRemoteBranch(remote, branch: branch, in: repository), existing == expectedTip {
            return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已确认目标 Git 已包含本次迁移提交。")
        }
        try await checkMigrationTarget(remoteURL: remote, branch: branch)
        try Task.checkCancellation()
        do {
            await progress(RepositoryOperationProgress("正在发布迁移后的 Git 历史…"))
            let pushed = try await git(["push", "--porcelain", "--force-with-lease=refs/heads/\(branch):", "--", remote, "\(expectedTip):refs/heads/\(branch)"], in: repository, timeout: 600, remote: true)
            if pushed.exitCode != 0 {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "迁移推送返回异常后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "迁移推送结果不明确，请先核对目标 Git。")
            }
            let confirmed = try await probeRemoteBranch(remote, branch: branch, in: repository)
            if confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "已发布迁移历史并确认目标 Git 分支。")
            }
            return MigrationPublicationResult(state: .unknown, message: "推送已返回成功，但远端分支尚未确认。")
        } catch is CancellationError {
            if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "迁移发布取消后仍确认目标 Git 已收到提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "迁移发布被取消，结果需要核对。")
        } catch {
            if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, prefix: "迁移发布异常后仍确认目标 Git 已收到提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "迁移发布异常，结果需要核对。")
        }
    }
}
