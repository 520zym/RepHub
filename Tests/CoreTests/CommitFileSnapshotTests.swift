import Foundation
import Testing
import ToolExecution
import VersionControlCore

@Suite("提交文件快照")
struct CommitFileSnapshotTests {
    @Test("内容和权限都会影响指纹")
    func contentAndPermissionsAffectFingerprint() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/file.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: file)
        let original = try CommitFileSnapshot.fingerprint(root: root, path: "Sources/file.txt")
        try Data("two".utf8).write(to: file)
        let changed = try CommitFileSnapshot.fingerprint(root: root, path: "Sources/file.txt")
        #expect(original != changed)
        try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: file.path)
        let permissionChanged = try CommitFileSnapshot.fingerprint(root: root, path: "Sources/file.txt")
        #expect(changed != permissionChanged)
    }

    @Test("最终符号链接只对链接目标做指纹")
    func finalSymbolicLinkHashesTarget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try Data("original target contents".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "target.txt")
        let before = try CommitFileSnapshot.fingerprint(root: root, path: "link")
        try Data("changed target contents".utf8).write(to: target)
        #expect(try CommitFileSnapshot.fingerprint(root: root, path: "link") == before)
    }

    @Test("父目录符号链接、元数据与越界路径被拒绝，缺失文件保持可复核")
    func rejectsUnsafePathsAndRepresentsMissingFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("actual"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "actual")
        #expect(throws: VersionControlError.self) {
            _ = try CommitFileSnapshot.fingerprint(root: root, path: "alias/file.txt")
        }
        for invalid in [".git/config", ".svn/entries", "../outside", "a/../b", "/absolute", "a\u{0000}b"] {
            #expect(throws: VersionControlError.self) {
                _ = try CommitFileSnapshot.validatedURL(root: root, path: invalid)
            }
        }
        #expect(try CommitFileSnapshot.fingerprint(root: root, path: "gone.txt") == "missing")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-CommitSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
