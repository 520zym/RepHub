import Foundation
import Darwin
import XCTest
@testable import SVNAdapter
import TestSupport
import ToolExecution
import VersionControlCore

final class SVNAcquisitionTests: XCTestCase {
    func testBrowsesAndChecksOutSelectedSubdirectory() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 获取测试。")
        }
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let selected = fixture.svnWriter.appendingPathComponent("子 目录@版本", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("subdirectory fixture\n".utf8).write(to: selected.appendingPathComponent("说明 文件.txt"))
        _ = try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["add", selected.path + "@"], directory: fixture.svnWriter),
            tool: "svn"
        )
        _ = try requireSuccess(
            try await fixture.run(executable: "svn", arguments: ["commit", "-m", "add selectable child"], directory: fixture.svnWriter),
            tool: "svn"
        )

        let provider = SVNProvider(runner: fixture.runner)
        let rootListing = try await provider.browseRemote(RemoteRepositoryLocation(url: fixture.svnURL.absoluteString))
        let entry = try XCTUnwrap(rootListing.entries.first { $0.name == "子 目录@版本" })
        XCTAssertTrue(entry.isDirectory)
        XCTAssertTrue(entry.url.contains("%E5%AD%90"))
        XCTAssertTrue(entry.url.contains("%20"))
        XCTAssertTrue(entry.url.contains("%40"))

        let destination = fixture.root.appendingPathComponent("checkout-target", isDirectory: true)
        let progress = ProgressMessages()
        try await provider.acquire(RemoteRepositoryLocation(url: entry.url), to: destination) { event in
            await progress.append(event.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("说明 文件.txt").path))
        let messages = await progress.values()
        XCTAssertTrue(messages.contains { $0.contains("检查") })
        XCTAssertTrue(messages.contains { $0.contains("完成") })

        let candidate = try await provider.detect(at: destination)
        let detected = try XCTUnwrap(candidate)
        XCTAssertEqual(detected.providerID, .svn)
        XCTAssertEqual(detected.root.standardizedFileURL, destination.standardizedFileURL)
    }

    func testRejectsExistingCheckoutDestinationBeforeWriting() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil else {
            throw XCTSkip("未安装 svn 或 svnadmin，跳过 SVN 获取测试。")
        }
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }
        let destination = fixture.root.appendingPathComponent("already-exists", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try await SVNProvider(runner: fixture.runner).acquire(
                RemoteRepositoryLocation(url: fixture.svnURL.absoluteString),
                to: destination,
                progress: { _ in }
            )
            XCTFail("已存在目标不应检出")
        } catch let error as VersionControlError {
            guard case .invalidRepository = error else {
                return XCTFail("错误类型不正确：\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".svn").path))
    }

    func testSessionCredentialsAuthenticateBrowseCheckoutAndLaterHistoryUpdate() async throws {
        guard ToolLocator.find("svn") != nil, ToolLocator.find("svnadmin") != nil,
              let svnserve = ToolLocator.find("svnserve") else {
            throw XCTSkip("未安装 svn、svnadmin 或 svnserve，跳过 SVN 认证获取测试。")
        }
        let fixture = try await LocalRepositoryFixture.create()
        defer { try? fixture.remove() }

        let configuration = fixture.svnRepository.appendingPathComponent("conf/svnserve.conf")
        let passwordFile = fixture.svnRepository.appendingPathComponent("conf/passwd")
        try Data("""
        [general]
        anon-access = none
        auth-access = write
        password-db = passwd
        realm = RepHub acquisition test
        """.utf8).write(to: configuration, options: .atomic)
        try Data("""
        [users]
        fixture-user = fixture-password
        """.utf8).write(to: passwordFile, options: .atomic)

        let port = try availableLoopbackPort()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: svnserve)
        server.arguments = [
            "--daemon", "--foreground", "--root", fixture.root.appendingPathComponent("remotes").path,
            "--listen-host", "127.0.0.1", "--listen-port", String(port)
        ]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        try await waitForLoopbackServer(port: port, process: server)

        let remote = "svn://127.0.0.1:\(port)/svn-repository/trunk"
        let provider = SVNProvider(runner: fixture.runner)
        let credentials = RepositoryCredentials(username: "fixture-user", password: "fixture-password")
        let listing = try await provider.browseRemote(RemoteRepositoryLocation(url: remote, credentials: credentials))
        XCTAssertTrue(listing.entries.contains { $0.name == "README.md" })

        let destination = fixture.root.appendingPathComponent("authenticated-checkout", isDirectory: true)
        try await provider.acquire(RemoteRepositoryLocation(url: remote), to: destination, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.md").path))

        let candidate = try await provider.detect(at: destination)
        let binding = try XCTUnwrap(candidate)
        let history = try await provider.history(in: binding, limit: 1, reference: nil)
        XCTAssertEqual(history.first?.message, "fixture initial commit")
        let update = try await provider.perform(.update, in: binding, progress: { _ in })
        XCTAssertEqual(update.outcome, .succeeded)
    }
}

private actor ProgressMessages {
    private var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
    func values() -> [String] { messages }
}

private func availableLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &address, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }) == 0 else { throw POSIXError(.EADDRINUSE) }
    return UInt16(bigEndian: address.sin_port)
}

private func waitForLoopbackServer(port: UInt16, process: Process) async throws {
    for _ in 0..<50 {
        if loopbackServerAcceptsConnections(port: port) { return }
        if !process.isRunning { throw VersionControlError.executionFailed("认证测试 svnserve 启动失败。") }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw VersionControlError.timedOut("svnserve")
}

private func loopbackServerAcceptsConnections(port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}
