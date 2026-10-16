import CryptoKit
import Foundation
import GitAdapter
import TestSupport
import Testing
import ToolExecution
import VersionControlCore

@Suite("Git 迁移对象复用")
struct GitVerifiedMigrationSessionTests {
    private let author = MigrationAuthor(name: "Fixture", email: "fixture@example.test")

    @Test("复用对象仍正确处理目录、文件、链接互换及执行位")
    func verifiesEveryTreeAcrossTypeChanges() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("verified-source")
        let repository = fixture.root.appendingPathComponent("verified-target")
        let manager = FileManager.default
        try manager.createDirectory(at: source.appendingPathComponent("changed"), withIntermediateDirectories: true)
        for index in 0..<80 {
            try Data(repeating: UInt8(index), count: 8192).write(to: source.appendingPathComponent("stable-\(index).bin"))
        }
        try Data("first".utf8).write(to: source.appendingPathComponent("changed/child.txt"))
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.initializeMigration(at: repository, branch: "main")
        let session = try await provider.makeVerifiedMigrationSession(at: repository)
        var expected: [[MigrationFileEntry]] = []
        var tips: [String] = []
        for index in 1...4 {
            if index > 1 { try manager.removeItem(at: source.appendingPathComponent("changed")) }
            if index == 2 { try Data("directory became a file".utf8).write(to: source.appendingPathComponent("changed")) }
            if index == 3 {
                try manager.createSymbolicLink(atPath: source.appendingPathComponent("changed").path, withDestinationPath: "stable-0.bin")
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("stable-1.bin").path)
            }
            if index == 4 {
                try manager.createDirectory(at: source.appendingPathComponent("changed"), withIntermediateDirectories: false)
                try Data("file restored".utf8).write(to: source.appendingPathComponent("changed/next.txt"))
                try manager.removeItem(at: source.appendingPathComponent("stable-2.bin"))
            }
            let manifest = try scan(source)
            expected.append(manifest.filter { $0.kind != .directory })
            tips.append(try await session.appendVerifiedSnapshot(from: source, files: manifest,
                revision: revision(index), author: author, progress: { _ in }))
            try await provider.verifyMigration(at: repository, expectedTip: tips[index - 1], branch: "main")
            let parents = try requireSuccess(try await fixture.run(
                executable: "git", arguments: ["show", "-s", "--format=%P", tips[index - 1]], directory: repository
            ), tool: "git").output.split(whereSeparator: \.isWhitespace).map(String.init)
            let expectedParents: [String] = index == 1 ? [] : [tips[index - 2]]
            #expect(parents == expectedParents)
        }
        for (index, tip) in tips.enumerated() {
            let exported = fixture.root.appendingPathComponent("verified-export-\(index)")
            try await provider.exportMigrationTree(at: repository, revision: tip, to: exported)
            #expect(try scan(exported).filter { $0.kind != .directory } == expected[index])
        }
        // 新会话从已有干净检查点继续，不能复用内存中未重新建立的对象映射。
        let resumed = try await provider.makeVerifiedMigrationSession(at: repository)
        let tip = try await resumed.appendVerifiedSnapshot(from: source, files: scan(source),
            revision: revision(5), author: author, progress: { _ in })
        try await provider.verifyMigration(at: repository, expectedTip: tip, branch: "main")
        // 即使外部追加的是空提交、工作区仍干净，也不能在未知父节点上继续本次会话。
        _ = try requireSuccess(try await fixture.run(executable: "git", arguments: [
            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
            "commit", "--allow-empty", "-m", "unexpected external commit"
        ], directory: repository), tool: "git")
        await #expect(throws: (any Error).self) {
            _ = try await resumed.appendVerifiedSnapshot(from: source, files: scan(source),
                revision: revision(6), author: author, progress: { _ in })
        }
    }

    @Test("伪造内容摘要或遗漏文件时不接受快照，失败会话不能继续")
    func rejectsFalseManifestAndInvalidatesSession() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("false-manifest-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("real bytes".utf8).write(to: source.appendingPathComponent("file.txt"))
        let real = try scan(source)
        for (index, bad) in [
            [MigrationFileEntry(path: "file.txt", kind: .file, digest: String(repeating: "0", count: 64), size: 10)],
            [],
            [MigrationFileEntry(path: "../escape", kind: .file, digest: real[0].digest, size: real[0].size)]
        ].enumerated() {
            let provider = GitMigrationTargetProvider(runner: fixture.runner)
            let repository = fixture.root.appendingPathComponent("rejected-target-\(index)")
            try await provider.initializeMigration(at: repository, branch: "main")
            let session = try await provider.makeVerifiedMigrationSession(at: repository)
            await #expect(throws: (any Error).self) {
                _ = try await session.appendVerifiedSnapshot(from: source, files: bad,
                    revision: revision(1), author: author, progress: { _ in })
            }
            await #expect(throws: (any Error).self) {
                _ = try await session.appendVerifiedSnapshot(from: source, files: real,
                    revision: revision(2), author: author, progress: { _ in })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape").path))
    }

    @Test("已核对会话流式校验 256 MiB 文件并可导出")
    func verifiesAndExportsLargeBlobBeyondInMemoryLimit() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let source = fixture.root.appendingPathComponent("verified-large-source")
        let repository = fixture.root.appendingPathComponent("verified-large-target")
        let exported = fixture.root.appendingPathComponent("verified-large-export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let block = Data(repeating: 0x3C, count: 1024 * 1024)
        let path = source.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        let writer = try FileHandle(forWritingTo: path)
        var expectedHash = SHA256()
        for _ in 0..<256 { try writer.write(contentsOf: block); expectedHash.update(data: block) }
        try writer.close()
        let digest = expectedHash.finalize().map { String(format: "%02x", $0) }.joined()
        let size: UInt64 = 256 * 1024 * 1024
        let manifest = [MigrationFileEntry(path: "large.bin", kind: .file, digest: digest, size: size)]
        let provider = GitMigrationTargetProvider(runner: fixture.runner)
        try await provider.initializeMigration(at: repository, branch: "main")
        let session = try await provider.makeVerifiedMigrationSession(at: repository)
        let tip = try await session.appendVerifiedSnapshot(from: source, files: manifest,
                                                           revision: revision(1), author: author, progress: { _ in })
        try await provider.exportMigrationTree(at: repository, revision: tip, to: exported)
        let reader = try FileHandle(forReadingFrom: exported.appendingPathComponent("large.bin"))
        defer { try? reader.close() }
        var actualHash = SHA256()
        var actualSize: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            actualHash.update(data: chunk); actualSize += UInt64(chunk.count)
        }
        #expect(actualSize == size)
        #expect(actualHash.finalize().map { String(format: "%02x", $0) }.joined() == digest)
    }

    private func revision(_ number: Int) -> MigrationRevision {
        MigrationRevision(id: "r\(number)", author: "fixture", date: Date(timeIntervalSince1970: Double(1_700_000_000 + number)), message: "revision \(number)")
    }

    private func scan(_ root: URL) throws -> [MigrationFileEntry] {
        let manager = FileManager.default
        var result: [MigrationFileEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + child.lastPathComponent
                let attributes = try manager.attributesOfItem(atPath: child.path)
                let kind = attributes[.type] as? FileAttributeType
                if kind == .typeDirectory {
                    result.append(.init(path: path, kind: .directory, digest: "", size: 0))
                    try visit(child, prefix: path + "/")
                } else {
                    let link = kind == .typeSymbolicLink
                    let data = try link ? Data(manager.destinationOfSymbolicLink(atPath: child.path).utf8) : Data(contentsOf: child)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let executable = !link && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
                    result.append(.init(path: path, kind: link ? .symbolicLink : .file, digest: digest,
                                        size: UInt64(data.count), executable: executable))
                }
            }
        }
        try visit(root, prefix: "")
        return result.sorted { $0.path < $1.path }
    }
}
