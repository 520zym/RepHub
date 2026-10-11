import Foundation
import XCTest
@testable import SVNAdapter
import ToolExecution
import VersionControlCore

final class SVNProviderTests: XCTestCase {
    func testReadsLocalWorkingCopyThroughSVNCLI() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过本地工作副本读取测试。")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepHub-SVNProviderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let seed = temporary.appendingPathComponent("seed", isDirectory: true)
        let trunk = seed.appendingPathComponent("trunk", isDirectory: true)
        let checkout = temporary.appendingPathComponent("checkout", isDirectory: true)
        let otherCheckout = temporary.appendingPathComponent("other-checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: trunk, withIntermediateDirectories: true)
        try "one\n".write(to: trunk.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "delete me\n".write(to: trunk.appendingPathComponent("DELETE-ME.txt"), atomically: true, encoding: .utf8)
        try "property only\n".write(to: trunk.appendingPathComponent("PROP-ONLY.txt"), atomically: true, encoding: .utf8)
        try "safe\n".write(to: trunk.appendingPathComponent("-option@file.txt"), atomically: true, encoding: .utf8)
        try "space\n".write(to: trunk.appendingPathComponent("space name.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: seed.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)

        try await command("svnadmin", ["create", repository.path])
        let repositoryURL = repository.absoluteURL.absoluteString
        try await command("svn", ["import", seed.path, repositoryURL, "-m", "initial"])
        let trunkURL = repositoryURL + "/trunk"
        try await command("svn", ["checkout", trunkURL, checkout.path])
        try await command("svn", ["checkout", trunkURL, otherCheckout.path])
        try "two\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await command("svn", ["propset", "rephub:test", "value", checkout.appendingPathComponent("README.md").path])
        try await command("svn", ["propset", "rephub:test", "value", checkout.appendingPathComponent("PROP-ONLY.txt").path])
        try "untracked\n".write(to: checkout.appendingPathComponent("@NEW.txt"), atomically: true, encoding: .utf8)
        // 需先由 SVN 调度删除，远端再修改同一节点才会形成 tree conflict；仅删除物理文件只会是 missing。
        try await command("svn", ["delete", checkout.appendingPathComponent("DELETE-ME.txt").path])

        let provider = SVNProvider()
        let detectedBinding = try await provider.detect(at: checkout)
        let binding = try XCTUnwrap(detectedBinding)
        XCTAssertEqual(binding.providerID, .svn)
        XCTAssertEqual(binding.root.standardizedFileURL, checkout.standardizedFileURL)

        let beforeUpdate = try await provider.status(in: binding)
        XCTAssertTrue(beforeUpdate.contains { $0.path == "README.md" && $0.kind == .modified })
        XCTAssertTrue(beforeUpdate.contains { $0.path == "PROP-ONLY.txt" && $0.kind == .modified })
        XCTAssertTrue(beforeUpdate.contains { $0.path == "@NEW.txt" && $0.kind == .untracked })
        XCTAssertTrue(beforeUpdate.contains { $0.path == "DELETE-ME.txt" && $0.kind == .deleted })

        let localPatch = try await provider.diff(in: binding, path: "README.md", revision: nil)
        XCTAssertTrue(localPatch.text.contains("Index: README.md"))
        XCTAssertTrue(localPatch.text.contains("-one"))
        XCTAssertTrue(localPatch.text.contains("+two"))
        let untrackedPatch = try await provider.diff(in: binding, path: "@NEW.txt", revision: nil)
        XCTAssertTrue(untrackedPatch.text.contains("未跟踪文件"))
        XCTAssertTrue(untrackedPatch.text.contains("@NEW.txt"))
        let allLocalPatch = try await provider.diff(in: binding, path: nil, revision: nil)
        XCTAssertTrue(allLocalPatch.text.contains("未跟踪文件"))
        XCTAssertTrue(allLocalPatch.text.contains("@NEW.txt"))
        let protectedPathPatch = try await provider.diff(in: binding, path: "-option@file.txt", revision: "r1")
        XCTAssertTrue(protectedPathPatch.text.contains("-option@file.txt"))

        try "three\n".write(to: otherCheckout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "remote delete content\n".write(to: otherCheckout.appendingPathComponent("DELETE-ME.txt"), atomically: true, encoding: .utf8)
        try await command("svn", ["commit", otherCheckout.path, "-m", "remote change"])
        try await command("svn", ["update", checkout.path])

        let changes = try await provider.status(in: binding)
        XCTAssertTrue(changes.contains { $0.path == "@NEW.txt" && $0.kind == .untracked })
        XCTAssertTrue(changes.contains { $0.path == "DELETE-ME.txt" && $0.kind == .conflicted })
        XCTAssertTrue(changes.contains { $0.path == "README.md" && $0.kind == .conflicted })

        let history = try await provider.history(in: binding, limit: 2, reference: nil)
        let revision = try XCTUnwrap(history.last)
        XCTAssertEqual(revision.id, "r1")
        XCTAssertEqual(revision.message, "initial")
        XCTAssertNotEqual(revision.date, .distantPast)
        let referencedHistory = try await provider.history(in: binding, limit: 1, reference: revision.id)
        XCTAssertEqual(referencedHistory.first?.id, "r1")

        let files = try await provider.changedFiles(in: binding, revision: revision.id)
        XCTAssertTrue(files.contains { $0.path == "README.md" && $0.kind == .added })
        XCTAssertTrue(files.contains { $0.path == "space name.txt" && $0.kind == .added })
        XCTAssertFalse(files.contains { $0.path == "outside.txt" })

    }

    private func command(_ executable: String, _ arguments: [String]) async throws {
        let result = try await CommandRunner().run(executable: executable, arguments: arguments, directory: nil)
        _ = try requireSuccess(result, tool: executable)
    }
}
