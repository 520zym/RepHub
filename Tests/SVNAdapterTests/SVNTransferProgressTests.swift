import XCTest
@testable import SVNAdapter
import VersionControlCore

final class SVNTransferProgressTests: XCTestCase {
    func testReporterPublishesOnlyObservedLocalFileBytesAsEstimatedSpeed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-SVNTransferProgress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x5A, count: 4_096).write(to: file)

        let sink = ProgressSink()
        let reporter = SVNTransferProgressReporter(root: root, operationName: "正在检出 SVN…") { event in
            await sink.append(event)
        }
        await reporter.receive(lines: ["A    payload.bin"])

        let latest = await sink.last()
        let event = try XCTUnwrap(latest)
        XCTAssertEqual(event.transferStatistics?.processedBytes, 4_096)
        XCTAssertEqual(event.transferStatistics?.isEstimated, true)
        XCTAssertNotNil(event.transferStatistics?.bytesPerSecond)
        XCTAssertTrue(event.detail?.contains("估算") == true)
    }

    func testReporterConfirmsDelayedFileButDoesNotFollowParentSymlink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-SVNTransferProgress-delayed-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-SVNTransferProgress-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 1_024).write(to: outside.appendingPathComponent("outside.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outside
        )

        let sink = ProgressSink()
        let reporter = SVNTransferProgressReporter(root: root, operationName: "正在检出 SVN…") { event in
            await sink.append(event)
        }
        await reporter.receive(lines: ["A    delayed.bin", "A    linked/outside.bin"])
        try Data(repeating: 0x5A, count: 2_048).write(to: root.appendingPathComponent("delayed.bin"))
        await reporter.finish()

        let latest = await sink.last()
        let event = try XCTUnwrap(latest)
        XCTAssertEqual(event.transferStatistics?.processedBytes, 2_048)
    }

    func testParsesStatusLinesWithChineseSpacesAndAtSign() {
        let root = URL(fileURLWithPath: "/tmp/RepHub 进度")
        let entry = SVNTransferProgressParser.entry(
            from: "A    /tmp/RepHub 进度/目录 空格@版本/说明 文件.txt",
            root: root
        )
        XCTAssertEqual(entry?.record.message, "已写入")
        XCTAssertEqual(entry?.record.path, "目录 空格@版本/说明 文件.txt")
        XCTAssertEqual(entry?.change.kind, .added)
    }

    func testDoesNotStripUnrelatedAbsolutePrefix() {
        let root = URL(fileURLWithPath: "/tmp/a")
        let entry = SVNTransferProgressParser.entry(from: "U    /tmp/ab/file.txt", root: root)
        XCTAssertEqual(entry?.record.path, "/tmp/ab/file.txt")
        XCTAssertEqual(entry?.record.message, "已更新")
    }

    func testParsesPropertyDeleteMergeAndConflictStatusColumns() {
        let root = URL(fileURLWithPath: "/tmp/work")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: " U   props.txt", root: root)?.record.message, "已更新")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: "D    gone.txt", root: root)?.record.message, "删除")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: "G    merged.txt", root: root)?.record.message, "合并")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: "C    conflict.txt", root: root)?.record.message, "发现冲突")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: " C   property-conflict.txt", root: root)?.record.message, "发现冲突")
    }

    func testIgnoresSummaryAndNonStatusLines() {
        let root = URL(fileURLWithPath: "/tmp/work")
        XCTAssertNil(SVNTransferProgressParser.entry(from: "Updating '.':", root: root))
        XCTAssertNil(SVNTransferProgressParser.entry(from: "Updated to revision 42.", root: root))
        XCTAssertNil(SVNTransferProgressParser.entry(from: "Checked out revision 42.", root: root))
    }
}

private actor ProgressSink {
    private var events: [RepositoryOperationProgress] = []
    func append(_ event: RepositoryOperationProgress) { events.append(event) }
    func last() -> RepositoryOperationProgress? { events.last }
}
