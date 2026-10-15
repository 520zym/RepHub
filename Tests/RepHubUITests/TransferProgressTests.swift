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

    func testNewPhaseClearsPreviousTransferStatisticsButKeepsMigrationProgress() {
        let state = TransferProgressState()
        state.begin("导出 SVN 快照")
        let statistics = RepositoryTransferStatistics(processedBytes: 2_048, elapsed: 2, isEstimated: true)
        let migration = RepositoryMigrationProgress(completedRevisions: 4, totalRevisions: 12, currentRevision: "r16072")
        state.consume(RepositoryOperationProgress("导出 SVN 快照", transferStatistics: statistics,
                                                  migrationProgress: migration))

        state.consume(RepositoryOperationProgress("写入 Git 快照"))

        XCTAssertNil(state.transferStatistics)
        XCTAssertEqual(state.migrationProgress, migration)
    }

    func testMigrationProgressSurvivesUpdatesWithoutMigrationPayloadAndClearsAtFinish() {
        let state = TransferProgressState()
        state.begin("正在转换")
        let migration = RepositoryMigrationProgress(completedRevisions: 1, totalRevisions: 2, currentRevision: "r2")
        state.consume(RepositoryOperationProgress("导出快照", migrationProgress: migration))
        state.consume(RepositoryOperationProgress("写入 Git 快照", detail: "正在建立对象"))
        XCTAssertEqual(state.migrationProgress, migration)

        state.finish("已完成")
        XCTAssertNil(state.migrationProgress)
    }

    func testMigrationProgressNormalizesInvalidCounts() {
        let progress = RepositoryMigrationProgress(completedRevisions: 9, totalRevisions: 3, currentRevision: "  r12  ")
        XCTAssertEqual(progress.completedRevisions, 3)
        XCTAssertEqual(progress.totalRevisions, 3)
        XCTAssertEqual(progress.currentRevision, "r12")
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

    func testStoresAndClearsTransferStatistics() {
        let state = TransferProgressState()
        state.begin("正在检出")
        let statistics = RepositoryTransferStatistics(processedBytes: 2_048, elapsed: 2, isEstimated: true)
        let migration = RepositoryMigrationProgress(completedRevisions: 2, totalRevisions: 3)
        state.consume(RepositoryOperationProgress("正在检出", transferStatistics: statistics, migrationProgress: migration))
        XCTAssertEqual(state.transferStatistics?.processedBytes, 2_048)
        XCTAssertEqual(state.transferStatistics?.isEstimated, true)
        XCTAssertEqual(state.migrationProgress, migration)

        state.clear()
        XCTAssertNil(state.transferStatistics)
        XCTAssertNil(state.migrationProgress)
    }
}
