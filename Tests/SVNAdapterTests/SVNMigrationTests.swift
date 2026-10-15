import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNMigrationTests: XCTestCase {
    func testWorkingCopyMigrationSourceRejectsRepositoryReplacementAtSameURL() async throws {
        let address = "file:///migration-fixture/trunk"
        let provider = SVNProvider(
            runner: CommandRunner(),
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { _, _, _ in
                CommandResult(data: Data("""
                <?xml version="1.0"?><info><entry kind="dir" path="" revision="9"><url>\(address)</url><repository><root>file:///migration-fixture</root><uuid>replacement-uuid</uuid></repository></entry></info>
                """.utf8), exitCode: 0)
            }
        )

        do {
            try await provider.verifyWorkingCopyMigrationSource(
                RemoteRepositoryLocation(url: address), repositoryUUID: "original-uuid", revision: "r9"
            )
            XCTFail("同一 URL 被替换为另一 SVN 仓库时必须拒绝迁移")
        } catch let error as VersionControlError {
            guard case let .invalidRepository(message) = error else { return XCTFail("错误类型不正确：\(error)") }
            XCTAssertTrue(message.contains("UUID"))
        }
    }

    func testInspectWorkingCopyRequiresCleanManagedStateButKeepsUntrackedFiles() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)

        try "not versioned\n".write(to: fixture.svnReader.appendingPathComponent("local-note.txt"), atomically: true, encoding: .utf8)
        let info = try await provider.inspectMigrationWorkingCopy(at: fixture.svnReader, requireClean: true)
        XCTAssertEqual(info.directory.standardizedFileURL, fixture.svnReader.standardizedFileURL)
        XCTAssertEqual(info.sourceURL, fixture.svnURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertFalse(info.repositoryUUID.isEmpty)
        XCTAssertEqual(info.baseRevision, "r2")

        try "managed modification\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await provider.inspectMigrationWorkingCopy(at: fixture.svnReader, requireClean: true)
            XCTFail("首次工作副本迁移必须拒绝已管修改")
        } catch let error as VersionControlError {
            guard case .invalidRepository = error else { return XCTFail("错误类型不正确：\(error)") }
        }

        // 补迁预检不把 Git 产生的本地差异当成 SVN update，也不修改 .svn。
        let supplement = try await provider.inspectMigrationWorkingCopy(at: fixture.svnReader, requireClean: false)
        XCTAssertEqual(supplement.sourceURL, info.sourceURL)
        XCTAssertEqual(supplement.repositoryUUID, info.repositoryUUID)
    }

    func testInspectWorkingCopyRejectsInternalDirectoryInsteadOfExpandingScope() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let subtree = fixture.svnWriter.appendingPathComponent("selected-subtree", isDirectory: true)
        try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
        try "owned by the root checkout\n".write(to: subtree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "selected-subtree"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add selected subtree"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["update"], directory: fixture.svnReader)

        let provider = SVNProvider(runner: fixture.runner)
        let nested = fixture.svnReader.appendingPathComponent("selected-subtree", isDirectory: true)
        do {
            _ = try await provider.inspectMigrationWorkingCopy(at: nested, requireClean: false)
            XCTFail("选择 SVN 工作副本内部目录不应静默迁移整个父工作副本")
        } catch let error as VersionControlError {
            guard case let .invalidRepository(message) = error else { return XCTFail("错误类型不正确：\(error)") }
            XCTAssertTrue(message.contains(fixture.svnReader.path))
        }

        // 单独检出的子目录本身是工作副本根，仍可作为迁移范围。
        let standalone = fixture.root.appendingPathComponent("selected-subtree-checkout", isDirectory: true)
        let standaloneURL = fixture.svnURL.appendingPathComponent("selected-subtree", isDirectory: true).absoluteString
        try await success(fixture, "svn", ["checkout", standaloneURL, standalone.path], directory: fixture.root)
        let isolated = try await provider.inspectMigrationWorkingCopy(at: standalone, requireClean: true)
        XCTAssertEqual(isolated.directory.standardizedFileURL, standalone.standardizedFileURL)

        // 根工作副本同样保持可用。
        let root = try await provider.inspectMigrationWorkingCopy(at: fixture.svnReader, requireClean: true)
        XCTAssertEqual(root.directory.standardizedFileURL, fixture.svnReader.standardizedFileURL)
    }

    func testWorkingCopyHistoryHonorsLocalBaseAndSupplementOnlyReadsLaterRevisions() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)
        let info = try await provider.inspectMigrationWorkingCopy(at: fixture.svnReader, requireClean: true)

        try "remote r3\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "remote r3"], directory: fixture.svnWriter)
        try "remote r4\n".write(to: fixture.svnWriter.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "remote r4"], directory: fixture.svnWriter)

        let initial = try await provider.planWorkingCopyHistory(
            from: RemoteRepositoryLocation(url: info.sourceURL), mode: .history,
            through: info.baseRevision, after: nil, progress: { _ in }
        )
        XCTAssertEqual(initial.anchor, "r2")
        XCTAssertFalse(initial.revisions.contains { $0.id == "r3" || $0.id == "r4" })

        let supplement = try await provider.planWorkingCopyHistory(
            from: RemoteRepositoryLocation(url: info.sourceURL), mode: .history,
            through: nil, after: info.baseRevision, progress: { _ in }
        )
        XCTAssertEqual(supplement.anchor, "r4")
        XCTAssertEqual(supplement.revisions.map(\.id), ["r3", "r4"])
        let none = try await provider.planWorkingCopyHistory(
            from: RemoteRepositoryLocation(url: info.sourceURL), mode: .history,
            through: "r4", after: "r4", progress: { _ in }
        )
        XCTAssertTrue(none.revisions.isEmpty)
    }

    func testHistoryPlanPaginatesMoreThanFiveHundredUsingOneFixedPeg() async throws {
        let capture = MigrationCommandCapture()
        let address = "file:///migration-fixture/trunk/module"
        let provider = SVNProvider(
            runner: CommandRunner(),
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, _, _ in
                await capture.append(arguments)
                if arguments.contains("info") {
                    return MigrationCommandCapture.result(xml: """
                    <?xml version="1.0"?><info><entry kind="dir" path="" revision="502"><url>\(address)</url></entry></info>
                    """)
                }
                guard let range = arguments.drop(while: { $0 != "-r" }).dropFirst().first else {
                    return CommandResult(data: Data(), errorData: Data("missing range".utf8), exitCode: 1)
                }
                switch range {
                case "502:1":
                    return MigrationCommandCapture.result(xml: MigrationCommandCapture.logXML(revisions: Array(stride(from: 502, through: 3, by: -1))))
                case "2:1":
                    return MigrationCommandCapture.result(xml: MigrationCommandCapture.logXML(revisions: [2]))
                default:
                    return CommandResult(data: Data(), errorData: Data("unexpected range \(range)".utf8), exitCode: 1)
                }
            }
        )

        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: address), mode: .history, progress: { _ in }
        )
        XCTAssertEqual(plan.anchor, "r502")
        XCTAssertTrue(plan.includeCopyHistory, "旧 API 必须保留跨复制祖先历史的原有语义")
        XCTAssertEqual(plan.revisions.count, 501)
        XCTAssertEqual(Set(plan.revisions.map(\.id)).count, 501)
        XCTAssertEqual(plan.revisions.first?.id, "r2")
        XCTAssertEqual(plan.revisions.last?.id, "r502")

        let logs = await capture.commands().filter { $0.contains("log") }
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs[0].contains("502:1"))
        XCTAssertTrue(logs[1].contains("2:1"), "第二页必须从首批最旧 r3 的前一条继续")
        XCTAssertTrue(logs.allSatisfy { $0.contains("\(address)@502") }, "续页不能重新解析移动的 HEAD")
        XCTAssertTrue(logs.allSatisfy { !$0.contains("-v") }, "迁移计划不读取无用的变更路径列表")
    }

    func testHistoryScopeStopsAtCopyWhenPlanningNewMigration() async throws {
        let capture = MigrationCommandCapture()
        let address = "file:///migration-fixture/trunk/module"
        let provider = SVNProvider(
            runner: CommandRunner(),
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, _, _ in
                await capture.append(arguments)
                if arguments.contains("info") {
                    return MigrationCommandCapture.result(xml: """
                    <?xml version="1.0"?><info><entry kind="dir" path="" revision="10"><url>\(address)</url></entry></info>
                    """)
                }
                guard let range = arguments.drop(while: { $0 != "-r" }).dropFirst().first,
                      range == "10:1" else {
                    return CommandResult(data: Data(), errorData: Data("unexpected range".utf8), exitCode: 1)
                }
                return MigrationCommandCapture.result(xml: MigrationCommandCapture.logXML(revisions: [10, 9]))
            }
        )

        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: address), mode: .history,
            includeCopyHistory: false, progress: { _ in }
        )

        XCTAssertFalse(plan.includeCopyHistory)
        let logs = await capture.commands().filter { $0.contains("log") }
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("--stop-on-copy"))
        XCTAssertTrue(logs[0].contains("\(address)@10"), "停止祖先追溯也必须保留固定 peg")
    }

    func testWorkingCopySupplementForcesCopyHistoryAndKeepsStrictLowerBound() async throws {
        let capture = MigrationCommandCapture()
        let address = "file:///migration-fixture/trunk/module"
        let provider = SVNProvider(
            runner: CommandRunner(),
            tlsFallback: SVNAutomaticTLSFallback(),
            commandExecutor: { arguments, _, _ in
                await capture.append(arguments)
                if arguments.contains("info") {
                    return MigrationCommandCapture.result(xml: """
                    <?xml version="1.0"?><info><entry kind="dir" path="" revision="10"><url>\(address)</url></entry></info>
                    """)
                }
                guard let range = arguments.drop(while: { $0 != "-r" }).dropFirst().first else {
                    return CommandResult(data: Data(), errorData: Data("missing range".utf8), exitCode: 1)
                }
                guard range == "10:8" else {
                    return CommandResult(data: Data(), errorData: Data("unexpected range \(range)".utf8), exitCode: 1)
                }
                return MigrationCommandCapture.result(xml: MigrationCommandCapture.logXML(revisions: [10, 9, 8]))
            }
        )

        let plan = try await provider.planWorkingCopyHistory(
            from: RemoteRepositoryLocation(url: address), mode: .history,
            through: "r10", after: "r7", includeCopyHistory: false, progress: { _ in }
        )

        XCTAssertTrue(plan.includeCopyHistory, "补迁必须跨越新的 copy/rename，不能按初次范围截断")
        XCTAssertEqual(plan.revisions.map(\.id), ["r8", "r9", "r10"], "补迁下界必须仍严格排除 r7")
        let logs = await capture.commands().filter { $0.contains("log") }
        XCTAssertEqual(logs.count, 1)
        XCTAssertFalse(logs[0].contains("--stop-on-copy"), "补迁即使请求仅当前路径，也必须取得 copy 点后的完整增量")
        XCTAssertTrue(logs[0].contains("10:8"))
        XCTAssertTrue(logs[0].contains("\(address)@10"), "停止祖先追溯也必须保留固定 peg")
    }

    func testHistoryPlanReadsPastLegacy150LimitOldestFirstAndKeepsNumericAnchor() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let directory = fixture.svnWriter.appendingPathComponent("migration-module", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("state.txt")
        try "0\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "migration-module"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "migration start"], directory: fixture.svnWriter)
        for value in 1...151 {
            try "\(value)\n".write(to: file, atomically: true, encoding: .utf8)
            try await success(fixture, "svn", ["commit", "-m", "migration \(value)"], directory: fixture.svnWriter)
        }

        let source = fixture.svnURL.appendingPathComponent("migration-module", isDirectory: true).absoluteString
        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: source), mode: .history, progress: { _ in }
        )

        XCTAssertEqual(plan.revisions.count, 152, "迁移历史不能沿用界面的 150 条默认上限")
        XCTAssertEqual(plan.revisions.first?.message, "migration start")
        XCTAssertEqual(plan.revisions.last?.message, "migration 151")
        XCTAssertEqual(plan.revisions, plan.revisions.sorted { lhs, rhs in
            Int(lhs.id.dropFirst())! < Int(rhs.id.dropFirst())!
        })
        XCTAssertTrue(plan.anchor.hasPrefix("r"))

        // 计划形成后源端继续提交；导出计划中的最后一个快照必须仍是固定锚点的内容。
        try "after-plan\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "after migration plan"], directory: fixture.svnWriter)
        let destination = fixture.root.appendingPathComponent("migration-history-export", isDirectory: true)
        try await provider.exportMigrationSnapshot(plan: plan, revision: try XCTUnwrap(plan.revisions.last), to: destination, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("state.txt"), encoding: .utf8), "151\n")
    }

    func testSnapshotPlanExportsExactlyOneFixedDirectoryRevision() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let directory = fixture.svnWriter.appendingPathComponent("snapshot-module", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("guide.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "snapshot-module"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "snapshot start"], directory: fixture.svnWriter)
        try "fixed\n".write(to: file, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "snapshot fixed"], directory: fixture.svnWriter)

        let source = fixture.svnURL.appendingPathComponent("snapshot-module", isDirectory: true).absoluteString
        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: source), mode: .snapshot, progress: { _ in }
        )
        XCTAssertEqual(plan.revisions.count, 1)
        XCTAssertEqual(plan.revisions.first?.id, plan.anchor)
        XCTAssertTrue(plan.revisions.first?.message.contains("SVN 快照 \(plan.anchor)") == true)
        XCTAssertTrue(plan.revisions.first?.message.contains("snapshot fixed") == true)

        // 源目录不变、仓库其他目录在计划后继续提交；快照仍要按计划中的 source anchor 导出。
        let unrelated = fixture.svnWriter.appendingPathComponent("unrelated-after-plan.txt")
        try "new remote head elsewhere\n".write(to: unrelated, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", "unrelated-after-plan.txt"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "unrelated commit after snapshot plan"], directory: fixture.svnWriter)
        let destination = fixture.root.appendingPathComponent("migration-snapshot-export", isDirectory: true)
        try await provider.exportMigrationSnapshot(plan: plan, revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("guide.txt"), encoding: .utf8), "fixed\n")
    }

    func testExportRejectsExistingDestinationBeforeWriting() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)
        let plan = try await provider.planMigration(
            from: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), mode: .snapshot, progress: { _ in }
        )
        let destination = fixture.root.appendingPathComponent("existing-export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try await provider.exportMigrationSnapshot(plan: plan, revision: try XCTUnwrap(plan.revisions.first), to: destination, progress: { _ in })
            XCTFail("已有迁移导出目录不应被覆盖")
        } catch let error as VersionControlError {
            guard case .invalidRepository = error else { return XCTFail("错误类型不正确：\(error)") }
        }
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 迁移测试。")
        }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ executable: String, _ arguments: [String], directory: URL) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
}

private actor MigrationCommandCapture {
    private var values: [[String]] = []

    func append(_ arguments: [String]) { values.append(arguments) }
    func commands() -> [[String]] { values }

    nonisolated static func result(xml: String) -> CommandResult {
        CommandResult(data: Data(xml.utf8), exitCode: 0)
    }

    nonisolated static func logXML(revisions: [Int]) -> String {
        let entries = revisions.map { revision in
            "<logentry revision=\"\(revision)\"><author>fixture</author><date>2026-10-12T00:00:00.000000Z</date><msg>revision \(revision)</msg></logentry>"
        }.joined()
        return "<?xml version=\"1.0\"?><log>\(entries)</log>"
    }
}
