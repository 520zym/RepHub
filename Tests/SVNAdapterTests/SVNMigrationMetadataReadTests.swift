import Foundation
import XCTest
@testable import SVNAdapter
import ToolExecution
import VersionControlCore

final class SVNMigrationMetadataReadTests: XCTestCase {
    func testTimeoutRetriesOnlyOnceAndReportsRevision() async throws {
        let attempts = MetadataAttempts(failures: 1)
        let messages = MetadataMessages()
        let result = try await SVNMigrationMetadataRead.run(revision: 153, progress: { await messages.append($0.message) }) {
            try await attempts.execute()
        }
        XCTAssertEqual(result.output, "ready")
        let count = await attempts.count
        let values = await messages.values
        XCTAssertEqual(count, 2)
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(values.first?.contains("r153") == true)
    }

    func testRepeatedTimeoutStopsAfterSecondAttempt() async throws {
        let attempts = MetadataAttempts(failures: 3)
        do {
            _ = try await SVNMigrationMetadataRead.run(revision: 153, progress: { _ in }) { try await attempts.execute() }
            XCTFail("重复超时应停止")
        } catch VersionControlError.timedOut { }
        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }

    func testOtherErrorsAreNotRetried() async throws {
        let attempts = MetadataAttempts(failures: 1, timeout: false)
        do {
            _ = try await SVNMigrationMetadataRead.run(revision: 153, progress: { _ in }) { try await attempts.execute() }
            XCTFail("非超时错误应直接返回")
        } catch VersionControlError.invalidRepository { }
        let count = await attempts.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationBetweenAttemptsDoesNotStartRetry() async throws {
        let attempts = MetadataAttempts(failures: 1)
        let task = Task {
            try await SVNMigrationMetadataRead.run(revision: 153, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }) { try await attempts.execute() }
        }
        do {
            _ = try await task.value
            XCTFail("取消后不得重试")
        } catch is CancellationError { }
        let count = await attempts.count
        XCTAssertEqual(count, 1)
    }
}

private actor MetadataAttempts {
    var count = 0
    let failures: Int
    let timeout: Bool
    init(failures: Int, timeout: Bool = true) { self.failures = failures; self.timeout = timeout }
    func execute() throws -> CommandResult {
        count += 1
        if count <= failures {
            if timeout { throw VersionControlError.timedOut("svn") }
            throw VersionControlError.invalidRepository("authentication failed")
        }
        return CommandResult(data: Data("ready".utf8), exitCode: 0)
    }
}

private actor MetadataMessages {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
