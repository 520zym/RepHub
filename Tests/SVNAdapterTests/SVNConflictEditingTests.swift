import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNConflictEditingTests: XCTestCase {
    func testReadsInfoXMLConflictFilesAndResolvesIsolatedTextConflict() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let reader = fixture.svnReader.appendingPathComponent("README.md")
        let writer = fixture.svnWriter.appendingPathComponent("README.md")
        try "reader local\n".write(to: reader, atomically: true, encoding: .utf8)
        try "writer remote\n".write(to: writer, atomically: true, encoding: .utf8)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["commit", "-m", "remote conflict"], directory: fixture.svnWriter), tool: "svn")
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnReader), tool: "svn")

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let conflict = try await provider.contentConflict(in: binding, path: "README.md")
        XCTAssertEqual(conflict.base, "initial fixture\n")
        XCTAssertEqual(conflict.local, "reader local\n")
        XCTAssertEqual(conflict.incoming, "writer remote\n")
        XCTAssertTrue(conflict.working.contains("<<<<<<<"))

        let result = try await provider.resolveContentConflict(
            .init(path: conflict.path, stateToken: conflict.stateToken, content: "kept both\n"), in: binding
        )
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(try String(contentsOf: reader, encoding: .utf8), "kept both\n")
        let context = try await provider.managementContext(in: binding)
        XCTAssertFalse(context.conflicts.contains { $0.path == "README.md" })
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 冲突编辑测试。")
        }
    }
}
