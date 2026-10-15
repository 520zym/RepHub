import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNMigrationSessionTests: XCTestCase {
    func testHistoricalURLQueryOverlapsIsolatedCheckoutBeforeSnapshotExport() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let planningProvider = SVNProvider(runner: fixture.runner)
        let plan = try await planningProvider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .history, progress: { _ in }
        )
        let cache = fixture.root.appendingPathComponent("overlap-session-cache", isDirectory: true)
        let gate = SnapshotHistoryGate(cache: cache, address: fixture.svnURL.absoluteString, shouldFailHistoricalInfo: false)
        let provider = SVNProvider(
            runner: fixture.runner,
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, directory, configuration in
                // 测试桩只模拟固定 peg 的远端 info；缓存工作副本内的 info/status
                // 必须走真实 svn，才能继续验证 UUID、working-copy-root 与状态。
                if directory.standardizedFileURL == cache.appendingPathComponent("working-copy", isDirectory: true).standardizedFileURL {
                    return try await fixture.runner.run(executable: "svn", arguments: arguments, directory: directory,
                                                        opensslConfiguration: configuration)
                }
                return await gate.respond(to: arguments)
            }
        )
        let session = try await provider.makeMigrationSnapshotSession(plan: plan, in: cache)
        let destination = fixture.root.appendingPathComponent("overlap-session-snapshot", isDirectory: true)
        try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })

        let observedCheckout = await gate.observedCheckoutDuringHistoricalInfo()
        XCTAssertTrue(observedCheckout, "固定 peg 的历史 URL 查询等待期间，隔离 checkout 应已启动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testHistoricalURLFailureLeavesNoSnapshotAndInvalidatesSession() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let planningProvider = SVNProvider(runner: fixture.runner)
        let plan = try await planningProvider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .history, progress: { _ in }
        )
        let cache = fixture.root.appendingPathComponent("failed-history-session-cache", isDirectory: true)
        let gate = SnapshotHistoryGate(cache: cache, address: fixture.svnURL.absoluteString, shouldFailHistoricalInfo: true)
        let provider = SVNProvider(
            runner: fixture.runner,
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, directory, configuration in
                if directory.standardizedFileURL == cache.appendingPathComponent("working-copy", isDirectory: true).standardizedFileURL {
                    return try await fixture.runner.run(executable: "svn", arguments: arguments, directory: directory,
                                                        opensslConfiguration: configuration)
                }
                return await gate.respond(to: arguments)
            }
        )
        let session = try await provider.makeMigrationSnapshotSession(plan: plan, in: cache)
        let destination = fixture.root.appendingPathComponent("failed-history-snapshot", isDirectory: true)
        await XCTAssertThrowsErrorAsync {
            try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "历史 URL 校验失败前不得导出本地快照")
        let retry = fixture.root.appendingPathComponent("failed-history-retry", isDirectory: true)
        await XCTAssertThrowsErrorAsync {
            try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: retry, progress: { _ in })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: retry.path), "失败会话不得继续导出")
    }

    func testSessionChecksOutOnceThenSwitchesAndExportsSnapshotsFromItsLocalCache() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let readme = fixture.svnWriter.appendingPathComponent("README.md")
        try "revision three\n".write(to: readme, atomically: true, encoding: .utf8)
        try await success(fixture, ["commit", "-m", "revision three"], directory: fixture.svnWriter)
        try "revision four\n".write(to: readme, atomically: true, encoding: .utf8)
        try await success(fixture, ["commit", "-m", "revision four"], directory: fixture.svnWriter)

        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .history, progress: { _ in }
        )
        XCTAssertEqual(plan.revisions.map(\.id), ["r1", "r2", "r3", "r4"])

        let cache = fixture.root.appendingPathComponent("incremental-session-cache", isDirectory: true)
        let session = try await provider.makeMigrationSnapshotSession(plan: plan, in: cache)
        let expectedContents: [String: String?] = [
            "r1": nil,
            "r2": "initial fixture\n",
            "r3": "revision three\n",
            "r4": "revision four\n"
        ]
        let phaseCapture = MigrationPhaseCapture()
        for (index, revision) in plan.revisions.enumerated() {
            let destination = fixture.root.appendingPathComponent("session-snapshot-\(index)", isDirectory: true)
            try await session.exportSnapshot(revision: revision, to: destination) { update in
                await phaseCapture.append(update.message)
            }
            let readme = destination.appendingPathComponent("README.md")
            guard let expected = expectedContents[revision.id] else {
                return XCTFail("未声明测试修订 \(revision.id) 的预期内容")
            }
            if let expected {
                XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), expected)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: readme.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".svn").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("working-copy/.svn/wc.db").path))
        let phases = await phaseCapture.values()
        XCTAssertTrue(phases.contains("首次检出 SVN 快照…"))
        XCTAssertTrue(phases.contains("增量获取 SVN 快照…"))
        XCTAssertTrue(phases.contains("本地整理 SVN 快照…"))
    }

    func testSessionRejectsExistingCacheOutOfOrderRevisionAndDoesNotModifySeed() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .snapshot, progress: { _ in }
        )
        let existingCache = fixture.root.appendingPathComponent("existing-session-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: existingCache, withIntermediateDirectories: true)
        do {
            _ = try await provider.makeMigrationSnapshotSession(plan: plan, in: existingCache)
            XCTFail("已有缓存目录不能复用")
        } catch let error as VersionControlError {
            guard case .invalidRepository = error else { return XCTFail("错误类型不正确：\(error)") }
        }

        let sourceDatabase = fixture.svnReader.appendingPathComponent(".svn/wc.db")
        let beforeDatabase = try Data(contentsOf: sourceDatabase)
        let beforeReadme = try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md"))
        let cache = fixture.root.appendingPathComponent("seed-session-cache", isDirectory: true)
        let session = try await provider.makeMigrationSnapshotSession(
            plan: plan, in: cache, seedWorkingCopy: fixture.svnReader
        )
        let destination = fixture.root.appendingPathComponent("seed-session-snapshot", isDirectory: true)
        try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: sourceDatabase), beforeDatabase)
        XCTAssertEqual(try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md")), beforeReadme)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")), beforeReadme)

        do {
            let duplicate = fixture.root.appendingPathComponent("seed-session-duplicate", isDirectory: true)
            try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: duplicate, progress: { _ in })
            XCTFail("重复修订不能继续复用缓存")
        } catch let error as VersionControlError {
            guard case .invalidData = error else { return XCTFail("错误类型不正确：\(error)") }
        }

        do {
            let afterFailure = fixture.root.appendingPathComponent("seed-session-after-failure", isDirectory: true)
            try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: afterFailure, progress: { _ in })
            XCTFail("失败后的会话不能继续使用")
        } catch let error as VersionControlError {
            guard case .invalidRepository = error else { return XCTFail("错误类型不正确：\(error)") }
        }
    }

    func testAnchorSeedExportsWithoutRemoteAndExcludesUntrackedFiles() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .snapshot, progress: { _ in }
        )
        let untracked = fixture.svnReader.appendingPathComponent("local-only.txt")
        try "must not migrate\n".write(to: untracked, atomically: true, encoding: .utf8)
        let database = fixture.svnReader.appendingPathComponent(".svn/wc.db")
        let beforeDatabase = try Data(contentsOf: database)
        let beforeReadme = try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md"))

        let cache = fixture.root.appendingPathComponent("offline-seed-cache", isDirectory: true)
        let session = try await provider.makeMigrationSnapshotSession(
            plan: plan, in: cache, seedWorkingCopy: fixture.svnReader
        )
        // 计划已形成后让 file:// 服务端不可访问。anchor seed 的导出只能使用本地工作副本，
        // 若实现重新 checkout/export 远端，这一步会失败。
        try FileManager.default.moveItem(
            at: fixture.svnRepository,
            to: fixture.root.appendingPathComponent("offline-svn-repository", isDirectory: true)
        )

        let destination = fixture.root.appendingPathComponent("offline-seed-snapshot", isDirectory: true)
        try await session.exportSnapshot(revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")), beforeReadme)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("local-only.txt").path))
        XCTAssertEqual(try Data(contentsOf: database), beforeDatabase)
        XCTAssertEqual(try Data(contentsOf: fixture.svnReader.appendingPathComponent("README.md")), beforeReadme)
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 迁移会话测试。")
        }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ arguments: [String], directory: URL) async throws {
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: arguments, directory: directory), tool: "svn")
    }
}

