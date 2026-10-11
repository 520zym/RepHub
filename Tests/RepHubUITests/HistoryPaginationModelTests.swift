import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class HistoryPaginationModelTests: XCTestCase {
    func testRepositoryPagesAppendWithoutDuplicatesAndKeepCurrentReading() async throws {
        let controller = PagingController(repositoryPages: [
            .history(nil, nil): .init(revisions: [revision("c3"), revision("c2")], nextCursor: "older"),
            .history(nil, "older"): .init(revisions: [revision("c2"), revision("c1")], nextCursor: nil),
        ])
        let (model, directory) = try await openModel(controller: controller)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await waitUntil { !model.isLoading && model.historyRevisions.map(\.id) == ["c3", "c2"] }

        model.setHistoryVisible(true)
        model.selectRevision(model.historyRevisions[1])
        try await waitUntil { model.selectedRevisionID == "c2" && model.patch?.text == "revision:c2:Sources/c2.swift" }
        let selectedPatch = model.patch?.text

        model.loadMoreHistory()
        try await waitUntil { !model.isLoadingMoreHistory && !model.hasMoreHistory }

        XCTAssertEqual(model.historyRevisions.map(\.id), ["c3", "c2", "c1"])
        XCTAssertEqual(model.selectedRevisionID, "c2")
        XCTAssertEqual(model.patch?.text, selectedPatch)
        XCTAssertNil(model.historyPageError)
    }

    func testFailedNextRepositoryPageKeepsLoadedEntriesAndCanRetry() async throws {
        let controller = PagingController(
            repositoryPages: [
                .history(nil, nil): .init(revisions: [revision("c3")], nextCursor: "older"),
                .history(nil, "older"): .init(revisions: [revision("c2")], nextCursor: nil),
            ],
            failures: [.history(nil, "older"): 1]
        )
        let (model, directory) = try await openModel(controller: controller)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await waitUntil { !model.isLoading && model.hasMoreHistory }

        model.loadMoreHistory()
        try await waitUntil { !model.isLoadingMoreHistory && model.historyPageError != nil }
        XCTAssertEqual(model.historyRevisions.map(\.id), ["c3"])
        XCTAssertTrue(model.hasMoreHistory)

        model.loadMoreHistory()
        try await waitUntil { !model.isLoadingMoreHistory && !model.hasMoreHistory }
        XCTAssertEqual(model.historyRevisions.map(\.id), ["c3", "c2"])
        XCTAssertNil(model.historyPageError)
    }

    func testLateRepositoryPageDoesNotMixAfterChangingReference() async throws {
        let delayedOlder = PagingController.RepositoryPage(revisions: [revision("main-old")], nextCursor: nil,
                                                            delayNanoseconds: 200_000_000)
        let controller = PagingController(repositoryPages: [
            .history(nil, nil): .init(revisions: [revision("main-new")], nextCursor: "older"),
            .history(nil, "older"): delayedOlder,
            .history("release", nil): .init(revisions: [revision("release-new")], nextCursor: nil),
        ])
        let (model, directory) = try await openModel(controller: controller)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await waitUntil { !model.isLoading && model.hasMoreHistory }

        model.loadMoreHistory()
        try await waitUntil { model.isLoadingMoreHistory }
        model.selectHistoryReference("release")
        try await waitUntil { !model.isLoading && model.historyRevisions.map(\.id) == ["release-new"] }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.historyReference, "release")
        XCTAssertEqual(model.historyRevisions.map(\.id), ["release-new"])
        XCTAssertFalse(model.isLoadingMoreHistory)
        XCTAssertNil(model.historyPageError)
    }

    func testLateRepositoryPageDoesNotMixAfterRefreshOrBindingChange() async throws {
        let controller = PagingController(repositoryPages: [
            .history(nil, nil): .init(revisions: [revision("git-new")], nextCursor: "git-older"),
            .history(nil, "git-older"): .init(revisions: [revision("git-old")], nextCursor: nil,
                                                delayNanoseconds: 200_000_000),
        ])
        let svnController = PagingController(repositoryPages: [
            .history(nil, nil): .init(revisions: [revision("svn-new")], nextCursor: nil),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = PagingFixtureProvider(id: .git, controller: controller)
        let svn = PagingFixtureProvider(id: .svn, controller: svnController)
        let model = WorkspaceModel(service: RepositoryService(providers: [git, svn]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.workspace?.bindings.count == 2 && model.hasMoreHistory }

        model.loadMoreHistory()
        try await waitUntil { model.isLoadingMoreHistory }
        model.refresh()
        try await waitUntil { !model.isLoading && model.historyRevisions.map(\.id) == ["git-new"] }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.historyRevisions.map(\.id), ["git-new"])

        model.loadMoreHistory()
        try await waitUntil { model.isLoadingMoreHistory }
        let svnBinding = try XCTUnwrap(model.workspace?.bindings.first { $0.providerID == .svn })
        model.selectBinding(svnBinding)
        try await waitUntil { !model.isLoading && model.selectedBindingID == svnBinding.id && model.historyRevisions.map(\.id) == ["svn-new"] }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.historyRevisions.map(\.id), ["svn-new"])
    }

    func testFileHistoryPagesKeepHistoricalPathAndPegRevision() async throws {
        let current = FileHistoryEntry(revision: revision("c3"), path: "Sources/New.swift", pegRevision: "c3")
        let old = FileHistoryEntry(revision: revision("c2"), path: "Sources/Old.swift", pegRevision: "c7")
        let controller = PagingController(filePages: [
            .file("Sources/New.swift", nil, nil): .init(entries: [current], nextCursor: "older-file"),
            .file("Sources/New.swift", nil, "older-file"): .init(entries: [old], nextCursor: nil),
        ])
        let (model, directory) = try await openModel(controller: controller)
        defer { try? FileManager.default.removeItem(at: directory) }

        model.showFileHistory(path: "Sources/New.swift")
        try await waitUntil { !model.isLoading && model.historyFileEntries.map(\.revision.id) == ["c3"] && model.hasMoreHistory }
        model.loadMoreHistory()
        try await waitUntil { !model.isLoadingMoreHistory && !model.hasMoreHistory }

        XCTAssertEqual(model.historyFileEntries.map(\.path), ["Sources/New.swift", "Sources/Old.swift"])
        XCTAssertEqual(model.historyFileEntries.last?.pegRevision, "c7")
        model.selectRevision(old.revision)
        try await waitUntil { model.patch?.text == "file:c2:Sources/Old.swift:c7" }
    }

    func testLateFilePageDoesNotMixAfterChangingFileScope() async throws {
        let controller = PagingController(filePages: [
            .file("Sources/New.swift", nil, nil): .init(entries: [fileEntry("new")], nextCursor: "older"),
            .file("Sources/New.swift", nil, "older"): .init(entries: [fileEntry("old", path: "Sources/Old.swift")], nextCursor: nil,
                                                               delayNanoseconds: 200_000_000),
            .file("README.md", nil, nil): .init(entries: [fileEntry("readme", path: "README.md")], nextCursor: nil),
        ])
        let (model, directory) = try await openModel(controller: controller)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.showFileHistory(path: "Sources/New.swift")
        try await waitUntil { !model.isLoading && model.hasMoreHistory }

        model.loadMoreHistory()
        try await waitUntil { model.isLoadingMoreHistory }
        model.showFileHistory(path: "README.md")
        try await waitUntil { !model.isLoading && model.historyFilePath == "README.md" && model.historyRevisions.map(\.id) == ["readme"] }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.historyFileEntries.map(\.path), ["README.md"])
        XCTAssertFalse(model.isLoadingMoreHistory)
        XCTAssertNil(model.historyPageError)
    }

    private func openModel(controller: PagingController) async throws -> (WorkspaceModel, URL) {
        let directory = try temporaryDirectory()
        let model = WorkspaceModel(service: RepositoryService(providers: [PagingFixtureProvider(id: .git, controller: controller)]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        return (model, directory)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-HistoryPagination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func revision(_ id: String) -> Revision {
        Revision(id: id, author: "zym", date: .distantPast, message: "提交 \(id)")
    }

    private func fileEntry(_ id: String, path: String = "Sources/New.swift") -> FileHistoryEntry {
        FileHistoryEntry(revision: revision(id), path: path, pegRevision: id)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "等待异步状态超时")
    }
}

private struct PagingFixtureProvider: RepositoryHistoryPagingProvider {
    let id: ProviderID
    let controller: PagingController
    var displayName: String { id == .svn ? "SVN 分页测试" : "Git 分页测试" }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: directory, currentBranch: id == .git ? "main" : "",
                          capabilities: [.status, .diff, .history, .fileHistory])
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] { [] }

    func historyPage(in binding: RepositoryBinding, request: HistoryPageRequest) async throws -> RepositoryHistoryPage {
        let page = try await controller.repositoryPage(reference: request.reference, cursor: request.cursor)
        return RepositoryHistoryPage(revisions: page.revisions, nextCursor: page.nextCursor)
    }

    func fileHistoryPage(in binding: RepositoryBinding, path: String, request: HistoryPageRequest) async throws -> FileHistoryPage {
        let page = try await controller.filePage(path: path, reference: request.reference, cursor: request.cursor)
        return FileHistoryPage(entries: page.entries, nextCursor: page.nextCursor)
    }

    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        RepositoryPatch(text: "file:\(entry.revision.id):\(entry.path):\(entry.pegRevision ?? "")")
    }

    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        RepositorySyncStatus(summary: "分页测试")
    }

    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        [FileChange(path: "Sources/\(revision).swift", kind: .modified)]
    }

    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        RepositoryPatch(text: "\(revision.map { "revision:\($0)" } ?? "working"):\(path ?? "all")")
    }
}

