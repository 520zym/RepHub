import Foundation
import CryptoKit
import ToolExecution
import VersionControlCore

/// Git 迁移目标。它只接收已经由来源适配器导出的隔离快照；不会读取来源工作区，
/// 也不会在预览阶段配置或推送任何远端。
public final class GitMigrationTargetProvider: RepositoryMigrationTargetProvider, RepositoryVerifiedMigrationTargetProvider, @unchecked Sendable {
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
        let files = entries.filter { $0.kind == .regular }
        let regularObjectIDs = try await hashRegularFiles(files, in: repository, revisionID: revision.id, progress: progress)
        for entry in entries where entry.kind != .directory {
            try Task.checkCancellation()
            let objectID: String
            switch entry.kind {
            case .directory:
                continue
            case .regular:
                guard let object = regularObjectIDs[entry.path] else {
                    throw VersionControlError.invalidData("Git 未返回快照文件的对象 ID。")
                }
                objectID = object
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
        try await materialize(entries, into: repository, revisionID: revision.id, progress: progress)
        await progress(RepositoryOperationProgress("已生成 Git 提交 \(tip.prefix(12))。"))
        return tip
    }

    /// 已核对会话仅用于业务层创建的隔离预览仓库。会话不改变旧接口的语义：调用方在
    /// 完成后仍会执行完整导出与扫描核对；它只减少中间修订重复写入相同 Git blob 的开销。
    public func makeVerifiedMigrationSession(at repository: URL) async throws -> any RepositoryVerifiedMigrationSession {
        let root = try validatedRepository(repository)
        try await ensureCleanMigrationWorkingTree(in: root)
        let initialTip = try await migrationTipOrNil(in: root)
        return VerifiedMigrationSession(provider: self, repository: root, expectedTip: initialTip)
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
        try await exportMigrationTree(at: directory, revision: revision, to: destination, progress: { _ in })
    }

    /// 导出只在迁移隔离仓库中进行。按受限批次读取 blob，避免为每一个文件单独启动 Git。
    public func exportMigrationTree(
        at directory: URL,
        revision: String,
        to destination: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        let repository = try validatedRepository(directory)
        guard isObjectID(revision), try await resolveCommit(revision, in: repository) == revision else {
            throw VersionControlError.invalidData("要导出的 Git 提交不存在。")
        }
        try prepareEmptyDirectory(destination)
        // archive 会应用 export-subst 属性，不能作为“真实对象树”校验。这里逐 blob
        // 读取对象并保留 Git 的可执行位与符号链接内容。
        let listing = try requireSuccess(try await git(["ls-tree", "-r", "-z", "--full-tree", revision], in: repository), tool: "git")
        let treeEntries = try listing.data.split(separator: 0, omittingEmptySubsequences: true).map(parseExportTreeEntry)
        try await exportTreeEntries(treeEntries, in: repository, revision: revision, to: destination, progress: progress)
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
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已确认目标 Git 已包含本次迁移提交。")
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
                    if check == expectedTip { return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "目标 Git 分支已确认到迁移末端提交。") }
                    return MigrationPublicationResult(state: check == nil ? .notPublished : .unknown, message: check == nil ? "目标 Git 未接受迁移提交。" : "推送结果不明确，请先核对目标 Git。")
                } catch { return MigrationPublicationResult(state: .unknown, message: "推送未完成且无法读取目标 Git，请先核对。") }
            }
            let confirmed = try await remoteBranch(remote, branch: branch, in: repository)
            guard confirmed == expectedTip else { return MigrationPublicationResult(state: .unknown, message: "推送已返回成功，但未能确认目标 Git 分支。") }
            return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已发布迁移历史并确认目标 Git 分支。")
        } catch is CancellationError {
            guard writeStarted else { return MigrationPublicationResult(state: .notPublished, message: "发布已取消，尚未写入目标 Git。") }
            if let check = try? await probeRemoteBranch(remote, branch: branch, in: repository), check == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "发布被取消后仍确认目标 Git 已收到迁移提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "发布被取消，结果需要核对。")
        } catch {
            if writeStarted {
                if let check = try? await probeRemoteBranch(remote, branch: branch, in: repository), check == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "发布出现异常后仍确认目标 Git 已收到迁移提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "发布过程异常，结果需要核对：\(error.localizedDescription)")
            }
            throw error
        }
    }

    /// 在一个预览转换内复用已经通过 SHA-256 内容核对的 blob。首次进入（包括从既有
    /// 检查点恢复）故意全量 hash；之后才依据来源清单安全复用，不能把 Git 的 object id
    /// 当作来源字节校验的替代品。
    private actor VerifiedMigrationSession: RepositoryVerifiedMigrationSession {
        private struct CachedBlob {
            let entry: MigrationFileEntry
            let objectID: String
        }

        private let provider: GitMigrationTargetProvider
        private let repository: URL
        private var expectedTip: String?
        private var blobs: [String: CachedBlob] = [:]
        private var previousManifest: [String: MigrationFileEntry]?
        private var verifiedObjectDigests: [String: String] = [:]
        private var busy = false
        private var invalidated = false

        init(provider: GitMigrationTargetProvider, repository: URL, expectedTip: String?) {
            self.provider = provider
            self.repository = repository
            self.expectedTip = expectedTip
        }

        func appendVerifiedSnapshot(
            from snapshot: URL,
            files: [MigrationFileEntry],
            revision: MigrationRevision,
            author: MigrationAuthor,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws -> String {
            guard !busy else {
                throw VersionControlError.invalidRepository("Git 迁移会话正在写入另一条修订，请等待当前操作完成。")
            }
            guard !invalidated else {
                throw VersionControlError.invalidRepository("Git 迁移会话上一操作未完成，不能继续复用。请重新生成迁移预览。")
            }
            busy = true
            defer { busy = false }
            do {
                try Task.checkCancellation()
                try provider.validateAuthor(author)
                try await provider.ensureCleanMigrationWorkingTree(in: repository)
                guard try await provider.migrationTipOrNil(in: repository) == expectedTip else {
                    throw VersionControlError.invalidRepository("迁移预览的 Git 末端提交已变化，不能继续复用已核对会话。")
                }
                let manifest = try validateManifest(files)
                let snapshotEntries = try provider.snapshotEntries(at: snapshot)
                try validateSnapshot(snapshotEntries, against: manifest)

                let previous = previousManifest
                var nextBlobs: [String: CachedBlob] = [:]
                var changed: [GitMigrationTargetProvider.SnapshotEntry] = []
                var reused = 0
                for entry in snapshotEntries where entry.kind != .directory {
                    guard let declared = manifest[entry.path] else {
                        throw VersionControlError.invalidData("来源快照缺少文件清单记录：\(entry.path)")
                    }
                    if let cached = blobs[entry.path], cached.entry == declared {
                        nextBlobs[entry.path] = cached
                        reused += 1
                    } else {
                        changed.append(entry)
                    }
                }
                await progress(RepositoryOperationProgress(
                    "准备 \(revision.id) 的 Git 对象…",
                    detail: "复用 \(reused) 个已核对 blob，变化 \(changed.count) 个文件。"
                ))

                let changedObjects = try await writeChangedObjects(
                    changed, manifest: manifest, revisionID: revision.id, progress: progress
                )
                for (path, objectID) in changedObjects {
                    guard let declared = manifest[path] else { throw VersionControlError.invalidData("Git 对象缺少来源清单记录。") }
                    nextBlobs[path] = CachedBlob(entry: declared, objectID: objectID)
                }

                try Task.checkCancellation()
                _ = try requireSuccess(try await provider.git(["read-tree", "--empty"], in: repository), tool: "git")
                var records = Data()
                for entry in snapshotEntries where entry.kind != .directory {
                    guard let blob = nextBlobs[entry.path] else { throw VersionControlError.invalidData("Git 快照缺少文件对象。") }
                    let record = Data("\(entry.mode) \(blob.objectID)\t\(entry.path)\u{0}".utf8)
                    if records.count + record.count > 1_000_000 {
                        try await provider.updateIndex(records, in: repository)
                        records.removeAll(keepingCapacity: true)
                    }
                    records.append(record)
                }
                try await provider.updateIndex(records, in: repository)
                if snapshotEntries.allSatisfy({ $0.kind == .directory }) {
                    _ = try requireSuccess(try await provider.git(["hash-object", "-t", "tree", "-w", "--stdin"], in: repository, standardInput: Data()), tool: "git")
                }

                let date = ISO8601DateFormatter().string(from: revision.date)
                _ = try requireSuccess(try await provider.git([
                    "-c", "user.name=RepHub Migration", "-c", "user.email=rephub@local", "-c", "commit.gpgSign=false",
                    "commit", "--no-verify", "--no-gpg-sign", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim",
                    "--author=\(author.name) <\(author.email)>", "--date=\(date)", "-m", revision.message
                ], in: repository, timeout: 180), tool: "git")
                let tip = try await readCommittedTipAndVerifyParent()
                try await verifyTree(tip: tip, entries: snapshotEntries, blobs: nextBlobs)
                try await materializeDelta(
                    snapshotEntries,
                    previous: previous,
                    manifest: manifest,
                    revisionID: revision.id,
                    progress: progress
                )
                try await provider.ensureCleanMigrationWorkingTree(in: repository)
                blobs = nextBlobs
                previousManifest = manifest
                expectedTip = tip
                await progress(RepositoryOperationProgress(
                    "已生成 Git 提交 \(tip.prefix(12))。",
                    detail: "复用 \(reused) 个 blob，写入 \(changed.count) 个变化文件；完整树已核对。"
                ))
                return tip
            } catch {
                invalidated = true
                throw error
            }
        }

        private func validateManifest(_ files: [MigrationFileEntry]) throws -> [String: MigrationFileEntry] {
            var result: [String: MigrationFileEntry] = [:]
            result.reserveCapacity(files.count)
            for entry in files {
                _ = try provider.validatedRelativePath(entry.path)
                guard result[entry.path] == nil else { throw VersionControlError.invalidData("来源文件清单包含重复路径：\(entry.path)") }
                switch entry.kind {
                case .directory:
                    guard entry.digest.isEmpty, entry.size == 0, !entry.executable else {
                        throw VersionControlError.invalidData("目录文件清单记录无效：\(entry.path)")
                    }
                case .file, .symbolicLink:
                    guard entry.digest.count == 64,
                          entry.digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                          entry.kind == .file || !entry.executable else {
                        throw VersionControlError.invalidData("来源文件清单摘要或属性无效：\(entry.path)")
                    }
                }
                result[entry.path] = entry
            }
            return result
        }

        /// 提交完成后以一次 NUL 分隔的 show 同时读取 HEAD 与父级。不能以 currentTip
        /// 加第二次 show 代替，否则长历史每条修订会多启动一个 Git 进程。
        private func readCommittedTipAndVerifyParent() async throws -> String {
            let result = try requireSuccess(try await provider.git(
                ["show", "-s", "--format=%H%x00%P", "HEAD"], in: repository
            ), tool: "git")
            let fields = result.data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                throw VersionControlError.invalidData("Git 提交元数据格式无效。")
            }
            let tip = String(decoding: fields[0], as: UTF8.self)
            guard provider.isObjectID(tip) else {
                throw VersionControlError.invalidData("Git 未返回有效末端提交。")
            }
            let parents = String(decoding: fields[1], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let values = parents.split(whereSeparator: \.isWhitespace).map(String.init)
            if let expectedTip {
                guard values == [expectedTip] else {
                    throw VersionControlError.invalidRepository("Git 提交父级与已核对迁移检查点不一致，不能继续迁移。")
                }
            } else {
                guard values.isEmpty else {
                    throw VersionControlError.invalidRepository("首个 Git 迁移提交意外包含父提交，不能继续迁移。")
                }
            }
            return tip
        }

        private func validateSnapshot(
            _ entries: [GitMigrationTargetProvider.SnapshotEntry],
            against manifest: [String: MigrationFileEntry]
        ) throws {
            guard entries.count == manifest.count else { throw VersionControlError.invalidData("来源快照与文件清单的路径数量不一致。") }
            for entry in entries {
                guard let declared = manifest[entry.path] else { throw VersionControlError.invalidData("来源快照存在未声明路径：\(entry.path)") }
                let expectedKind: MigrationFileEntry.Kind = switch entry.kind {
                case .directory: .directory
                case .regular: .file
                case .symbolicLink: .symbolicLink
                }
                guard declared.kind == expectedKind,
                      declared.executable == (entry.mode == "100755"),
                      declared.size == entry.size else {
                    throw VersionControlError.invalidData("来源快照与文件清单类型、权限或大小不一致：\(entry.path)")
                }
            }
        }

        private func writeChangedObjects(
            _ changed: [GitMigrationTargetProvider.SnapshotEntry],
            manifest: [String: MigrationFileEntry],
            revisionID: String,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws -> [String: String] {
            var result: [String: String] = [:]
            var verification: [(objectID: String, entry: MigrationFileEntry)] = []
            let regular = changed.filter { $0.kind == .regular }
            let regularIDs = try await provider.hashRegularFiles(regular, in: repository, revisionID: revisionID, progress: progress)
            for entry in regular {
                try Task.checkCancellation()
                guard let oid = regularIDs[entry.path], let declared = manifest[entry.path] else { throw VersionControlError.invalidData("Git 未返回来源文件对象。") }
                let actual = try sha256(of: entry.url)
                guard actual.digest == declared.digest, actual.size == declared.size else {
                    throw VersionControlError.invalidData("来源文件在扫描后发生变化：\(entry.path)")
                }
                result[entry.path] = oid
                verification.append((oid, declared))
            }
            for entry in changed where entry.kind == .symbolicLink {
                try Task.checkCancellation()
                guard let declared = manifest[entry.path] else { throw VersionControlError.invalidData("符号链接缺少来源清单记录。") }
                let target = try provider.fileManager.destinationOfSymbolicLink(atPath: entry.url.path)
                let source = Data(target.utf8)
                guard UInt64(source.count) == declared.size,
                      SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == declared.digest else {
                    throw VersionControlError.invalidData("来源符号链接内容与已核对文件清单不一致：\(entry.path)")
                }
                let written = try requireSuccess(try await provider.git(
                    ["hash-object", "-w", "--stdin"], in: repository,
                    standardInput: source, maximumStandardInputBytes: 64 * 1024
                ), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard provider.isObjectID(written) else { throw VersionControlError.invalidData("Git 未返回有效符号链接对象。") }
                result[entry.path] = written
                verification.append((written, declared))
            }
            try await verifyGitBlobs(verification)
            return result
        }

        /// 按受限批次读取首次出现的 blob。不能逐文件启动 cat-file：大型历史的首轮
        /// 仍可能有数千个变化文件；只有超过批次上限的单 blob 才单独读取。
        private func verifyGitBlobs(_ candidates: [(objectID: String, entry: MigrationFileEntry)]) async throws {
            var unique: [String: MigrationFileEntry] = [:]
            for candidate in candidates where verifiedObjectDigests[candidate.objectID] != candidate.entry.digest {
                if let previous = unique[candidate.objectID], previous.digest != candidate.entry.digest || previous.size != candidate.entry.size {
                    throw VersionControlError.invalidData("同一 Git blob 对应了不一致的来源摘要。")
                }
                unique[candidate.objectID] = candidate.entry
            }
            let entries = unique.keys.sorted().map { objectID in
                GitMigrationTargetProvider.ExportTreeEntry(mode: "100644", objectID: objectID, path: objectID)
            }
            guard !entries.isEmpty else { return }
            let sizes = try await provider.readBlobSizes(entries, in: repository)
            var start = 0
            while start < entries.count {
                try Task.checkCancellation()
                let firstSize = sizes[start]
                guard firstSize <= GitMigrationTargetProvider.maxExportBlobBytes else {
                    throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象内容核对。")
                }
                if firstSize > GitMigrationTargetProvider.catFileBatchOutputBytes {
                    let entry = entries[start]
                    let blob = try await provider.readSingleExportBlob(entry, in: repository)
                    try verifyBlob(blob, objectID: entry.objectID, expected: try requiredManifest(for: entry.objectID, in: unique))
                    start += 1
                    continue
                }
                var end = start
                var outputBytes = 0
                var queryBytes = 0
                while end < entries.count, end - start < GitMigrationTargetProvider.catFileBatchCount {
                    let size = sizes[end]
                    guard size <= GitMigrationTargetProvider.maxExportBlobBytes else {
                        throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象内容核对。")
                    }
                    let querySize = entries[end].objectID.utf8.count + 1
                    let responseSize = querySize + 26 + size + 1
                    if end > start,
                       (queryBytes + querySize > GitMigrationTargetProvider.catFileBatchQueryBytes || outputBytes + responseSize > GitMigrationTargetProvider.catFileBatchOutputBytes) {
                        break
                    }
                    queryBytes += querySize
                    outputBytes += responseSize
                    end += 1
                }
                if end == start { end += 1 }
                let batch = Array(entries[start..<end])
                var input = Data()
                for entry in batch { input.append(Data("\(entry.objectID)\n".utf8)) }
                let result = try requireSuccess(try await provider.git(
                    ["cat-file", "--batch"], in: repository, timeout: 180,
                    standardInput: input,
                    maximumStandardInputBytes: max(GitMigrationTargetProvider.catFileBatchQueryBytes, input.count)
                ), tool: "git")
                let blobs = try provider.parseBatchBlobs(result.data, expected: batch, sizes: Array(sizes[start..<end]))
                for (entry, blob) in zip(batch, blobs) {
                    try verifyBlob(blob, objectID: entry.objectID, expected: try requiredManifest(for: entry.objectID, in: unique))
                }
                start = end
            }
        }

        private func requiredManifest(for objectID: String, in manifests: [String: MigrationFileEntry]) throws -> MigrationFileEntry {
            guard let value = manifests[objectID] else { throw VersionControlError.invalidData("Git blob 缺少来源摘要。") }
            return value
        }

        private func verifyBlob(_ blob: Data, objectID: String, expected: MigrationFileEntry) throws {
            guard UInt64(blob.count) == expected.size,
                  SHA256.hash(data: blob).map({ String(format: "%02x", $0) }).joined() == expected.digest else {
                throw VersionControlError.invalidData("Git 写入的 blob 与来源字节摘要不一致。")
            }
            verifiedObjectDigests[objectID] = expected.digest
        }

        private func sha256(of url: URL) throws -> (digest: String, size: UInt64) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            var size: UInt64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
                size += UInt64(data.count)
            }
            return (digest.finalize().map { String(format: "%02x", $0) }.joined(), size)
        }

        private func verifyTree(
            tip: String,
            entries: [GitMigrationTargetProvider.SnapshotEntry],
            blobs: [String: CachedBlob]
        ) async throws {
            let listing = try requireSuccess(try await provider.git(["ls-tree", "-r", "-z", "--full-tree", tip], in: repository), tool: "git")
            let tree = try listing.data.split(separator: 0, omittingEmptySubsequences: true).map(provider.parseExportTreeEntry)
            let expected = entries.filter { $0.kind != .directory }
            guard tree.count == expected.count else { throw VersionControlError.invalidData("Git 提交树的路径数量与来源快照不一致。") }
            let actualByPath = Dictionary(uniqueKeysWithValues: tree.map { ($0.path, $0) })
            for source in expected {
                guard let actual = actualByPath[source.path], actual.mode == source.mode,
                      actual.objectID == blobs[source.path]?.objectID else {
                    throw VersionControlError.invalidData("Git 提交树与来源快照不一致：\(source.path)")
                }
            }
        }

        private func materializeDelta(
            _ current: [GitMigrationTargetProvider.SnapshotEntry],
            previous: [String: MigrationFileEntry]?,
            manifest: [String: MigrationFileEntry],
            revisionID: String,
            progress: @escaping RepositoryOperationProgressHandler
        ) async throws {
            guard let previous else {
                try await provider.materialize(current, into: repository, revisionID: revisionID, progress: progress)
                return
            }
            let removed = previous.values.filter { old in
                guard let next = manifest[old.path] else { return true }
                return next.kind != old.kind
            }.sorted { $0.path.count > $1.path.count }
            for entry in removed {
                try Task.checkCancellation()
                let path = try provider.validatedExportPath(entry.path, under: repository)
                if provider.fileManager.fileExists(atPath: path.path) || (try? provider.fileManager.destinationOfSymbolicLink(atPath: path.path)) != nil {
                    try provider.fileManager.removeItem(at: path)
                }
            }
            for entry in current where entry.kind == .directory {
                try Task.checkCancellation()
                let output = try provider.validatedExportPath(entry.path, under: repository)
                if provider.fileManager.fileExists(atPath: output.path),
                   (try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory != true {
                    try provider.fileManager.removeItem(at: output)
                }
                try provider.fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            }
            let changed = current.filter { entry in
                guard entry.kind != .directory, let old = previous[entry.path], let currentEntry = manifest[entry.path] else { return entry.kind != .directory }
                return old != currentEntry
            }
            for (index, entry) in changed.enumerated() {
                try Task.checkCancellation()
                let output = try provider.validatedExportPath(entry.path, under: repository)
                if provider.fileManager.fileExists(atPath: output.path) || (try? provider.fileManager.destinationOfSymbolicLink(atPath: output.path)) != nil {
                    try provider.fileManager.removeItem(at: output)
                }
                try provider.fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.kind {
                case .regular:
                    try provider.fileManager.copyItem(at: entry.url, to: output)
                    if entry.mode == "100755" { try provider.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
                case .symbolicLink:
                    try provider.fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: try provider.fileManager.destinationOfSymbolicLink(atPath: entry.url.path))
                case .directory:
                    break
                }
                if index == 0 || (index + 1).isMultiple(of: 128) || index + 1 == changed.count {
                    await progress(RepositoryOperationProgress("正在整理 \(revisionID) 的 Git 工作区…", detail: "更新 \(index + 1) / \(changed.count) 个变化路径。"))
                }
            }
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
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已确认目标 Git 已包含本次补迁提交。")
            }
            guard currentRemote == expectedBeforeTip else { throw VersionControlError.invalidRepository("目标 Git 已变化，拒绝补迁发布。") }
            try Task.checkCancellation()
            do {
                await progress(RepositoryOperationProgress("正在发布补迁提交…"))
                let pushed = try await git(["push", "--porcelain", "--force-with-lease=refs/heads/\(branch):\(expectedBeforeTip)", "--", remote, "\(expectedTip):refs/heads/\(branch)"], in: repository, timeout: 600, remote: true)
                if pushed.exitCode != 0 {
                    if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                        return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "补迁推送返回异常后仍确认目标 Git 已收到提交。")
                    }
                    return MigrationPublicationResult(state: .unknown, message: "补迁推送结果不明确，请先核对目标 Git。")
                }
                let confirmed = try await probeRemoteBranch(remote, branch: branch, in: repository)
                if confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已发布补迁提交并确认目标 Git 分支。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁推送已返回成功，但远端分支尚未确认。")
            } catch is CancellationError {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "补迁发布取消后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁发布被取消，结果需要核对。")
            } catch {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "补迁发布异常后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "补迁发布异常，结果需要核对。")
            }
        }
        return try await publishInitialWorkingCopyMigration(at: repository, remote: remote, branch: branch, expectedTip: expectedTip, progress: progress)
    }
}

