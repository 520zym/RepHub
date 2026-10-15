import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("Git 迁移目标")
struct GitMigrationTargetProviderTests {
    @Test("快照迁移保留作者时间、可执行位、符号链接并发布到空裸仓库")
    func createsPreviewAndPublishesToEmptyTarget() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let snapshot = fixture.root.appendingPathComponent("migration-source", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("migration-preview", isDirectory: true)
        let exported = fixture.root.appendingPathComponent("migration-export", isDirectory: true)
        let remote = fixture.root.appendingPathComponent("remotes/migration-target.git", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "ignored by source gitignore\n".write(to: snapshot.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho migrated\n".write(to: snapshot.appendingPathComponent("bin/run"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.appendingPathComponent("bin/run").path)
        try FileManager.default.createSymbolicLink(atPath: snapshot.appendingPathComponent("latest").path, withDestinationPath: "bin/run")
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["init", "--bare", remote.path]), tool: "git")

        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.checkMigrationTarget(remoteURL: remote.path, branch: "main")
        try await provider.initializeMigration(at: preview, branch: "main")
        let revision = MigrationRevision(id: "r42", author: "old-svn-user", date: Date(timeIntervalSince1970: 1_700_000_000), message: "保留原始说明\n\n第二段")
        let tip = try await provider.appendMigrationSnapshot(from: snapshot, revision: revision, author: MigrationAuthor(name: "Old User", email: "old@example.test"), to: preview, progress: { _ in })
        try await provider.verifyMigration(at: preview, expectedTip: tip, branch: "main")
        try await provider.exportMigrationTree(at: preview, revision: tip, to: exported)
        #expect(try String(contentsOf: exported.appendingPathComponent("ignored.txt"), encoding: .utf8) == "ignored by source gitignore\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: exported.appendingPathComponent("latest").path) == "bin/run")
        let executable = (try FileManager.default.attributesOfItem(atPath: exported.appendingPathComponent("bin/run").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((executable & 0o111) != 0)
        let author = try requireSuccess(try await fixture.run(executable: "git", arguments: ["show", "-s", "--format=%an|%ae|%aI|%B", tip], directory: preview), tool: "git").output
        #expect(author.contains("Old User|old@example.test|"))
        #expect(author.contains("保留原始说明\n\n第二段"))
        let published = try await provider.publishMigration(at: preview, remoteURL: remote.path, branch: "main", expectedTip: tip, progress: { _ in })
        #expect(published.state == .published)
        let remoteTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["--git-dir", remote.path, "rev-parse", "refs/heads/main"]), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteTip == tip)
        let trackingTip = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-parse", "refs/remotes/origin/main"], directory: preview), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let divergence = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-list", "--left-right", "--count", "main...origin/main"], directory: preview), tool: "git").output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trackingTip == tip)
        #expect(divergence.split(whereSeparator: \.isWhitespace).map(String.init) == ["0", "0"])
    }

    @Test("已有引用和快照元数据均被拒绝")
    func rejectsNonEmptyTargetAndMetadataSnapshot() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        var nonEmptyRejected = false
        do { try await provider.checkMigrationTarget(remoteURL: fixture.gitRemote.path, branch: "main") } catch { nonEmptyRejected = true }
        #expect(nonEmptyRejected)

        let snapshot = fixture.root.appendingPathComponent("bad-migration-source", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("bad-migration-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot.appendingPathComponent(".svn"), withIntermediateDirectories: true)
        try await provider.initializeMigration(at: preview, branch: "main")
        var metadataRejected = false
        do {
            _ = try await provider.appendMigrationSnapshot(
                from: snapshot,
                revision: MigrationRevision(id: "r1", author: "u", date: .now, message: "x"),
                author: MigrationAuthor(name: "User", email: "user@example.test"),
                to: preview,
                progress: { _ in }
            )
        } catch { metadataRejected = true }
        #expect(metadataRejected)
    }

    @Test("迁移本地生成和校验不继承全局过滤器")
    func localMigrationCommandsUseIsolatedGitConfiguration() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let script = fixture.root.appendingPathComponent("filter-marker.sh")
        let marker = fixture.root.appendingPathComponent("filter-ran")
        let snapshot = fixture.root.appendingPathComponent("filter-source", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("filter-preview", isDirectory: true)
        try "#!/bin/sh\necho ran >> '\(marker.path)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: ["config", "--global", "filter.rephub.clean", script.path]), tool: "git")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "*.filtered filter=rephub\n".write(to: snapshot.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "must not invoke the global filter\n".write(to: snapshot.appendingPathComponent("sample.filtered"), atomically: true, encoding: .utf8)

        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.initializeMigration(at: preview, branch: "main")
        let tip = try await provider.appendMigrationSnapshot(
            from: snapshot,
            revision: MigrationRevision(id: "r-filter", author: "u", date: .now, message: "filter"),
            author: MigrationAuthor(name: "User", email: "user@example.test"),
            to: preview,
            progress: { _ in }
        )
        try await provider.verifyMigration(at: preview, expectedTip: tip, branch: "main")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("批量快照和对象导出保留大量文件、二进制、符号链接及特殊路径")
    func batchesSnapshotHashingAndObjectExport() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let snapshot = fixture.root.appendingPathComponent("batch-source", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("batch-preview", isDirectory: true)
        let exported = fixture.root.appendingPathComponent("batch-export", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        var expected: [String: Data] = [:]
        for index in 0..<320 {
            let directory = snapshot.appendingPathComponent("group-\(index / 40)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = index == 17 ? "file with space\nand newline.bin" : "file-\(index).bin"
            let path = "group-\(index / 40)/\(name)"
            let data = Data((0..<1024).map { UInt8((index + $0) % 251) })
            try data.write(to: directory.appendingPathComponent(name))
            expected[path] = data
        }
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("linked-file").path,
            withDestinationPath: "group-0/file-0.bin"
        )
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.initializeMigration(at: preview, branch: "main")
        let writeProgress = MigrationProgressCollector()
        let tip = try await provider.appendMigrationSnapshot(
            from: snapshot,
            revision: MigrationRevision(id: "r-batch", author: "old", date: .now, message: "batch"),
            author: MigrationAuthor(name: "Batch User", email: "batch@example.test"),
            to: preview,
            progress: { update in await writeProgress.append(update.message) }
        )
        #expect((await writeProgress.messages()).filter { $0.contains("Git 文件对象") }.count >= 2)
        let exportProgress = MigrationProgressCollector()
        try await provider.exportMigrationTree(at: preview, revision: tip, to: exported, progress: { update in
            await exportProgress.append(update.message)
        })
        #expect((await exportProgress.messages()).contains { $0.contains("Git 对象") })
        for (path, data) in expected {
            #expect(try Data(contentsOf: exported.appendingPathComponent(path)) == data)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: exported.appendingPathComponent("linked-file").path) == "group-0/file-0.bin")
    }

    @Test("接近读取上限的 blob 保持旧单对象导出能力")
    func exportsLargeBlobWithoutBatchProtocolOverhead() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let snapshot = fixture.root.appendingPathComponent("large-source", isDirectory: true)
        let preview = fixture.root.appendingPathComponent("large-preview", isDirectory: true)
        let exported = fixture.root.appendingPathComponent("large-export", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let contents = Data(repeating: 0xA5, count: 15 * 1024 * 1024 + 1)
        try contents.write(to: snapshot.appendingPathComponent("near-limit.bin"))
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.initializeMigration(at: preview, branch: "main")
        let tip = try await provider.appendMigrationSnapshot(
            from: snapshot,
            revision: MigrationRevision(id: "r-large", author: "old", date: .now, message: "large"),
            author: MigrationAuthor(name: "Large User", email: "large@example.test"),
            to: preview,
            progress: { _ in }
        )
        try await provider.exportMigrationTree(at: preview, revision: tip, to: exported)
        #expect(try Data(contentsOf: exported.appendingPathComponent("near-limit.bin")) == contents)
    }

    @Test(".git 指向其他仓库时拒绝迁移核对")
    func rejectsGitPointerOutsideMigrationDirectory() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        let expectedTip = String(repeating: "a", count: 40)

        let symlinkPreview = fixture.root.appendingPathComponent("linked-git-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkPreview, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPreview.appendingPathComponent(".git").path, withDestinationPath: fixture.gitReader.appendingPathComponent(".git").path)
        var symlinkRejected = false
        do { try await provider.verifyMigration(at: symlinkPreview, expectedTip: expectedTip, branch: "main") } catch { symlinkRejected = true }
        #expect(symlinkRejected)

        let filePreview = fixture.root.appendingPathComponent("file-git-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: filePreview, withIntermediateDirectories: true)
        try "gitdir: \(fixture.gitReader.appendingPathComponent(".git").path)\n".write(to: filePreview.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        var fileRejected = false
        do { try await provider.verifyMigration(at: filePreview, expectedTip: expectedTip, branch: "main") } catch { fileRejected = true }
        #expect(fileRejected)
    }

    @Test("HTTP 地址中的用户信息在联网前被拒绝")
    func rejectsCredentialBearingHTTPRemoteBeforeNetworkAccess() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        var rejected = false
        do { try await provider.checkMigrationTarget(remoteURL: "https://token@example.invalid/target.git", branch: "main") } catch { rejected = true }
        #expect(rejected)
    }
}

private actor MigrationProgressCollector {
    private var values: [String] = []
    func append(_ message: String) { values.append(message) }
    func messages() -> [String] { values }
}
