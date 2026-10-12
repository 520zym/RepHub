import Foundation
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNManagementAndSetupTests: XCTestCase {
    func testSetupRejectsExistingRemoteWithoutChangingSourceOrRepository() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("existing-target-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "original\n".write(to: source.appendingPathComponent("Guide.txt"), atomically: true, encoding: .utf8)
        let before = try await youngestRevision(in: fixture)

        let result = try await SVNProvider(runner: fixture.runner).initialize(
            RepositorySetupRequest(providerID: .svn, directory: source,
                                   remote: RemoteRepositoryLocation(url: fixture.svnURL.absoluteString), message: "must not import"),
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Guide.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".svn").path))
        let after = try await youngestRevision(in: fixture)
        XCTAssertEqual(after, before)
    }

    func testSetupRejectsMalformedRemoteAddressBeforeAnyWrite() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("malformed-address-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "keep local\n".write(to: source.appendingPathComponent("Guide.txt"), atomically: true, encoding: .utf8)
        let malformed = fixture.svnURL.absoluteString.replacingOccurrences(of: "file:", with: "file")
        let before = try await youngestRevision(in: fixture)

        let result = try await SVNProvider(runner: fixture.runner).initialize(
            RepositorySetupRequest(providerID: .svn, directory: source,
                                   remote: RemoteRepositoryLocation(url: malformed), message: "must not import"),
            progress: { _ in }
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.summary.contains("未开始导入"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Guide.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".svn").path))
        let after = try await youngestRevision(in: fixture)
        XCTAssertEqual(after, before)
    }

    func testSetupRejectsSymbolicLinkWithoutCreatingRemotePath() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("symlink-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "kept\n".write(to: source.appendingPathComponent("Guide.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("external-link").path, withDestinationPath: "/tmp")
        let imports = try await createImportsParent(in: fixture)
        let remote = imports + "/symlink-rejected"
        let before = try await youngestRevision(in: fixture)

        do {
            _ = try await SVNProvider(runner: fixture.runner).initialize(
                RepositorySetupRequest(providerID: .svn, directory: source,
                                       remote: RemoteRepositoryLocation(url: remote), message: "must not import"),
                progress: { _ in }
            )
            XCTFail("包含符号链接的目录不应导入")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Guide.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("external-link").path))
        let after = try await youngestRevision(in: fixture)
        XCTAssertEqual(after, before)
    }

    func testSetupKeepsSourceWhenItChangesAfterSnapshot() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("mutating-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let guide = source.appendingPathComponent("Guide.txt")
        try "before snapshot\n".write(to: guide, atomically: true, encoding: .utf8)
        let imports = try await createImportsParent(in: fixture)
        let remote = imports + "/source-changed"
        let provider = SVNProvider(runner: fixture.runner)
        let before = try await youngestRevision(in: fixture)
        let result = try await provider.initialize(
            RepositorySetupRequest(providerID: .svn, directory: source,
                                   remote: RemoteRepositoryLocation(url: remote), message: "import old snapshot"),
            progress: { event in
                if event.message == "正在导入到 SVN…" {
                    try? "changed after snapshot\n".write(to: guide, atomically: true, encoding: .utf8)
                }
            }
        )
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.backupDirectory)
        XCTAssertEqual(try String(contentsOf: guide, encoding: .utf8), "changed after snapshot\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".svn").path))
        let after = try await youngestRevision(in: fixture)
        XCTAssertEqual(after, before)
    }

    func testImportsUnmanagedFolderWithoutMetadataAndPublishesWorkingCopy() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("import-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "kept\n".write(to: source.appendingPathComponent("nested/Guide.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ignored".write(to: source.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        let imports = try await createImportsParent(in: fixture)
        let remote = imports + "/new-project"
        let provider = SVNProvider(runner: fixture.runner)
        let result = try await provider.initialize(
            RepositorySetupRequest(providerID: .svn, directory: source,
                                   remote: RemoteRepositoryLocation(url: remote), message: "import fixture"),
            progress: { _ in }
        )
        XCTAssertEqual(result.outcome, .succeeded, result.details)
        XCTAssertNotNil(result.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(".svn").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("nested/Guide.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.backupDirectory).appendingPathComponent(".git/config").path))
    }

    func testComparisonAndLocalManagementToken() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let writer = fixture.svnWriter.appendingPathComponent("README.md")
        try "remote r3\n".write(to: writer, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "remote comparison"], directory: fixture.svnWriter)
        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let comparison = try await provider.compare(in: binding, from: "r2", to: "r3")
        XCTAssertTrue(comparison.files.contains { $0.path == "README.md" && $0.kind == .modified })
        let patch = try await provider.comparisonDiff(in: binding, comparison: comparison, path: "README.md")
        XCTAssertTrue(patch.text.contains("remote r3"))

        let directory = fixture.svnWriter.appendingPathComponent("目录 @ 空格", isDirectory: true)
        let special = directory.appendingPathComponent("新增 @ 文件.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "special\n".write(to: special, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["add", directory.path + "@"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "add special path"], directory: fixture.svnWriter)
        let added = try await provider.compare(in: binding, from: "r3", to: "r4")
        XCTAssertTrue(added.files.contains { $0.path == "目录 @ 空格/新增 @ 文件.txt" && $0.kind == .added })
        let addedPatch = try await provider.comparisonDiff(in: binding, comparison: added, path: "目录 @ 空格/新增 @ 文件.txt")
        XCTAssertTrue(addedPatch.text.contains("+special"))
        try await success(fixture, "svn", ["propset", "rephub:directory", "yes", directory.path + "@"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "directory property"], directory: fixture.svnWriter)
        let directoryProperty = try await provider.compare(in: binding, from: "r4", to: "r5")
        XCTAssertTrue(directoryProperty.files.contains { $0.path == "目录 @ 空格" })
        try await success(fixture, "svn", ["delete", special.path + "@"], directory: fixture.svnWriter)
        try await success(fixture, "svn", ["commit", "-m", "delete special path"], directory: fixture.svnWriter)
        let deleted = try await provider.compare(in: binding, from: "r5", to: "r6")
        XCTAssertTrue(deleted.files.contains { $0.path == "目录 @ 空格/新增 @ 文件.txt" && $0.kind == .deleted })
        let deletedPatch = try await provider.comparisonDiff(in: binding, comparison: deleted, path: "目录 @ 空格/新增 @ 文件.txt")
        XCTAssertTrue(deletedPatch.text.contains("-special"))

        let before = try await provider.managementContext(in: binding)
        try "local edit\n".write(to: fixture.svnReader.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let after = try await provider.managementContext(in: binding)
        XCTAssertNotEqual(before.stateToken, after.stateToken)
    }

    func testMarksOnlyEditedTextConflictAsResolved() async throws {
        try requireSVN()
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let reader = fixture.svnReader.appendingPathComponent("README.md")
        let writer = fixture.svnWriter.appendingPathComponent("README.md")
        try "reader local\n".write(to: reader, atomically: true, encoding: .utf8)
        try "writer remote\n".write(to: writer, atomically: true, encoding: .utf8)
        try await success(fixture, "svn", ["commit", "-m", "remote conflicting edit"], directory: fixture.svnWriter)
        _ = try requireSuccess(try await fixture.run(executable: "svn", arguments: ["update"], directory: fixture.svnReader), tool: "svn")

        let provider = SVNProvider(runner: fixture.runner)
        let detected = try await provider.detect(at: fixture.svnReader)
        let binding = try XCTUnwrap(detected)
        let conflicted = try await provider.managementContext(in: binding)
        XCTAssertEqual(conflicted.conflicts.first?.path, "README.md")
        XCTAssertFalse(conflicted.conflicts.first?.canMarkResolved ?? true)

        try "resolved content\n".write(to: reader, atomically: true, encoding: .utf8)
        let ready = try await provider.managementContext(in: binding)
        XCTAssertTrue(ready.conflicts.first?.canMarkResolved ?? false)
        let result = try await provider.performManagement(
            RepositoryManagementRequest(action: .markResolved(paths: ["README.md"]), stateToken: ready.stateToken),
            in: binding, progress: { _ in }
        )
        XCTAssertEqual(result.outcome, .succeeded)
        let resolved = try await provider.managementContext(in: binding)
        XCTAssertTrue(resolved.conflicts.isEmpty)
    }

    private func requireSVN() throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else { throw XCTSkip("缺少 SVN 工具") }
    }

    private func success(_ fixture: LocalRepositoryFixture, _ executable: String, _ arguments: [String], directory: URL) async throws {
        _ = try requireSuccess(try await fixture.run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }

    private func youngestRevision(in fixture: LocalRepositoryFixture) async throws -> String {
        let result = try requireSuccess(
            try await fixture.run(executable: "svnlook", arguments: ["youngest", fixture.svnRepository.path]), tool: "svnlook"
        )
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createImportsParent(in fixture: LocalRepositoryFixture) async throws -> String {
        let root = fixture.svnRepository.absoluteURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let imports = root + "/imports"
        try await success(fixture, "svn", ["mkdir", "-m", "create imports parent", imports], directory: fixture.root)
        return imports
    }
}
