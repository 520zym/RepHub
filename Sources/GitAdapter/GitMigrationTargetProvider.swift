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
            let origin = try await git(["remote", "get-url", "origin"], in: repository)
            if origin.exitCode == 0 {
                _ = try requireSuccess(try await git(["remote", "set-url", "origin", remote], in: repository), tool: "git")
            } else if origin.exitCode == 2 || origin.exitCode == 128 {
                _ = try requireSuccess(try await git(["remote", "add", "origin", remote], in: repository), tool: "git")
            } else {
                _ = try requireSuccess(origin, tool: "git")
            }
            // 直接写入本地分支跟踪关系，不 fetch、不改变远端，也不依赖裸仓库的
            // HEAD 是否仍指向 master。
            _ = try requireSuccess(try await git(["config", "branch.\(branch).remote", "origin"], in: repository), tool: "git")
            _ = try requireSuccess(try await git(["config", "branch.\(branch).merge", "refs/heads/\(branch)"], in: repository), tool: "git")
            return MigrationPublicationResult(state: .published, message: "\(prefix) 已为本地仓库设置 origin 和 \(branch) 上游；如远端是空裸仓库，必要时仍需在服务端将默认分支设为 \(branch)。")
        } catch {
            return MigrationPublicationResult(state: .published, message: "\(prefix) 远端发布已确认；但本地 origin/上游配置失败（\(error.localizedDescription)），可在仓库设置中重试。空裸远端的默认分支仍可能需要在服务端设为 \(branch)。")
        }
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
}
