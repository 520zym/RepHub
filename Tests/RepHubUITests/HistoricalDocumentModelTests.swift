import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

/// 历史二进制文件只能来自所选节点，绝不能以工作副本同路径文件替代。
@MainActor
final class HistoricalDocumentModelTests: XCTestCase {
    func testHistoryDocumentUsesSelectedRevisionBytesInsteadOfWorkingCopy() async throws {
        let directory = try makeDirectory()
        let local = directory.appendingPathComponent("Documents/Plan.pdf")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let localBytes = Data("working-copy".utf8)
        try localBytes.write(to: local)
        let historicalBytes = Data("revision-r2".utf8)
        let provider = HistoricalDocumentProvider(contents: ["r2|Documents/Plan.pdf": .data(historicalBytes)])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r2" }

        let previewURL = try XCTUnwrap(model.filePreview?.systemPreviewURL)
        XCTAssertNotEqual(previewURL.standardizedFileURL, local.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: previewURL), historicalBytes)
        XCTAssertNotEqual(try Data(contentsOf: previewURL), localBytes)
        XCTAssertEqual(model.filePreview?.documentKind, .pdf)
        XCTAssertNil(model.patch)
    }

    func testSelectingHistoricalDocumentsReplacesQuickLookIdentity() async throws {
        let directory = try makeDirectory()
        let provider = HistoricalDocumentProvider(
            revisions: [revision("r2"), revision("r1")],
            files: [
                "r2": [FileChange(path: "Documents/New.pdf", kind: .modified)],
                "r1": [FileChange(path: "Documents/Old.xlsx", kind: .modified)],
            ],
            contents: [
                "r2|Documents/New.pdf": .data(Data("new-pdf".utf8)),
                "r1|Documents/Old.xlsx": .data(Data("old-sheet".utf8)),
            ]
        )
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r2" }
        let firstURL = try XCTUnwrap(model.filePreview?.systemPreviewURL)
        let firstIdentity = try XCTUnwrap(model.filePreview?.systemPreviewIdentity)

        model.selectRevision(revision("r1"))
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r1" }
        let secondURL = try XCTUnwrap(model.filePreview?.systemPreviewURL)
        let secondIdentity = try XCTUnwrap(model.filePreview?.systemPreviewIdentity)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertNotEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("old-sheet".utf8))
        XCTAssertEqual(model.filePreview?.documentKind, .spreadsheet)
    }

    func testLeavingHistoryHidesHistoricalDocumentAndRestoresWorkingSelection() async throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let local = true\n".write(to: source, atomically: true, encoding: .utf8)
        let provider = HistoricalDocumentProvider(contents: ["r2|Documents/Plan.pdf": .data(Data("history".utf8))])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(directory)
        try await waitUntil { !model.isLoading && model.patch?.text == "working:Sources/App.swift" }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r2" }
        model.setHistoryVisible(false)

        XCTAssertFalse(model.isHistoryVisible)
        XCTAssertNil(model.filePreview)
        XCTAssertEqual(model.selectedRevisionID, nil)
        XCTAssertEqual(model.patch?.text, "working:Sources/App.swift")
    }

    func testFileHistoryReadsRenamedEntryPathAtItsRevision() async throws {
        let directory = try makeDirectory()
        let provider = HistoricalDocumentProvider(
            fileHistoryEntries: [
                FileHistoryEntry(revision: revision("r2"), path: "Documents/OldName.pdf", pegRevision: "r2"),
            ],
            contents: ["r2|Documents/OldName.pdf": .data(Data("renamed-history".utf8))]
        )
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.showFileHistory(path: "Documents/NewName.pdf")
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r2" }

        XCTAssertEqual(model.selectedPath, "Documents/OldName.pdf")
        let contentRequests = await provider.log.contentRequests()
        XCTAssertEqual(contentRequests, ["r2|Documents/OldName.pdf|r2"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(model.filePreview?.systemPreviewURL)), Data("renamed-history".utf8))
    }

    func testSlowHistoricalDocumentCannotReplaceNewerSelection() async throws {
        let directory = try makeDirectory()
        let provider = HistoricalDocumentProvider(
            revisions: [revision("r2"), revision("r1")],
            files: [
                "r2": [FileChange(path: "Documents/Slow.pdf", kind: .modified)],
                "r1": [FileChange(path: "Documents/Fast.pdf", kind: .modified)],
            ],
            contents: [
                "r2|Documents/Slow.pdf": .delayed(Data("slow".utf8), 250_000_000),
                "r1|Documents/Fast.pdf": .data(Data("fast".utf8)),
            ]
        )
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.setHistoryVisible(true)
        try await provider.log.waitForContentRequest("r2|Documents/Slow.pdf|-")
        model.selectRevision(revision("r1"))
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r1" }
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(model.selectedRevisionID, "r1")
        XCTAssertEqual(model.selectedPath, "Documents/Fast.pdf")
        let url = try XCTUnwrap(model.filePreview?.systemPreviewURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("fast".utf8))
    }

    func testMissingOrFailedHistoricalDocumentShowsMessageWithoutLocalURL() async throws {
        let directory = try makeDirectory()
        let provider = HistoricalDocumentProvider(
            revisions: [revision("r2"), revision("r1")],
            files: [
                "r2": [FileChange(path: "Documents/Deleted.pdf", kind: .deleted)],
                "r1": [FileChange(path: "Documents/Unreadable.docx", kind: .modified)],
            ],
            contents: [
                "r2|Documents/Deleted.pdf": .missing,
                "r1|Documents/Unreadable.docx": .failure,
            ]
        )
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r2" }
        XCTAssertNil(model.filePreview?.systemPreviewURL)
        XCTAssertNotNil(model.filePreview?.message)
        XCTAssertNil(model.errorMessage)

        model.selectRevision(revision("r1"))
        try await waitUntil { !model.isLoading && model.filePreview?.revisionID == "r1" }
        XCTAssertNil(model.filePreview?.systemPreviewURL)
        XCTAssertTrue(model.filePreview?.message?.contains("无法读取该节点的文档") == true)
        XCTAssertNil(model.errorMessage)
    }

    func testHistoricalTextStillUsesNormalDiffInsteadOfDocumentSnapshot() async throws {
        let directory = try makeDirectory()
        let provider = HistoricalDocumentProvider(
            files: ["r2": [FileChange(path: "Sources/Readable.swift", kind: .modified)]],
            contents: [:]
        )
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.patch?.text == "revision:r2:Sources/Readable.swift" }

        XCTAssertNil(model.filePreview)
        let diffRequests = await provider.log.diffRequests()
        let contentRequests = await provider.log.contentRequests()
        XCTAssertTrue(diffRequests.contains("r2|Sources/Readable.swift"))
        XCTAssertTrue(contentRequests.isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rephub-history-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(timeout: UInt64 = 2_000_000_000, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待历史文档读取完成超时")
    }

    private func revision(_ id: String) -> Revision {
        Revision(id: id, author: "zym", date: .distantPast, message: "历史节点 \(id)")
    }
}

