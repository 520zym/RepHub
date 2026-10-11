import Foundation
import ToolExecution
import VersionControlCore

/// 仅供测试使用的本地 Git/SVN 设施。
/// 所有远端、工作副本和工具配置均位于 `root`，不会读取或写入用户仓库。
public final class LocalRepositoryFixture: @unchecked Sendable {
    public let root: URL
    public let home: URL
    public let runner: CommandRunner
    public let gitRemote: URL
    public let gitWriter: URL
    public let gitReader: URL
    public let svnRepository: URL
    public let svnURL: URL
    public let svnWriter: URL
    public let svnReader: URL
    public let dualWorkingCopy: URL

    private let fileManager: FileManager

    private init(root: URL, fileManager: FileManager) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        home = root.appendingPathComponent("home", isDirectory: true)
        runner = CommandRunner(isolatedHome: home)
        gitRemote = root.appendingPathComponent("remotes/git-origin.git", isDirectory: true)
        gitWriter = root.appendingPathComponent("git-writer", isDirectory: true)
        gitReader = root.appendingPathComponent("git-reader", isDirectory: true)
        svnRepository = root.appendingPathComponent("remotes/svn-repository", isDirectory: true)
        svnURL = root.appendingPathComponent("remotes/svn-repository/trunk", isDirectory: true)
        svnWriter = root.appendingPathComponent("svn-writer", isDirectory: true)
        svnReader = root.appendingPathComponent("svn-reader", isDirectory: true)
        dualWorkingCopy = root.appendingPathComponent("dual-working-copy", isDirectory: true)
    }

    public static func create(root explicitRoot: URL? = nil, fileManager: FileManager = .default) async throws -> LocalRepositoryFixture {
        let root: URL
        if let explicitRoot {
            root = explicitRoot.standardizedFileURL
            guard !fileManager.fileExists(atPath: root.path) else {
                throw VersionControlError.executionFailed("测试设施目录已存在：\(root.path)")
            }
        } else {
            root = fileManager.temporaryDirectory
                .appendingPathComponent("RepHub-UpdateFixture-\(UUID().uuidString)", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = LocalRepositoryFixture(root: root, fileManager: fileManager)
        do {
            try fixture.makeDirectory(fixture.home)
            try fixture.makeDirectory(fixture.home.appendingPathComponent(".config", isDirectory: true))
            try fixture.makeDirectory(fixture.root.appendingPathComponent("remotes", isDirectory: true))
            try await fixture.createGitFixture()
            try await fixture.createSVNFixture()
            try await fixture.createDualFixture()
            return fixture
        } catch {
            try? fixture.remove()
            throw error
        }
    }

    /// 所有命令必须在本设施根目录内运行，且参数不得引用非本地远端或根目录外路径。
    @discardableResult
    public func run(
        executable: String,
        arguments: [String],
        directory: URL? = nil,
        timeout: TimeInterval = 20
    ) async throws -> CommandResult {
        let workingDirectory = directory ?? root
        try requireInsideRoot(workingDirectory, includingRoot: true)
        for argument in arguments { try validate(argument: argument) }
        return try await runner.run(executable: executable, arguments: arguments, directory: workingDirectory, timeout: timeout)
    }

    public func remove() throws {
        try requireInsideRoot(root, includingRoot: true)
        guard root.lastPathComponent.hasPrefix("RepHub-UpdateFixture-") || root.path.contains("/update-fixtures/") else {
            throw VersionControlError.executionFailed("拒绝清理非 RepHub 测试设施目录：\(root.path)")
        }
        try fileManager.removeItem(at: root)
    }

    private func createGitFixture() async throws {
        try await success("git", ["init", "--bare", gitRemote.path])
        try await success("git", ["clone", gitRemote.path, gitWriter.path])
        try await success("git", ["config", "user.name", "RepHub Fixture"], directory: gitWriter)
        try await success("git", ["config", "user.email", "fixture@localhost"], directory: gitWriter)
        try write("initial fixture\n", to: gitWriter.appendingPathComponent("README.md"))
        try await success("git", ["add", "README.md"], directory: gitWriter)
        try await success("git", ["commit", "-m", "fixture initial commit"], directory: gitWriter)
        try await success("git", ["branch", "-M", "main"], directory: gitWriter)
        try await success("git", ["push", "-u", "origin", "main"], directory: gitWriter)
        try await success("git", ["clone", gitRemote.path, gitReader.path])
        try await success("git", ["checkout", "main"], directory: gitReader)
    }

    private func createSVNFixture() async throws {
        try await success("svnadmin", ["create", svnRepository.path])
        let repositoryURL = svnRepositoryURL
        try await success("svn", ["mkdir", "-m", "fixture create trunk", "\(repositoryURL)/trunk"])
        try await success("svn", ["checkout", "\(repositoryURL)/trunk", svnWriter.path])
        try write("initial fixture\n", to: svnWriter.appendingPathComponent("README.md"))
        try await success("svn", ["add", "README.md"], directory: svnWriter)
        try await success("svn", ["commit", "-m", "fixture initial commit"], directory: svnWriter)
        try await success("svn", ["checkout", "\(repositoryURL)/trunk", svnReader.path])
    }

    private func createDualFixture() async throws {
        try await success("svn", ["checkout", "\(svnRepositoryURL)/trunk", dualWorkingCopy.path])
        let dualRemote = root.appendingPathComponent("remotes/dual-origin.git", isDirectory: true)
        try await success("git", ["init", "--bare", dualRemote.path])
        try await success("git", ["init"], directory: dualWorkingCopy)
        try await success("git", ["config", "user.name", "RepHub Fixture"], directory: dualWorkingCopy)
        try await success("git", ["config", "user.email", "fixture@localhost"], directory: dualWorkingCopy)
        try await success("git", ["add", "README.md"], directory: dualWorkingCopy)
        try await success("git", ["commit", "-m", "fixture initial commit"], directory: dualWorkingCopy)
        try await success("git", ["branch", "-M", "main"], directory: dualWorkingCopy)
        try await success("git", ["remote", "add", "origin", dualRemote.path], directory: dualWorkingCopy)
        try await success("git", ["push", "-u", "origin", "main"], directory: dualWorkingCopy)
    }

    private var svnRepositoryURL: String { svnRepository.absoluteURL.absoluteString }

    @discardableResult
    private func success(_ executable: String, _ arguments: [String], directory: URL? = nil) async throws -> CommandResult {
        try requireSuccess(try await run(executable: executable, arguments: arguments, directory: directory), tool: executable)
    }

    private func makeDirectory(_ url: URL) throws {
        try requireInsideRoot(url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func write(_ content: String, to url: URL) throws {
        try requireInsideRoot(url)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    private func requireInsideRoot(_ url: URL, includingRoot: Bool = false) throws {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard (includingRoot && candidate == rootPath) || candidate.hasPrefix(rootPath + "/") else {
            throw VersionControlError.executionFailed("测试操作越出隔离目录：\(candidate)")
        }
    }

    private func validate(argument: String) throws {
        if argument.contains("://") {
            guard let url = URL(string: argument), url.scheme == "file", url.host == nil || url.host?.isEmpty == true else {
                throw VersionControlError.executionFailed("测试设施拒绝非本地远端：\(argument)")
            }
            try requireInsideRoot(url)
            return
        }
        if argument.hasPrefix("/") { try requireInsideRoot(URL(fileURLWithPath: argument)) }
    }
}
