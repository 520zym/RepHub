import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNInspectionTests: XCTestCase {
    func testBlameReadsFixedCommittedRevision() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)

        let result = try await provider.blame(in: binding, path: "README.md", reference: "r2")

        XCTAssertEqual(result.reference, "r2")
        XCTAssertEqual(result.lines.map(\.content), ["initial fixture"])
        XCTAssertEqual(result.lines.first?.revision.id, "r2")
    }

    func testUnversionedFileCannotBeBlamed() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "local\n".write(to: fixture.svnReader.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        do {
            _ = try await provider.blame(in: binding, path: "untracked.txt", reference: nil)
            XCTFail("未跟踪 SVN 文件不应返回追溯记录")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未受 SVN 管理"))
        }
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 逐行追溯测试。")
        }
    }
}