private actor PagingController {
    struct Key: Hashable, Sendable {
        let scope: String
        let reference: String?
        let cursor: String?

        static func history(_ reference: String?, _ cursor: String?) -> Self {
            .init(scope: "history", reference: reference, cursor: cursor)
        }

        static func file(_ path: String, _ reference: String?, _ cursor: String?) -> Self {
            .init(scope: "file:\(path)", reference: reference, cursor: cursor)
        }
    }

    struct RepositoryPage: Sendable {
        let revisions: [Revision]
        let nextCursor: String?
        let delayNanoseconds: UInt64

        init(revisions: [Revision], nextCursor: String?, delayNanoseconds: UInt64 = 0) {
            self.revisions = revisions
            self.nextCursor = nextCursor
            self.delayNanoseconds = delayNanoseconds
        }
    }

    struct FilePage: Sendable {
        let entries: [FileHistoryEntry]
        let nextCursor: String?
        let delayNanoseconds: UInt64

        init(entries: [FileHistoryEntry], nextCursor: String?, delayNanoseconds: UInt64 = 0) {
            self.entries = entries
            self.nextCursor = nextCursor
            self.delayNanoseconds = delayNanoseconds
        }
    }

    private let repositoryPages: [Key: RepositoryPage]
    private let filePages: [Key: FilePage]
    private var failures: [Key: Int]

    init(repositoryPages: [Key: RepositoryPage] = [:], filePages: [Key: FilePage] = [:], failures: [Key: Int] = [:]) {
        self.repositoryPages = repositoryPages
        self.filePages = filePages
        self.failures = failures
    }

    func repositoryPage(reference: String?, cursor: String?) async throws -> RepositoryPage {
        let key = Key.history(reference, cursor)
        if let remaining = failures[key], remaining > 0 {
            failures[key] = remaining - 1
            throw VersionControlError.executionFailed("分页测试失败")
        }
        guard let page = repositoryPages[key] else { throw VersionControlError.invalidData("未配置仓库分页测试页") }
        await uncancellableDelay(page.delayNanoseconds)
        return page
    }

    func filePage(path: String, reference: String?, cursor: String?) async throws -> FilePage {
        let key = Key.file(path, reference, cursor)
        if let remaining = failures[key], remaining > 0 {
            failures[key] = remaining - 1
            throw VersionControlError.executionFailed("分页测试失败")
        }
        guard let page = filePages[key] else { throw VersionControlError.invalidData("未配置文件分页测试页") }
        await uncancellableDelay(page.delayNanoseconds)
        return page
    }

    private func uncancellableDelay(_ nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }
}
