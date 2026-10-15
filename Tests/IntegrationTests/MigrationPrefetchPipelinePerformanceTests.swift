import Foundation
import Testing
@testable import RepositoryApplication
import SVNAdapter
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("迁移预取本地性能基准")
struct MigrationPrefetchPipelinePerformanceTests {
    @Test("同一已核对 Git 路径比较串行与单页预取，并记录原始阶段时间")
    func comparesSerialAndOnePagePrefetchOnLocalSVNFixture() async throws {
        try requireTools()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try await seedFixture(fixture)

        let location = RemoteRepositoryLocation(url: fixture.svnURL.appendingPathComponent("pipeline-module", isDirectory: true).absoluteString)
        let source = SVNProvider(runner: fixture.runner)
        let sourcePlan = try await source.planMigration(from: location, mode: .history, includeCopyHistory: true, progress: { _ in })
        #expect(sourcePlan.revisions.count == 4)

        let serial = try await runMigration(fixture: fixture, source: source, sourcePlan: sourcePlan, prefetchEnabled: false, label: "serial")
        let prefetched = try await runMigration(fixture: fixture, source: source, sourcePlan: sourcePlan, prefetchEnabled: true, label: "prefetch")
        #expect(serial.signature == prefetched.signature)
        #expect(serial.commitCount == sourcePlan.revisions.count)
        #expect(prefetched.commitCount == sourcePlan.revisions.count)

        let report: [String: Any] = [
            "scope": "本地 file:// SVN 到已核对 Git 初迁，含来源快照、来源扫描、Git 写入核对和末次导出核对；不代表真实网络服务器耗时。",
            "fixture": ["revisions": sourcePlan.revisions.count, "staticSmallFiles": 320],
            "serial": serial.report,
            "prefetch": prefetched.report,
            "notes": ["同一 verified Git 路径仅切换 prefetchEnabled；单次对照先串行后预取。", "phaseEvents 是进度回调时序，不等同于精确 CPU 或网络耗时。", "无速度阈值：本地磁盘争用时预取可更慢。"]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-migration-prefetch-benchmark.json")
        try data.write(to: output, options: .atomic)
        print("Migration prefetch benchmark JSON: \(output.path)\n\(String(decoding: data, as: UTF8.self))")
    }

    private func runMigration(fixture: LocalRepositoryFixture, source: SVNProvider, sourcePlan: MigrationSourcePlan,
                              prefetchEnabled: Bool, label: String) async throws -> BenchmarkRun {
        let remote = fixture.root.appendingPathComponent("remotes/\(label).git", isDirectory: true)
        try await command("git", ["init", "--bare", remote.path], fixture: fixture)
        let destination = fixture.root.appendingPathComponent("\(label)-preview", isDirectory: true)
        let authors = Dictionary(sourcePlan.revisions.reduce(into: [(String, MigrationAuthor)]()) { pairs, revision in
            if !pairs.contains(where: { $0.0 == revision.author }) {
                pairs.append((revision.author, MigrationAuthor(name: revision.author, email: "\(revision.author)@example.test")))
            }
        }, uniquingKeysWith: { first, _ in first })
        let plan = MigrationPlan(source: sourcePlan, targetProviderID: .git, remoteURL: remote.absoluteURL.absoluteString,
                                 branch: "main", destination: destination, authors: authors)
        let recorder = PhaseRecorder()
        let service = RepositoryMigrationService(sources: [source], targets: [GitMigrationTargetProvider(runner: fixture.runner)], prefetchEnabled: prefetchEnabled)
        let start = ProcessInfo.processInfo.systemUptime
        let preview = try await service.prepare(plan) { update in await recorder.append(update) }
        let wall = ProcessInfo.processInfo.systemUptime - start
        let commits = try await gitCommitCount(preview.repository, fixture: fixture)

        let auditCache = fixture.root.appendingPathComponent("\(label)-audit-cache", isDirectory: true)
        let auditSnapshot = fixture.root.appendingPathComponent("\(label)-audit-snapshot", isDirectory: true)
        let session = try await source.makeMigrationSnapshotSession(plan: sourcePlan, in: auditCache)
        try await session.exportSnapshot(revision: try #require(sourcePlan.revisions.last), to: auditSnapshot, progress: { _ in })
        let signature = try treeSignature(auditSnapshot)
        #expect(!signature.isEmpty)
        #expect(try treeSignature(preview.repository) == signature)
        let phaseEvents = await recorder.snapshot()
        return BenchmarkRun(signature: signature, commitCount: commits, report: [
            "wallSeconds": wall,
            "commitCount": commits,
            "phaseEvents": phaseEvents.map { ["time": $0.time, "message": $0.message, "detail": $0.detail, "revision": $0.revision] as [String: Any] }
        ])
    }

    private func seedFixture(_ fixture: LocalRepositoryFixture) async throws {
        let module = fixture.svnWriter.appendingPathComponent("pipeline-module", isDirectory: true)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        for index in 0 ..< 320 {
            let name = String(format: "static-%03d.txt", index)
            try String(repeating: "fixture \(index) ", count: 8).write(to: module.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await command("svn", ["add", "pipeline-module"], directory: fixture.svnWriter, fixture: fixture)
        try await commit("pipeline create", fixture: fixture)
        for index in 0 ..< 8 { try "changed-r2-\(index)".write(to: module.appendingPathComponent(String(format: "static-%03d.txt", index)), atomically: true, encoding: .utf8) }
        try await commit("pipeline modify", fixture: fixture)
        try await command("svn", ["delete", "pipeline-module/static-008.txt", "pipeline-module/static-009.txt", "pipeline-module/static-010.txt", "pipeline-module/static-011.txt"], directory: fixture.svnWriter, fixture: fixture)
        try await commit("pipeline delete", fixture: fixture)
        try "final".write(to: module.appendingPathComponent("final.txt"), atomically: true, encoding: .utf8)
        try await command("svn", ["add", "pipeline-module/final.txt"], directory: fixture.svnWriter, fixture: fixture)
        try await commit("pipeline final", fixture: fixture)
    }

    private func treeSignature(_ root: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if child.lastPathComponent == ".git" || child.lastPathComponent == ".svn" { continue }
                let path = prefix + child.lastPathComponent
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: try visit(child, prefix: path + "/")
                case .typeSymbolicLink: entries["l:\(path)"] = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                case .typeRegular:
                    entries["f:\(path)"] = try Data(contentsOf: child).base64EncodedString()
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    entries["x:\(path)"] = mode & 0o111 == 0 ? "0" : "1"
                default: throw VersionControlError.unsupported("unsupported benchmark fixture entry")
                }
            }
        }
        try visit(root, prefix: "")
        return entries
    }

    private func command(_ executable: String, _ arguments: [String], directory: URL? = nil, fixture: LocalRepositoryFixture) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }
    private func commit(_ message: String, fixture: LocalRepositoryFixture) async throws { try await command("svn", ["commit", "--username", "fixture", "-m", message], directory: fixture.svnWriter, fixture: fixture) }
    private func gitCommitCount(_ repository: URL, fixture: LocalRepositoryFixture) async throws -> Int {
        let output = try requireSuccess(try await fixture.run(executable: "git", arguments: ["rev-list", "--count", "HEAD"], directory: repository), tool: "git").output
        return try #require(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func requireTools() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil, ToolLocator.find("git") != nil else { throw BenchmarkError.toolsUnavailable }
    }

    private struct BenchmarkRun { let signature: [String: String]; let commitCount: Int; let report: [String: Any] }
    private enum BenchmarkError: Error { case toolsUnavailable }
}

private struct PhaseEvent: Sendable {
    let time: Double
    let message: String
    let detail: String
    let revision: String
}

private actor PhaseRecorder {
    private var events: [PhaseEvent] = []
    func append(_ update: RepositoryOperationProgress) {
        events.append(PhaseEvent(time: ProcessInfo.processInfo.systemUptime, message: update.message,
                                 detail: update.detail ?? "", revision: update.migrationProgress?.currentRevision ?? ""))
    }
    func snapshot() -> [PhaseEvent] { events }
}
