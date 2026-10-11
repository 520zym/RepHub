import XCTest
@testable import SVNAdapter
import VersionControlCore

final class SVNTransferProgressTests: XCTestCase {
    func testParsesStatusLinesWithChineseSpacesAndAtSign() {
        let root = URL(fileURLWithPath: "/tmp/RepHub 进度")
        let entry = SVNTransferProgressParser.entry(
            from: "A    /tmp/RepHub 进度/目录 空格@版本/说明 文件.txt",
            root: root
        )
        XCTAssertEqual(entry?.record.message, "添加")
        XCTAssertEqual(entry?.record.path, "目录 空格@版本/说明 文件.txt")
        XCTAssertEqual(entry?.change.kind, .added)
    }

    func testDoesNotStripUnrelatedAbsolutePrefix() {
        let root = URL(fileURLWithPath: "/tmp/a")
        let entry = SVNTransferProgressParser.entry(from: "U    /tmp/ab/file.txt", root: root)
        XCTAssertEqual(entry?.record.path, "/tmp/ab/file.txt")
        XCTAssertEqual(entry?.record.message, "更新")
    }

    func testParsesPropertyDeleteMergeAndConflictStatusColumns() {
        let root = URL(fileURLWithPath: "/tmp/work")
        XCTAssertEqual(SVNTransferProgressParser.entry(from: " U   props.txt", root: root)?.record.message, "更新")
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
