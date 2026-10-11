import Foundation
import XCTest
@testable import RepHubUI

@MainActor
final class WorkspaceFileBrowserTests: XCTestCase {
    func testLazyDirectoryLoadingAndSameRootKeepsExpansion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-file-browser-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("nested".utf8).write(to: folder.appendingPathComponent("App.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let browser = WorkspaceFileBrowser()
        browser.setRoot(root)
        try await waitUntil { browser.children(in: "").contains(where: { $0.path == "Sources" }) }
        XCTAssertTrue(browser.children(in: "Sources").isEmpty, "未展开目录不应预读取子项")

        let sources = try XCTUnwrap(browser.children(in: "").first(where: { $0.path == "Sources" }))
        browser.toggleDirectory(sources)
        try await waitUntil { browser.children(in: "Sources").contains(where: { $0.path == "Sources/App.swift" }) }
        XCTAssertTrue(browser.isExpanded("Sources"))

        browser.setRoot(root)
        XCTAssertTrue(browser.isExpanded("Sources"), "相同根目录的刷新不应丢失展开状态")
    }

    private func waitUntil(
        timeout: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待文件树异步读取超时")
    }
}
