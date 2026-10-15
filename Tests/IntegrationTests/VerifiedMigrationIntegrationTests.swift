import CryptoKit
import Foundation
import Testing
import GitAdapter
import RepositoryApplication
import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("已验证 SVN 到 Git 迁移集成")
struct VerifiedMigrationIntegrationTests {
    @Test("标准迁移与当前工作副本初迁均复用不可变 Git blob，并逐修订核对 SVN 树")
    func verifiedSessionKeepsEveryRevisionEquivalentForBothInitialServices() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedLargeCopiedModule(in: fixture)

        let moduleURL = fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString
        let source = SVNProvider(runner: fixture.runner)
        let target = GitMigrationTargetProvider(runner: fixture.runner)

        // 普通远程目录迁移：预览仓库不能发布到远端，并且每个提交都与旧导出 oracle 一致。
        let remotePlan = try await source.planMigration(
            from: RemoteRepositoryLocation(url: moduleURL), mode: .history, includeCopyHistory: true, progress: { _ in }
        )
        let remote = fixture.root.appendingPathComponent("remotes/verified-standard.git", isDirectory: true)
        try await git(["init", "--bare", remote.path], fixture: fixture)
        let standardPlan = MigrationPlan(
            source: remotePlan, targetProviderID: .git, remoteURL: remote.absoluteURL.absoluteString,
            branch: "main", destination: fixture.root.appendingPathComponent("verified-standard-preview", isDirectory: true),
            authors: authors(for: remotePlan)
        )
        let standardService = RepositoryMigrationService(sources: [source], targets: [target])
        let standardProgress = BenchmarkProgressRecorder()
        let standardPreview = try await standardService.prepare(standardPlan, progress: { update in
            await standardProgress.append(update.detail)
        })
        try await assertEveryCommit(
            preview: standardPreview, source: source, target: target, fixture: fixture, label: "standard"
        )
        let standardDetails = await standardProgress.details()
        #expect(standardDetails.contains(where: { $0.contains("复用 ") }))
        #expect(try await remoteRefs(remote, fixture: fixture).isEmpty)

