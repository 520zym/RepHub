import Foundation
import Testing
import GitAdapter
import TestSupport
import ToolExecution
import VersionControlCore

@Suite("GitProvider 获取")
struct GitAcquisitionTests {
    @Test("从隔离的裸仓库克隆并识别工作副本")
    func clonesLocalBareRemote() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        // `git init --bare` 默认 HEAD 可能仍指向 master；让 clone 确实检出 fixture 的 main。
        _ = try requireSuccess(
            try await fixture.run(executable: "git", arguments: ["--git-dir", fixture.gitRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"]),
            tool: "git"
        )
        let destination = fixture.root.appendingPathComponent("acquired-git", isDirectory: true)
        let provider = GitProvider(runner: fixture.runner)
        let stages = StageCollector()

        try await provider.acquire(
            RemoteRepositoryLocation(url: fixture.gitRemote.absoluteURL.absoluteString),
            to: destination,
            progress: { update in await stages.append(update.message) }
        )

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.md").path))
        #expect(try await provider.detect(at: destination) != nil)
        #expect(await stages.values().contains("正在连接 Git 远端…"))
        #expect(await stages.values().contains("Git 工作副本已就绪。"))
    }

    @Test("不会覆盖已有目标目录")
    func refusesExistingDestination() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let destination = fixture.root.appendingPathComponent("already-exists", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let provider = GitProvider(runner: fixture.runner)
        await #expect(throws: VersionControlError.self) {
            try await provider.acquire(
                RemoteRepositoryLocation(url: fixture.gitRemote.path),
                to: destination,
                progress: { _ in }
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("空远端也会得到可识别的空工作副本")
    func clonesEmptyRemote() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let emptyRemote = fixture.root.appendingPathComponent("remotes/empty.git", isDirectory: true)
        _ = try requireSuccess(
            try await fixture.run(executable: "git", arguments: ["init", "--bare", emptyRemote.path]),
            tool: "git"
        )
        let destination = fixture.root.appendingPathComponent("empty-clone", isDirectory: true)
        let provider = GitProvider(runner: fixture.runner)

        try await provider.acquire(
            RemoteRepositoryLocation(url: emptyRemote.path),
            to: destination,
            progress: { _ in }
        )

        let binding = try #require(await provider.detect(at: destination))
        #expect(try await provider.history(in: binding, limit: 10, reference: nil).isEmpty)
    }

    @Test("拒绝带密码、控制字符和 remote helper 的地址")
    func refusesUnsafeRemoteLocations() async throws {
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let provider = GitProvider(runner: fixture.runner)
        let cases = [
            "https://user:password@example.invalid/repo.git",
            "ext::sh -c echo-unsafe",
            "https://example.invalid/repo.git\n--upload-pack=anything"
        ]

        for (index, remote) in cases.enumerated() {
            let destination = fixture.root.appendingPathComponent("invalid-\(index)", isDirectory: true)
            await #expect(throws: VersionControlError.self) {
                try await provider.acquire(
                    RemoteRepositoryLocation(url: remote),
                    to: destination,
                    progress: { _ in }
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

private actor StageCollector {
    private var recorded: [String] = []
    func append(_ value: String) { recorded.append(value) }
    func values() -> [String] { recorded }
}
