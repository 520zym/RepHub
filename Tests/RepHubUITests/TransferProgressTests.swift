import XCTest
@testable import RepHubUI
import VersionControlCore

@MainActor
final class TransferProgressTests: XCTestCase {
    func testRecordBufferKeepsRecentEntriesAndPreservesCumulativeCount() {
        let state = TransferProgressState()
        state.begin("正在下载")
        let records = (0...TransferProgressState.retainedRecordLimit).map {
            RepositoryProgressRecord(kind: .file, message: "写入文件 \($0)", path: "Sources/\($0).swift")
        }

        state.consume(RepositoryOperationProgress("正在下载", records: records))

        XCTAssertEqual(state.totalRecordCount, records.count)
        XCTAssertEqual(state.records.count, TransferProgressState.retainedRecordLimit)
        XCTAssertEqual(state.records.first?.path, "Sources/1.swift")
        XCTAssertEqual(state.records.last?.path, "Sources/\(TransferProgressState.retainedRecordLimit).swift")
    }

    func testNewPhaseClearsPreviousStagePercentage() {
        let state = TransferProgressState()
        state.begin("接收对象")
        state.consume(RepositoryOperationProgress("接收对象", fractionCompleted: 0.6))
        XCTAssertEqual(state.fractionCompleted, 0.6)

        state.consume(RepositoryOperationProgress("写入工作副本"))

        XCTAssertEqual(state.phase, "写入工作副本")
        XCTAssertNil(state.fractionCompleted)
    }

    func testNewAttemptClearsOldRecordsAndMarksActivity() {
        let state = TransferProgressState()
        state.begin("第一次")
        state.consume(RepositoryOperationProgress("第一次", records: [RepositoryProgressRecord(kind: .information, message: "旧记录")]))
        state.finish("第一次结束")

        state.begin("第二次")

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.phase, "第二次")
        XCTAssertNil(state.fractionCompleted)
        XCTAssertEqual(state.totalRecordCount, 0)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertNotNil(state.startedAt)
        XCTAssertNotNil(state.lastActivityAt)
    }
}