private actor MigrationPhaseCapture {
    private var messages: [String] = []

    func append(_ message: String) { messages.append(message) }
    func values() -> [String] { messages }
}

private actor SnapshotHistoryGate {
    private let cache: URL
    private let address: String
    private let shouldFailHistoricalInfo: Bool
    private var observedCheckout = false

    init(cache: URL, address: String, shouldFailHistoricalInfo: Bool) {
        self.cache = cache
        self.address = address
        self.shouldFailHistoricalInfo = shouldFailHistoricalInfo
    }

    func respond(to arguments: [String]) async -> CommandResult {
        guard arguments.contains("info") else {
            return CommandResult(data: Data(), errorData: Data("unexpected command".utf8), exitCode: 1)
        }
        if arguments.contains("-r") {
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: cache.appendingPathComponent("working-copy/.svn").path) {
                    observedCheckout = true
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            if shouldFailHistoricalInfo {
                return CommandResult(data: Data(), errorData: Data("simulated historical info failure".utf8), exitCode: 1)
            }
        }
        let revision = arguments.drop(while: { $0 != "-r" }).dropFirst().first ?? "2"
        let xml = "<?xml version=\"1.0\"?><info><entry kind=\"dir\" path=\"\" revision=\"\(revision)\"><url>\(address)</url></entry></info>"
        return CommandResult(data: Data(xml.utf8), exitCode: 0)
    }

    func observedCheckoutDuringHistoricalInfo() -> Bool { observedCheckout }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("预期抛出错误", file: file, line: line)
    } catch {}
}
