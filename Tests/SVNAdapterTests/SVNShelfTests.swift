import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNShelfTests: XCTestCase {
    func testLocalTextSnapshotCanCleanAndRestore() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else { throw XCTSkip("未安装 svn 或 svnadmin") }
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        try "local change\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "local note\n".write(to: fixture.svnReader.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let provider = SVNProvider(runner: fixture.runner, shelfStorageDirectory: fixture.root.appendingPathComponent("shelves"))
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let preview = try await provider.shelfPreview(in: binding, includeUntracked: true)
        XCTAssertEqual(Set(preview.files.map(\.path)), Set(["README.md", "note.txt"]))
        let record = try await provider.createShelf(in: binding, name: "fixture", includeUntracked: true,
                                                    mode: .saveAndClean, expectedStateToken: preview.stateToken)
        let cleanStatus = try await provider.status(in: binding)
        XCTAssertTrue(cleanStatus.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.svnReader.appendingPathComponent("note.txt").path))
        _ = try await provider.restoreShelf(in: binding, record: record)
        let restored = try await provider.status(in: binding)
        XCTAssertTrue(restored.contains { $0.path == "README.md" && $0.kind == .modified })
        XCTAssertTrue(restored.contains { $0.path == "note.txt" && $0.kind == .untracked })
        try await provider.deleteShelf(in: binding, record: record)
    }
}