        // 当前工作副本初迁：单独检出目标目录，记录 .svn 内容和工作树。prepare 只能在
        // 临时 Git 预览内写对象，绝不能更新该工作副本或发布远端。
        let workingCopy = fixture.root.appendingPathComponent("verified-working-copy", isDirectory: true)
        try await svn(["checkout", moduleURL, workingCopy.path], in: fixture.root, fixture: fixture)
        let workingCopyBefore = try treeSignature(at: workingCopy, excludingSVN: true)
        let databaseBefore = try Data(contentsOf: workingCopy.appendingPathComponent(".svn/wc.db"))
        let workingRemote = fixture.root.appendingPathComponent("remotes/verified-working-copy.git", isDirectory: true)
        try await git(["init", "--bare", workingRemote.path], fixture: fixture)
        let workingService = WorkingCopyMigrationService(source: source, target: target)
        let workingPlan = try await workingService.plan(
            at: workingCopy, remoteURL: workingRemote.absoluteURL.absoluteString, branch: "main",
            mode: .history, action: .initial, progress: { _ in }
        )
        let workingProgress = BenchmarkProgressRecorder()
        let workingPreview = try await workingService.prepare(workingPlan, progress: { update in
            await workingProgress.append(update.detail)
        })
        let temporaryJob = try #require(await workingService.partialDirectory(for: workingPlan.id))
        defer { removeOwnedWorkingPreview(temporaryJob) }
        // WorkingCopyMigrationService 的预览按设计位于系统临时目录。测试夹具拒绝让
        // 命令直接在根目录外运行，因此复制到夹具内的只读审计副本后再做 Git 树核对；
        // 不放宽 LocalRepositoryFixture 对路径和远端的通用保护。
        let auditedPreview = fixture.root.appendingPathComponent("audited-working-preview", isDirectory: true)
        try FileManager.default.copyItem(at: workingPreview.repository, to: auditedPreview)
        #expect(workingPreview.mappings.count == workingPlan.source.revisions.count)
        #expect(try await gitCount(in: auditedPreview, fixture: fixture) == workingPlan.source.revisions.count)
        try await assertEveryCommit(
            sourcePlan: workingPlan.source, mappings: workingPreview.mappings, repository: auditedPreview,
            source: source, target: target, fixture: fixture, label: "working-copy"
        )
        let workingDetails = await workingProgress.details()
        #expect(workingDetails.contains(where: { $0.contains("复用 ") }))
        #expect(try treeSignature(at: workingCopy, excludingSVN: true) == workingCopyBefore)
        #expect(try Data(contentsOf: workingCopy.appendingPathComponent(".svn/wc.db")) == databaseBefore)
        #expect(try await svnStatus(workingCopy, fixture: fixture).isEmpty)
        #expect(try await remoteRefs(workingRemote, fixture: fixture).isEmpty)
    }

    @Test("已验证 Git 会话在同一快照夹具记录实际 blob 复用基准")
    func verifiedSessionRecordsObjectReuseBenchmark() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedPerformanceModule(in: fixture)

        let source = SVNProvider(runner: fixture.runner)
        let sourcePlan = try await source.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.appendingPathComponent("性能迁移模块", isDirectory: true).absoluteString),
            mode: .history, includeCopyHistory: true, progress: { _ in }
        )
        #expect(sourcePlan.revisions.count == 4)

        // SVN 导出不计入基准：这里先把同一组不可变快照准备好，随后只度量两种 Git
        // 对象构造路径。不能把本地 SVN export 或网络字节数伪称为 Git 会话的提速。
        let sourceCache = fixture.root.appendingPathComponent("benchmark-source-cache", isDirectory: true)
        let sourceSession = try await source.makeMigrationSnapshotSession(plan: sourcePlan, in: sourceCache)
        var snapshots: [(MigrationRevision, URL, [MigrationFileEntry])] = []
        for (index, revision) in sourcePlan.revisions.enumerated() {
            let snapshot = fixture.root.appendingPathComponent("benchmark-snapshot-\(index)", isDirectory: true)
            try await sourceSession.exportSnapshot(revision: revision, to: snapshot, progress: { _ in })
            let entries = try migrationEntries(at: snapshot)
            try #require(!entries.isEmpty)
            snapshots.append((revision, snapshot, entries))
        }

        let target = GitMigrationTargetProvider(runner: fixture.runner)
        let author = MigrationAuthor(name: "benchmark", email: "benchmark@example.test")
        let legacyRepository = fixture.root.appendingPathComponent("legacy-git", isDirectory: true)
        try await target.initializeMigration(at: legacyRepository, branch: "main")
        let legacyStart = ProcessInfo.processInfo.systemUptime
        var legacyTip = ""
        for (index, item) in snapshots.enumerated() {
            let (revision, snapshot, expectedEntries) = item
            legacyTip = try await target.appendMigrationSnapshot(from: snapshot, revision: revision, author: author, to: legacyRepository, progress: { _ in })
            let verification = fixture.root.appendingPathComponent("legacy-verification-\(index)", isDirectory: true)
            try await target.exportMigrationTree(at: legacyRepository, revision: legacyTip, to: verification)
            #expect(try migrationEntries(at: verification) == expectedEntries)
        }
        try await target.verifyMigration(at: legacyRepository, expectedTip: legacyTip, branch: "main")
        let legacySeconds = ProcessInfo.processInfo.systemUptime - legacyStart

        let verifiedRepository = fixture.root.appendingPathComponent("verified-git", isDirectory: true)
        try await target.initializeMigration(at: verifiedRepository, branch: "main")
        let recorder = BenchmarkProgressRecorder()
        let verified = try await target.makeVerifiedMigrationSession(at: verifiedRepository)
        let verifiedStart = ProcessInfo.processInfo.systemUptime
        var verifiedTip = ""
        for (revision, snapshot, entries) in snapshots {
            verifiedTip = try await verified.appendVerifiedSnapshot(from: snapshot, files: entries, revision: revision, author: author) { update in
                await recorder.append(update.detail)
            }
        }
        // 新路径在会话内核对每次提交的对象树，业务层仍只在末次做一次完整导出及文件
        // 清单核对。这里与实际服务的边界一致，且不会隐藏最终 materialize 的成本。
        let verifiedCheck = fixture.root.appendingPathComponent("verified-final-verification", isDirectory: true)
        try await target.exportMigrationTree(at: verifiedRepository, revision: verifiedTip, to: verifiedCheck)
        guard let finalSnapshot = snapshots.last else { throw FixtureError.emptySnapshots }
        let finalExpected = finalSnapshot.2
        #expect(try migrationEntries(at: verifiedCheck) == finalExpected)
        try await target.verifyMigration(at: verifiedRepository, expectedTip: verifiedTip, branch: "main")
        let verifiedSeconds = ProcessInfo.processInfo.systemUptime - verifiedStart
        let details = await recorder.details()
        let maximumReused = details.compactMap(reusedBlobCount).max() ?? 0
        let maximumChanged = details.compactMap(changedBlobCount).max() ?? 0

        #expect(try await gitCount(in: legacyRepository, fixture: fixture) == snapshots.count)
        #expect(try await gitCount(in: verifiedRepository, fixture: fixture) == snapshots.count)
        #expect(maximumReused >= 600)
        #expect(maximumChanged > 0)
        let report: [String: Any] = [
            "scope": "Git construction and verification: legacy exports and scans every revision; verified session exports and scans final revision only. Excludes SVN reads, source scans, and business checkpoints.",
            "revisions": snapshots.count,
            "snapshotFiles": snapshots.first.map { $0.2.count } ?? 0,
            "legacyFullSnapshotSeconds": legacySeconds,
            "verifiedSessionSeconds": verifiedSeconds,
            "maximumReusedBlobs": maximumReused,
            "maximumChangedBlobs": maximumChanged,
            "progressDetails": details
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-verified-migration-benchmark.json")
        try data.write(to: reportURL, options: .atomic)
        print("Verified migration benchmark JSON: \(reportURL.path)\n\(String(decoding: data, as: UTF8.self))")
    }

    @Test("已验证 Git 会话中断后从检查点恢复且不重复首个提交")
    func verifiedGitSessionResumesAfterSourceFailureWithoutDuplicatingCommit() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedLargeCopiedModule(in: fixture)

        let sourceURL = fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString
        let remote = fixture.root.appendingPathComponent("remotes/verified-resume.git", isDirectory: true)
        try await git(["init", "--bare", remote.path], fixture: fixture)
        let gate = SnapshotFailureGate(failAt: 2)
        let source = FailingSnapshotSource(base: SVNProvider(runner: fixture.runner), gate: gate)
        let service = RepositoryMigrationService(sources: [source], targets: [GitMigrationTargetProvider(runner: fixture.runner)])
        let plan = try await service.plan(
            sourceProviderID: .svn, location: RemoteRepositoryLocation(url: sourceURL), mode: .history,
            targetProviderID: .git, remoteURL: remote.absoluteURL.absoluteString, branch: "main",
            destination: fixture.root.appendingPathComponent("verified-resume-preview", isDirectory: true), progress: { _ in }
        )

        await #expect(throws: Error.self) {
            try await service.prepare(plan, progress: { _ in })
        }
        let partial = try #require(await service.partialDirectory(for: plan.id))
        let repository = partial.appendingPathComponent("repository", isDirectory: true)
        #expect(try await gitCount(in: repository, fixture: fixture) == 1)
        #expect(try await remoteRefs(remote, fixture: fixture).isEmpty)

        let preview = try await service.prepare(plan, progress: { _ in })
        #expect(preview.mappings.count == plan.source.revisions.count)
        #expect(try await gitCount(in: preview.repository, fixture: fixture) == plan.source.revisions.count)
        let firstCommit = try #require(preview.mappings.first?.targetCommit)
        let rebuiltFirstCommit = try await gitOutput(
            ["rev-parse", "HEAD~\(plan.source.revisions.count - 1)"], in: preview.repository, fixture: fixture
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(firstCommit == rebuiltFirstCommit)
        #expect(try await remoteRefs(remote, fixture: fixture).isEmpty)
        #expect(try await svnStatus(fixture.svnWriter, fixture: fixture).isEmpty)
    }

    @Test("隔离 SVN 缓存被篡改后拒绝继续导出且会话失效")
    func tamperedSVNSourceCacheIsRejectedAndInvalidated() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedLargeCopiedModule(in: fixture)

        let source = SVNProvider(runner: fixture.runner)
        let plan = try await source.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.appendingPathComponent("迁移模块", isDirectory: true).absoluteString),
            mode: .history, includeCopyHistory: true, progress: { _ in }
        )
        let cache = fixture.root.appendingPathComponent("tampered-source-cache", isDirectory: true)
        let session = try await source.makeMigrationSnapshotSession(plan: plan, in: cache)
        let first = try #require(plan.revisions.first)
        let second = try #require(plan.revisions.dropFirst().first)
        try await session.exportSnapshot(revision: first, to: fixture.root.appendingPathComponent("clean-first", isDirectory: true), progress: { _ in })

        // 只破坏业务层创建的隔离缓存，绝不接触 fixture.svnWriter 这个模拟用户工作副本。
        let cachedFile = cache.appendingPathComponent("working-copy/assets/固定-00.bin")
        try Data([0x54, 0x41, 0x4D, 0x50, 0x45, 0x52]).write(to: cachedFile, options: .atomic)
        await #expect(throws: Error.self) {
            try await session.exportSnapshot(revision: second, to: fixture.root.appendingPathComponent("tampered-second", isDirectory: true), progress: { _ in })
        }
        // 失败后的 session 必须永久失效，不能带着半切换/脏缓存继续导出。
        await #expect(throws: Error.self) {
            try await session.exportSnapshot(revision: second, to: fixture.root.appendingPathComponent("tampered-retry", isDirectory: true), progress: { _ in })
        }
        #expect(try await svnStatus(fixture.svnWriter, fixture: fixture).isEmpty)
    }

    private func assertEveryCommit(
        preview: MigrationPreview,
        source: SVNProvider,
        target: GitMigrationTargetProvider,
        fixture: LocalRepositoryFixture,
        label: String
    ) async throws {
        #expect(preview.mappings.count == preview.plan.source.revisions.count)
        #expect(try await gitCount(in: preview.repository, fixture: fixture) == preview.plan.source.revisions.count)
        try await assertEveryCommit(
            sourcePlan: preview.plan.source, mappings: preview.mappings, repository: preview.repository,
            source: source, target: target, fixture: fixture, label: label
        )
    }

    private func assertEveryCommit(
        sourcePlan: MigrationSourcePlan,
        mappings: [MigrationMapping],
        repository: URL,
        source: SVNProvider,
        target: GitMigrationTargetProvider,
        fixture: LocalRepositoryFixture,
        label: String
    ) async throws {
        #expect(mappings.count == sourcePlan.revisions.count)
        var unchangedBlobIDs = Set<String>()
        for (index, mapping) in mappings.enumerated() {
            let oracle = fixture.root.appendingPathComponent("\(label)-oracle-\(index)", isDirectory: true)
            let actual = fixture.root.appendingPathComponent("\(label)-actual-\(index)", isDirectory: true)
            try await source.exportMigrationSnapshot(plan: sourcePlan, revision: mapping.source, to: oracle, progress: { _ in })
            try await target.exportMigrationTree(at: repository, revision: mapping.targetCommit, to: actual)
            let expectedTree = try treeSignature(at: oracle)
            let actualTree = try treeSignature(at: actual)
            try #require(!expectedTree.isEmpty)
            #expect(actualTree == expectedTree)

            // 逐修订读取 Git 真实树，不用工作区状态代替对象库断言。
            let listed = try await gitOutput(["ls-tree", "-r", "--full-tree", mapping.targetCommit], in: repository, fixture: fixture)
            #expect(!listed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let staticBlob = try await gitOutput(["rev-parse", "\(mapping.targetCommit):assets/固定-00.bin"], in: repository, fixture: fixture)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!staticBlob.isEmpty)
            unchangedBlobIDs.insert(staticBlob)
        }
        // 多次历史快照中的大文件内容未变时，对象 ID 必须复用。该断言不把网络字节数
        // 当作速度指标，只证明最终 Git 对象库没有复制出多个内容相同的 blob。
        #expect(unchangedBlobIDs.count == 1)
    }

    private func seedLargeCopiedModule(in fixture: LocalRepositoryFixture) async throws {
        let old = fixture.svnWriter.appendingPathComponent("旧迁移模块", isDirectory: true)
        let assets = old.appendingPathComponent("assets", isDirectory: true)
        let source = old.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<8 {
            let bytes = Data(repeating: UInt8(index + 1), count: 192 * 1024)
            try bytes.write(to: assets.appendingPathComponent(String(format: "固定-%02d.bin", index)))
        }
        try "first\n".write(to: source.appendingPathComponent("旧名.txt"), atomically: true, encoding: .utf8)
        try "delete me\n".write(to: old.appendingPathComponent("删除我.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho first\n".write(to: old.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("run-link").path, withDestinationPath: "run.sh")
        try await svn(["add", "旧迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("建立大文件旧目录", author: "fixture-a", fixture: fixture)

        try "second\n".write(to: source.appendingPathComponent("旧名.txt"), atomically: true, encoding: .utf8)
        try await svnCommit("修改旧目录文本", author: "fixture-b", fixture: fixture)
        try await svn(["update"], in: fixture.svnWriter, fixture: fixture)
        try await svn(["copy", "旧迁移模块", "迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("复制为迁移目录", author: "fixture-c", fixture: fixture)

        let current = fixture.svnWriter.appendingPathComponent("迁移模块", isDirectory: true)
        try await svn(["move", "src/旧名.txt", "src/新名.txt"], in: current, fixture: fixture)
        try await svn(["delete", "删除我.txt"], in: current, fixture: fixture)
        try "#!/bin/sh\necho final\n".write(to: current.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try await svnCommit("改名删除并更新脚本", author: "fixture-d", fixture: fixture)
    }

    private func seedPerformanceModule(in fixture: LocalRepositoryFixture) async throws {
        let module = fixture.svnWriter.appendingPathComponent("性能迁移模块", isDirectory: true)
        let small = module.appendingPathComponent("small", isDirectory: true)
        let large = module.appendingPathComponent("large", isDirectory: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for index in 0..<640 {
            try "stable file \(index)\n".write(to: small.appendingPathComponent(String(format: "file-%04d.txt", index)), atomically: true, encoding: .utf8)
        }
        for index in 0..<4 {
            try Data(repeating: UInt8(index + 40), count: 768 * 1024).write(to: large.appendingPathComponent(String(format: "blob-%02d.bin", index)))
        }
        try "first\n".write(to: module.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        try "rename\n".write(to: module.appendingPathComponent("old-name.txt"), atomically: true, encoding: .utf8)
        try "remove\n".write(to: module.appendingPathComponent("remove.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: module.appendingPathComponent("stable-link").path, withDestinationPath: "small/file-0000.txt")
        try await svn(["add", "性能迁移模块"], in: fixture.svnWriter, fixture: fixture)
        try await svnCommit("性能基准初始快照", author: "benchmark", fixture: fixture)

        try "second\n".write(to: module.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        try await svnCommit("性能基准文本变化", author: "benchmark", fixture: fixture)
        try "third\n".write(to: module.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        try await svn(["move", "old-name.txt", "new-name.txt"], in: module, fixture: fixture)
        try await svnCommit("性能基准改名", author: "benchmark", fixture: fixture)
        try "fourth\n".write(to: module.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        try await svn(["delete", "remove.txt"], in: module, fixture: fixture)
        try await svnCommit("性能基准删除", author: "benchmark", fixture: fixture)
    }

    private func migrationEntries(at root: URL) throws -> [MigrationFileEntry] {
        let manager = FileManager.default
        var entries: [MigrationFileEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + child.lastPathComponent
                let attributes = try manager.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    entries.append(MigrationFileEntry(path: path, kind: .directory, digest: "", size: 0))
                    try visit(child, prefix: path + "/")
                case .typeSymbolicLink:
                    let value = try manager.destinationOfSymbolicLink(atPath: child.path)
                    entries.append(MigrationFileEntry(path: path, kind: .symbolicLink, digest: digest(Data(value.utf8)), size: UInt64(value.utf8.count)))
                case .typeRegular:
                    let data = try Data(contentsOf: child)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
                    entries.append(MigrationFileEntry(path: path, kind: .file, digest: digest(data), size: size, executable: executable))
                default:
                    throw VersionControlError.unsupported("性能夹具包含不支持的节点：\(path)")
                }
            }
        }
        try visit(root, prefix: "")
        return entries.sorted { $0.path < $1.path }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func reusedBlobCount(_ detail: String?) -> Int? {
        number(after: "复用 ", in: detail)
    }

    private func changedBlobCount(_ detail: String?) -> Int? {
        number(after: "变化 ", in: detail) ?? number(after: "写入 ", in: detail)
    }

    private func number(after marker: String, in detail: String?) -> Int? {
        guard let detail, let range = detail.range(of: marker) else { return nil }
        let digits = detail[range.upperBound...].prefix { $0.isWholeNumber }
        return Int(digits)
    }

    private func authors(for plan: MigrationSourcePlan) -> [String: MigrationAuthor] {
        Dictionary(plan.revisions.map { revision in
            (revision.author, MigrationAuthor(name: revision.author, email: "\(revision.author)@example.test"))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func treeSignature(at root: URL, excludingSVN: Bool = false) throws -> [String: String] {
        let manager = FileManager.default
        var result: [String: String] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = child.lastPathComponent
                if excludingSVN && prefix.isEmpty && name == ".svn" { continue }
                let path = prefix + name
                let attributes = try manager.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    result["d:\(path)"] = ""
                    try visit(child, prefix: path + "/")
                case .typeSymbolicLink:
                    result["l:\(path)"] = try manager.destinationOfSymbolicLink(atPath: child.path)
                case .typeRegular:
                    result["f:\(path)"] = try Data(contentsOf: child).base64EncodedString()
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    result["x:\(path)"] = mode & 0o111 == 0 ? "0" : "1"
                default:
                    throw VersionControlError.unsupported("测试树包含不支持的节点：\(path)")
                }
            }
        }
        try visit(root, prefix: "")
        return result
    }

    private func requireTools() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil, ToolLocator.find("git") != nil else {
            throw FixtureError.toolUnavailable
        }
    }

    private func svn(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: arguments, directory: directory), tool: "svn")
    }

    private func svnCommit(_ message: String, author: String, fixture: LocalRepositoryFixture) async throws {
        try await svn(["commit", "--username", author, "-m", message], in: fixture.svnWriter, fixture: fixture)
    }

    private func svnStatus(_ directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "svn", arguments: ["status"], directory: directory), tool: "svn")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func git(_ arguments: [String], fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: arguments), tool: "git")
    }

    private func gitOutput(_ arguments: [String], in directory: URL, fixture: LocalRepositoryFixture) async throws -> String {
        try requireSuccess(try await fixture.run(executable: "git", arguments: arguments, directory: directory), tool: "git").output
    }

    private func gitCount(in repository: URL, fixture: LocalRepositoryFixture) async throws -> Int {
        Int(try await gitOutput(["rev-list", "--count", "HEAD"], in: repository, fixture: fixture)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private func remoteRefs(_ remote: URL, fixture: LocalRepositoryFixture) async throws -> [String] {
        let output = try await gitOutput(["ls-remote", "--refs", "--", remote.absoluteURL.absoluteString], in: fixture.root, fixture: fixture)
        return output.split(separator: "\n").map(String.init)
    }

    private func removeOwnedWorkingPreview(_ folder: URL) {
        let normalized = folder.standardizedFileURL
        let name = normalized.lastPathComponent
        let prefix = "RepHub-working-copy-migration-"
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              normalized.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else {
            return
        }
        try? FileManager.default.removeItem(at: normalized)
    }

    private enum FixtureError: Error { case toolUnavailable, emptySnapshots }
}

private actor BenchmarkProgressRecorder {
    private var values: [String] = []
    func append(_ value: String?) { if let value { values.append(value) } }
    func details() -> [String] { values }
}

private actor SnapshotFailureGate {
    private let failAt: Int
    private var count = 0
    private var failed = false

    init(failAt: Int) { self.failAt = failAt }

    func beforeExport() throws {
        count += 1
        if !failed, count == failAt {
            failed = true
            throw VersionControlError.executionFailed("测试注入：第二次 SVN 快照导出中断。")
        }
    }
}

private struct FailingSnapshotSource: RepositoryMigrationSourceProvider {
    let base: SVNProvider
    let gate: SnapshotFailureGate
    var id: ProviderID { base.id }

    func planMigration(from location: RemoteRepositoryLocation, mode: MigrationMode,
                       progress: @escaping RepositoryOperationProgressHandler) async throws -> MigrationSourcePlan {
        try await base.planMigration(from: location, mode: mode, progress: progress)
    }

    func exportMigrationSnapshot(plan: MigrationSourcePlan, revision: MigrationRevision, to directory: URL,
                                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await base.exportMigrationSnapshot(plan: plan, revision: revision, to: directory, progress: progress)
    }

    func makeMigrationSnapshotSession(plan: MigrationSourcePlan, in workspace: URL) async throws -> any RepositoryMigrationSnapshotSession {
        let session = try await base.makeMigrationSnapshotSession(plan: plan, in: workspace)
        return FailingSnapshotSession(base: session, gate: gate)
    }
}

private struct FailingSnapshotSession: RepositoryMigrationSnapshotSession {
    let base: any RepositoryMigrationSnapshotSession
    let gate: SnapshotFailureGate

    func exportSnapshot(revision: MigrationRevision, to directory: URL,
                        progress: @escaping RepositoryOperationProgressHandler) async throws {
        try await gate.beforeExport()
        try await base.exportSnapshot(revision: revision, to: directory, progress: progress)
    }
}