private enum HistoricalContent: Sendable {
    case data(Data)
    case delayed(Data, UInt64)
    case missing
    case failure
}

private struct HistoricalDocumentProvider: RepositoryHistoryProvider, RepositoryFileContentProvider {
    let id: ProviderID = .git
    let displayName = "历史文档测试适配器"
    let revisions: [Revision]
    let files: [String: [FileChange]]
    let fileHistoryEntries: [FileHistoryEntry]
    let contents: [String: HistoricalContent]
    let log = HistoricalDocumentLog()

    init(revisions: [Revision] = [Revision(id: "r2", author: "zym", date: .distantPast, message: "历史 PDF")],
         files: [String: [FileChange]] = ["r2": [FileChange(path: "Documents/Plan.pdf", kind: .modified)]],
         fileHistoryEntries: [FileHistoryEntry]? = nil,
         contents: [String: HistoricalContent]) {
        self.revisions = revisions
        self.files = files
        self.fileHistoryEntries = fileHistoryEntries ?? revisions.map { FileHistoryEntry(revision: $0, path: files[$0.id]?.first?.path ?? "Documents/Plan.pdf", pegRevision: $0.id) }
        self.contents = contents
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        RepositoryBinding(providerID: id, providerName: displayName, root: directory, currentBranch: "main",
                          capabilities: [.status, .diff, .history, .fileHistory])
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [FileChange(path: "Sources/App.swift", kind: .modified)]
    }

    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { revisions }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { files[revision] ?? [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        await log.recordDiff("\(revision ?? "working")|\(path ?? "all")")
        return RepositoryPatch(text: "\(revision.map { "revision:\($0)" } ?? "working"):\(path ?? "all")")
    }

    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] {
        fileHistoryEntries
    }
    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        RepositoryPatch(text: "file-history:\(entry.revision.id):\(entry.path)")
    }
    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        RepositorySyncStatus(summary: "测试同步")
    }

    func fileContent(in binding: RepositoryBinding, path: String, revision: String, pegRevision: String?) async throws -> Data? {
        let key = "\(revision)|\(path)"
        await log.recordContentRequest("\(key)|\(pegRevision ?? "-")")
        switch contents[key] ?? .missing {
        case .data(let data): return data
        case .delayed(let data, let nanoseconds):
            await uninterruptibleDelay(nanoseconds)
            return data
        case .missing: return nil
        case .failure: throw VersionControlError.executionFailed("测试节点读取失败")
        }
    }

    private func uninterruptibleDelay(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { continuation.resume() }
        }
    }
}

private actor HistoricalDocumentLog {
    private var requests: [String] = []
    private var diffs: [String] = []

    func recordContentRequest(_ request: String) { requests.append(request) }
    func recordDiff(_ request: String) { diffs.append(request) }
    func contentRequests() -> [String] { requests }
    func diffRequests() -> [String] { diffs }

    func waitForContentRequest(_ request: String) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !requests.contains(request) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard requests.contains(request) else { throw VersionControlError.timedOut("测试历史文档读取") }
    }
}