private extension GitMigrationTargetProvider {
    struct SnapshotEntry: Sendable {
        enum Kind: Equatable, Sendable { case directory, regular, symbolicLink }
        let url: URL
        let path: String
        let kind: Kind
        let mode: String
        let size: UInt64
    }

    struct ExportTreeEntry: Sendable {
        let mode: String
        let objectID: String
        let path: String
    }

    static let hashObjectBatchCount = 256
    /// macOS 的参数与环境总大小可能只有约 256 KiB，给隔离环境和 Git 自己的参数保留余量。
    static let hashObjectBatchArgumentBytes = 64 * 1024
    static let catFileBatchQueryBytes = 512 * 1024
    static let catFileBatchCount = 256
    /// CommandRunner 会把 stdout 与 stderr 一起限制为 16 MiB。接近该上限的 blob
    /// 不能带 batch 协议头读取，而是沿用旧的单对象读取，保持原有能力边界。
    static let maxExportBlobBytes = 16 * 1024 * 1024
    static let catFileBatchOutputBytes = 12 * 1024 * 1024

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

    /// 空仓库是迁移会话的合法起点；其余 rev-parse 错误必须原样暴露，不能误当成未出生 HEAD。
    func migrationTipOrNil(in repository: URL) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository)
        if result.exitCode == 1 || result.exitCode == 128 { return nil }
        let value = try requireSuccess(result, tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 这只写入新目录迁移结果或已确认的当前工作副本；不改远端 HEAD、默认分支或任何远端设置。
    /// 远端已确认成功后才调用，因此本地配置失败也不能否定已完成的发布。
    func publishedResult(repository: URL, remote: String, branch: String, confirmedTip: String, prefix: String) async -> MigrationPublicationResult {
        do {
            try await configureOrigin(in: repository, remote: remote, branch: branch)
            _ = try requireSuccess(try await git(["update-ref", "--no-deref", "refs/remotes/origin/\(branch)", confirmedTip], in: repository), tool: "git")
            return MigrationPublicationResult(state: .published, message: "\(prefix) 已为本地仓库设置 origin、\(branch) 上游并刷新远端跟踪引用；如远端是空裸仓库，必要时仍需在服务端将默认分支设为 \(branch)。")
        } catch {
            return MigrationPublicationResult(state: .published, message: "\(prefix) 远端发布已确认；但本地 origin/上游或远端跟踪引用刷新失败（\(error.localizedDescription)），可在仓库设置中重试。空裸远端的默认分支仍可能需要在服务端设为 \(branch)。")
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

    /// `hash-object --stdin-paths` 的输入按换行分隔，无法安全表达含换行的合法 POSIX 路径；
    /// 因此这里使用参数数组批量传入路径。CommandRunner 不经 shell，空格、引号与换行都保持为
    /// 单个参数，同时受总参数字节数限制，避免 exec 参数上限。
    func hashRegularFiles(
        _ entries: [SnapshotEntry],
        in repository: URL,
        revisionID: String,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> [String: String] {
        guard !entries.isEmpty else { return [:] }
        var objectIDs: [String: String] = [:]
        objectIDs.reserveCapacity(entries.count)
        var start = 0
        while start < entries.count {
            try Task.checkCancellation()
            var end = start
            var argumentBytes = 0
            while end < entries.count, end - start < Self.hashObjectBatchCount {
                let nextBytes = entries[end].url.path.utf8.count + 1
                if end > start, argumentBytes + nextBytes > Self.hashObjectBatchArgumentBytes { break }
                argumentBytes += nextBytes
                end += 1
            }
            let batch = Array(entries[start..<end])
            await progress(RepositoryOperationProgress("正在写入 \(revisionID) 的 Git 文件对象（\(start + 1)–\(end) / \(entries.count)）…"))
            let result = try requireSuccess(try await git(
                ["hash-object", "-w", "--no-filters", "--"] + batch.map { $0.url.path },
                in: repository,
                timeout: 180
            ), tool: "git")
            let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count == batch.count else {
                throw VersionControlError.invalidData("Git 返回的快照对象数量不完整。")
            }
            for (entry, objectID) in zip(batch, lines) {
                guard isObjectID(objectID) else { throw VersionControlError.invalidData("Git 未返回有效对象 ID。") }
                objectIDs[entry.path] = objectID
            }
            start = end
        }
        return objectIDs
    }

    func parseExportTreeEntry(_ field: Data.SubSequence) throws -> ExportTreeEntry {
        let parts = field.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw VersionControlError.invalidData("Git 树记录格式错误。") }
        let metadata = parts[0].split(separator: 32)
        guard metadata.count == 3, String(decoding: metadata[1], as: UTF8.self) == "blob" else {
            throw VersionControlError.invalidData("Git 树包含不支持的对象。")
        }
        let mode = String(decoding: metadata[0], as: UTF8.self)
        let objectID = String(decoding: metadata[2], as: UTF8.self)
        let path = String(decoding: parts[1], as: UTF8.self)
        guard isObjectID(objectID) else { throw VersionControlError.invalidData("Git 树包含无效对象 ID。") }
        _ = try validatedRelativePath(path)
        return ExportTreeEntry(mode: mode, objectID: objectID, path: path)
    }

    func exportTreeEntries(
        _ entries: [ExportTreeEntry],
        in repository: URL,
        revision: String,
        to destination: URL,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        guard !entries.isEmpty else { return }
        let sizes = try await readBlobSizes(entries, in: repository)
        var start = 0
        while start < entries.count {
            try Task.checkCancellation()
            let firstSize = sizes[start]
            guard firstSize <= Self.maxExportBlobBytes else {
                throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象树预览校验。")
            }
            if firstSize > Self.catFileBatchOutputBytes {
                let entry = entries[start]
                await progress(RepositoryOperationProgress("正在核对 \(revision.prefix(12)) 的 Git 大文件（\(start + 1) / \(entries.count)）…"))
                let blob = try await readSingleExportBlob(entry, in: repository)
                try materializeExportBlob(blob, for: entry, under: destination)
                start += 1
                continue
            }
            var end = start
            var outputBytes = 0
            var queryBytes = 0
            while end < entries.count, end - start < Self.catFileBatchCount {
                let size = sizes[end]
                guard size <= Self.maxExportBlobBytes else {
                    throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象树预览校验。")
                }
                let querySize = entries[end].objectID.utf8.count + 1
                // <oid> blob <size>\\n + 内容 + 内容后的换行。这里按最大位数预留，
                // 防止许多空 blob 绕过字节上限。
                let responseSize = querySize + 26 + size + 1
                if end > start,
                   (queryBytes + querySize > Self.catFileBatchQueryBytes || outputBytes + responseSize > Self.catFileBatchOutputBytes) {
                    break
                }
                queryBytes += querySize
                outputBytes += responseSize
                end += 1
            }
            // 单个受支持 blob 可能大于常规批次预算，仍单独读取，避免无限循环。
            if end == start { end += 1 }
            let batch = Array(entries[start..<end])
            await progress(RepositoryOperationProgress("正在核对 \(revision.prefix(12)) 的 Git 对象（\(start + 1)–\(end) / \(entries.count)）…"))
            var input = Data()
            for entry in batch { input.append(Data("\(entry.objectID)\n".utf8)) }
            let result: CommandResult
            do {
                result = try requireSuccess(try await git(
                    ["cat-file", "--batch"],
                    in: repository,
                    timeout: 180,
                    standardInput: input,
                    maximumStandardInputBytes: max(Self.catFileBatchQueryBytes, input.count)
                ), tool: "git")
            } catch VersionControlError.outputTooLarge {
                throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象树预览校验。")
            }
            let blobs = try parseBatchBlobs(result.data, expected: batch, sizes: Array(sizes[start..<end]))
            for (entry, blob) in zip(batch, blobs) {
                try Task.checkCancellation()
                try materializeExportBlob(blob, for: entry, under: destination)
            }
            start = end
        }
    }

    func materializeExportBlob(_ blob: Data, for entry: ExportTreeEntry, under destination: URL) throws {
        let output = try validatedExportPath(entry.path, under: destination)
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if entry.mode == "120000" {
            guard let link = String(data: blob, encoding: .utf8), !link.contains("\0") else {
                throw VersionControlError.invalidData("Git 符号链接内容无效。")
            }
            try fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: link)
        } else {
            try blob.write(to: output, options: .atomic)
            if entry.mode == "100755" {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            }
        }
    }

    func readSingleExportBlob(_ entry: ExportTreeEntry, in repository: URL) async throws -> Data {
        do {
            return try requireSuccess(try await git(["cat-file", "blob", entry.objectID], in: repository, timeout: 180), tool: "git").data
        } catch VersionControlError.outputTooLarge {
            throw VersionControlError.unsupported("迁移提交含有超过本地安全读取上限的单个文件，无法完成对象树预览校验。")
        }
    }

    func readBlobSizes(_ entries: [ExportTreeEntry], in repository: URL) async throws -> [Int] {
        var sizes: [Int] = []
        sizes.reserveCapacity(entries.count)
        var start = 0
        while start < entries.count {
            try Task.checkCancellation()
            var end = start
            var queryBytes = 0
            while end < entries.count {
                let next = entries[end].objectID.utf8.count + 1
                if end > start, queryBytes + next > Self.catFileBatchQueryBytes { break }
                queryBytes += next
                end += 1
            }
            let batch = entries[start..<end]
            let input = Data(batch.reduce(into: "") { $0 += "\($1.objectID)\n" }.utf8)
            let result = try requireSuccess(try await git(
                ["cat-file", "--batch-check"],
                in: repository,
                timeout: 180,
                standardInput: input,
                maximumStandardInputBytes: max(Self.catFileBatchQueryBytes, input.count)
            ), tool: "git")
            let lines = result.output.split(whereSeparator: \.isNewline)
            guard lines.count == batch.count else { throw VersionControlError.invalidData("Git 对象大小核对结果不完整。") }
            for (entry, line) in zip(batch, lines) {
                let fields = line.split(separator: " ")
                guard fields.count == 3,
                      String(fields[0]) == entry.objectID,
                      String(fields[1]) == "blob",
                      let size = Int(fields[2]), size >= 0 else {
                    throw VersionControlError.invalidData("Git 对象大小核对结果无效。")
                }
                sizes.append(size)
            }
            start = end
        }
        return sizes
    }

    func parseBatchBlobs(_ data: Data, expected entries: [ExportTreeEntry], sizes: [Int]) throws -> [Data] {
        let bytes = [UInt8](data)
        var offset = 0
        var blobs: [Data] = []
        blobs.reserveCapacity(entries.count)
        func nextLine() throws -> ArraySlice<UInt8> {
            guard let newline = bytes[offset...].firstIndex(of: 10) else {
                throw VersionControlError.invalidData("Git 批量对象输出缺少协议头。")
            }
            defer { offset = newline + 1 }
            return bytes[offset..<newline]
        }
        for (entry, expectedSize) in zip(entries, sizes) {
            let header = try nextLine().split(separator: 32)
            guard header.count == 3,
                  String(decoding: header[0], as: UTF8.self) == entry.objectID,
                  String(decoding: header[1], as: UTF8.self) == "blob",
                  Int(String(decoding: header[2], as: UTF8.self)) == expectedSize,
                  expectedSize <= bytes.count - offset else {
                throw VersionControlError.invalidData("Git 批量对象输出格式无效。")
            }
            let end = offset + expectedSize
            blobs.append(Data(bytes[offset..<end]))
            offset = end
            guard offset < bytes.count, bytes[offset] == 10 else {
                throw VersionControlError.invalidData("Git 批量对象输出缺少内容分隔符。")
            }
            offset += 1
        }
        guard offset == bytes.count else { throw VersionControlError.invalidData("Git 批量对象输出包含未识别内容。") }
        return blobs
    }

    func materialize(
        _ entries: [SnapshotEntry],
        into repository: URL,
        revisionID: String,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws {
        let children = try fileManager.contentsOfDirectory(at: repository, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent != ".git" {
            try Task.checkCancellation()
            try fileManager.removeItem(at: child)
        }
        let directories = entries.filter { $0.kind == .directory }
        for (index, entry) in directories.enumerated() {
            try Task.checkCancellation()
            try fileManager.createDirectory(at: repository.appendingPathComponent(entry.path), withIntermediateDirectories: true)
            if index == 0 || (index + 1).isMultiple(of: 128) || index + 1 == directories.count {
                await progress(RepositoryOperationProgress("正在整理 \(revisionID) 的 Git 工作区（目录 \(index + 1) / \(directories.count)）…"))
            }
        }
        let files = entries.filter { $0.kind != .directory }
        for (index, entry) in files.enumerated() {
            try Task.checkCancellation()
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
            if index == 0 || (index + 1).isMultiple(of: 128) || index + 1 == files.count {
                await progress(RepositoryOperationProgress("正在整理 \(revisionID) 的 Git 工作区（文件 \(index + 1) / \(files.count)）…"))
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
                let target = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                entries.append(SnapshotEntry(url: item, path: relative, kind: .symbolicLink, mode: "120000", size: UInt64(target.utf8.count))); continue
            }
            if values.isDirectory == true {
                entries.append(SnapshotEntry(url: item, path: relative, kind: .directory, mode: "040000", size: 0)); continue
            }
            guard values.isRegularFile == true else { throw VersionControlError.unsupported("迁移快照包含不支持的文件类型：\(relative)") }
            let attributes = try fileManager.attributesOfItem(atPath: item.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let executable = (permissions & 0o111) != 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            entries.append(SnapshotEntry(url: item, path: relative, kind: .regular, mode: executable ? "100755" : "100644", size: size))
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

    /// 已核对迁移会话不能在带有任何残留文件的预览目录上继续。与原地补迁不同，
    /// 这里的仓库完全由迁移任务拥有，未跟踪文件同样说明上一次物化没有完成。
    func ensureCleanMigrationWorkingTree(in repository: URL) async throws {
        let result = try requireSuccess(try await git(["status", "--porcelain=v1", "-z"], in: repository), tool: "git")
        guard result.data.isEmpty else {
            throw VersionControlError.invalidRepository("迁移预览工作区存在残留修改，不能继续复用已核对会话。")
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
            return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已确认目标 Git 已包含本次迁移提交。")
        }
        try await checkMigrationTarget(remoteURL: remote, branch: branch)
        try Task.checkCancellation()
        do {
            await progress(RepositoryOperationProgress("正在发布迁移后的 Git 历史…"))
            let pushed = try await git(["push", "--porcelain", "--force-with-lease=refs/heads/\(branch):", "--", remote, "\(expectedTip):refs/heads/\(branch)"], in: repository, timeout: 600, remote: true)
            if pushed.exitCode != 0 {
                if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                    return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "迁移推送返回异常后仍确认目标 Git 已收到提交。")
                }
                return MigrationPublicationResult(state: .unknown, message: "迁移推送结果不明确，请先核对目标 Git。")
            }
            let confirmed = try await probeRemoteBranch(remote, branch: branch, in: repository)
            if confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "已发布迁移历史并确认目标 Git 分支。")
            }
            return MigrationPublicationResult(state: .unknown, message: "推送已返回成功，但远端分支尚未确认。")
        } catch is CancellationError {
            if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "迁移发布取消后仍确认目标 Git 已收到提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "迁移发布被取消，结果需要核对。")
        } catch {
            if let confirmed = try? await probeRemoteBranch(remote, branch: branch, in: repository), confirmed == expectedTip {
                return await publishedResult(repository: repository, remote: remote, branch: branch, confirmedTip: expectedTip, prefix: "迁移发布异常后仍确认目标 Git 已收到提交。")
            }
            return MigrationPublicationResult(state: .unknown, message: "迁移发布异常，结果需要核对。")
        }
    }
}
