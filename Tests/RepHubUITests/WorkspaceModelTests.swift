import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testRepeatedTabsRestoreBothSelectionsWithoutReadingProviderAgain() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(try makeDirectory())
        try await waitUntil { !model.isLoading && model.patch != nil }
        model.selectChange(FileChange(path: "Sources/New.swift", kind: .modified))
        try await waitUntil { !model.isLoading && model.selectedPath == "Sources/New.swift" }
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.selectedRevisionID != nil }
        model.selectRevisionFile(FileChange(path: "README.md", kind: .modified))
        try await waitUntil { !model.isLoading && model.patch?.text == "revision:a1b2c3d4:README.md" }
        let before = await provider.log.diffRequests().count
        let filesBefore = await provider.log.changedFileRequests().count

        for _ in 0..<10 {
            model.setHistoryVisible(false)
            XCTAssertEqual(model.patch?.text, "working:Sources/New.swift")
            XCTAssertFalse(model.isLoading)
            model.setHistoryVisible(true)
            XCTAssertEqual(model.patch?.text, "revision:a1b2c3d4:README.md")
            XCTAssertFalse(model.isLoading)
        }
        let after = await provider.log.diffRequests().count
        let filesAfter = await provider.log.changedFileRequests().count
        XCTAssertEqual(before, after, "已查看的TAB往返不应再次运行版本控制差异读取")
        XCTAssertEqual(filesBefore, filesAfter)
        model.refresh()
        try await waitUntil { !model.isLoading }
        let refreshed = await provider.log.diffRequests().count
        XCTAssertGreaterThan(refreshed, after, "显式刷新必须使阅读缓存失效")
    }

    func testUnchangedFilePreviewSurvivesTabsAndRefreshReadsNewContent() async throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("Unchanged.txt")
        try "initial content".write(to: file, atomically: true, encoding: .utf8)
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        model.open(directory)
        try await waitUntil { !model.isLoading && model.snapshot != nil }
        model.selectWorkspaceFile(path: "Unchanged.txt")
        try await waitUntil { !model.isLoading && model.filePreview?.text == "initial content" }
        XCTAssertNil(model.patch)
        model.setHistoryVisible(true)
        try await waitUntil { !model.isLoading && model.selectedRevisionID != nil }
        XCTAssertNil(model.filePreview)
        model.setHistoryVisible(false)
        XCTAssertEqual(model.filePreview?.text, "initial content")
        XCTAssertEqual(model.selectedPath, "Unchanged.txt")
        try "updated content".write(to: file, atomically: true, encoding: .utf8)
        model.refresh()
        try await waitUntil { !model.isLoading && model.filePreview?.text == "updated content" }
        XCTAssertNil(model.selectedRevisionID)
        let requests = await provider.log.diffRequests()
        XCTAssertFalse(requests.contains { $0.path == "Unchanged.txt" }, "本地普通文件预览不调用VCS差异工具")
    }

    func testOpenAutomaticallySelectsReadableSourceFileAndLoadsWorkingDiff() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.selectedPath == "Sources/App.swift" && model.patch?.text == "working:Sources/App.swift" }

        XCTAssertEqual(model.selectedBinding?.providerID, .git)
        XCTAssertNil(model.selectedRevisionID)
        XCTAssertEqual(model.patch?.text, "working:Sources/App.swift")
        let diffs = await provider.log.diffRequests()
        XCTAssertTrue(diffs.contains { $0.path == "Sources/App.swift" && $0.revision == nil })
    }

    func testOpeningDualManagedWorkspaceRecordsOneRecentRepository() async throws {
        let directory = try makeDirectory()
        let store = RecentRepositoryStore()
        let git = WorkspaceFixtureProvider(providerID: .git)
        let svn = WorkspaceFixtureProvider(providerID: .svn)
        let model = WorkspaceModel(service: RepositoryService(providers: [git, svn]), recentRepositories: store)

        model.open(directory)
        try await waitUntil { !model.isLoading && model.workspace?.bindings.count == 2 }

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].path, directory.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.entries[0].providerNames, ["Git 测试适配器", "SVN 测试适配器"])
    }

    func testReopeningRepositoryMovesItsRecentEntryToFrontWithoutDuplicating() async throws {
        let firstDirectory = try makeDirectory()
        let secondDirectory = try makeDirectory()
        let store = RecentRepositoryStore()
        let model = WorkspaceModel(service: RepositoryService(providers: [WorkspaceFixtureProvider()]), recentRepositories: store)

        model.open(firstDirectory)
        try await waitUntil { !model.isLoading && model.workspace?.directory == firstDirectory.standardizedFileURL }
        model.open(secondDirectory)
        try await waitUntil { !model.isLoading && model.workspace?.directory == secondDirectory.standardizedFileURL }
        model.open(firstDirectory)
        try await waitUntil { !model.isLoading && model.workspace?.directory == firstDirectory.standardizedFileURL }

        XCTAssertEqual(store.entries.map(\.path), [
            firstDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
            secondDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
        ])
    }

    func testUnmanagedAndDetectionFailureAreNotRecordedAsRecentRepositories() async throws {
        let unmanagedDirectory = try makeDirectory()
        let failedDirectory = try makeDirectory()
        let store = RecentRepositoryStore()
        let unmanaged = WorkspaceFixtureProvider(detectsRepository: false)
        let model = WorkspaceModel(service: RepositoryService(providers: [unmanaged]), recentRepositories: store)

        model.open(unmanagedDirectory)
        try await waitUntil { !model.isLoading && model.workspace?.isUnmanaged == true }
        XCTAssertTrue(store.entries.isEmpty)

        let failing = WorkspaceFixtureProvider(detectError: true)
        let failingModel = WorkspaceModel(service: RepositoryService(providers: [failing]), recentRepositories: store)
        failingModel.open(failedDirectory)
        try await waitUntil { !failingModel.isLoading && !(failingModel.workspace?.issues.isEmpty ?? true) }
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testOpeningMissingRecentRepositoryPreservesCurrentWorkspaceAndHistory() async throws {
        let directory = try makeDirectory()
        let store = RecentRepositoryStore()
        let model = WorkspaceModel(service: RepositoryService(providers: [WorkspaceFixtureProvider()]), recentRepositories: store)
        model.open(directory)
        try await waitUntil { !model.isLoading && model.workspace?.directory == directory.standardizedFileURL }
        model.setHistoryVisible(true)
        try await waitUntil { model.selectedRevisionID != nil }
        let openedWorkspace = try XCTUnwrap(model.workspace)
        let historyID = model.selectedRevisionID
        let originalEntries = store.entries
        let missing = RecentRepository(
            path: directory.appendingPathComponent("missing-repository", isDirectory: true).path,
            name: "missing-repository", providerNames: ["Git"], lastOpenedAt: .now
        )

        model.openRecentRepository(missing)

        XCTAssertEqual(model.workspace?.id, openedWorkspace.id)
        XCTAssertEqual(model.selectedRevisionID, historyID)
        XCTAssertEqual(store.entries, originalEntries)
        XCTAssertNotNil(model.recentRepositoryError)
        XCTAssertTrue(model.recentRepositoryError?.contains("不存在或无法访问") == true)
    }

    func testOpeningRecentDirectoryWithoutVersionControlPreservesCurrentSelectionAndDiff() async throws {
        let managedDirectory = try makeDirectory()
        let staleDirectory = try makeDirectory()
        let store = RecentRepositoryStore()
        let provider = WorkspaceFixtureProvider(unmanagedDirectories: [staleDirectory.standardizedFileURL.path])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]), recentRepositories: store)

        model.open(managedDirectory)
        try await waitUntil { model.patch?.text == "working:Sources/App.swift" && !model.isLoading }
        let currentWorkspace = try XCTUnwrap(model.workspace)
        let currentPath = model.selectedPath
        let currentPatch = model.patch
        let staleBinding = RepositoryBinding(providerID: .git, providerName: "Git 测试适配器",
                                             root: staleDirectory, capabilities: [.status])
        store.record(Workspace(directory: staleDirectory, bindings: [staleBinding], issues: []))
        let staleRepository = try XCTUnwrap(store.entries.first { $0.path == staleDirectory.standardizedFileURL.path })
        let entriesBefore = store.entries

        model.openRecentRepository(staleRepository)
        try await waitUntil { !model.isLoading && model.recentRepositoryError != nil }

        XCTAssertEqual(model.workspace?.id, currentWorkspace.id)
        XCTAssertEqual(model.selectedPath, currentPath)
        XCTAssertEqual(model.patch?.text, currentPatch?.text)
        XCTAssertEqual(model.patch?.isTruncated, currentPatch?.isTruncated)
        XCTAssertEqual(store.entries, entriesBefore)
        XCTAssertTrue(model.recentRepositoryError?.contains("无法识别为受版本控制的仓库") == true)
    }

    func testLateOpenDoesNotRecordSupersededRepository() async throws {
        let slowDirectory = try makeDirectory()
        let currentDirectory = try makeDirectory()
        let log = WorkspaceInvocationLog()
        let provider = WorkspaceFixtureProvider(
            detectDelays: [slowDirectory.standardizedFileURL.path: 180_000_000], log: log
        )
        let store = RecentRepositoryStore()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]), recentRepositories: store)

        model.open(slowDirectory)
        try await waitForDetectionStart(slowDirectory, log: log)
        model.open(currentDirectory)
        try await waitUntil { !model.isLoading && model.workspace?.directory == currentDirectory.standardizedFileURL }
        try await Task.sleep(nanoseconds: 240_000_000)

        XCTAssertEqual(store.entries.map(\.path), [currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path])
    }

    func testSelectingHistoryRevisionLoadsItsPreferredFileWithSameRevision() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot?.revisions.first != nil }
        let revision = try XCTUnwrap(model.snapshot?.revisions.first)

        model.selectRevision(revision)
        try await waitUntil { model.selectedRevisionID == revision.id && model.patch?.text == "revision:\(revision.id):Sources/Revision.swift" }

        XCTAssertEqual(model.selectedPath, "Sources/Revision.swift")
        XCTAssertEqual(model.revisionFiles.map(\.path), ["README.md", "Sources/Revision.swift"])
        let changedFiles = await provider.log.changedFileRequests()
        let diffs = await provider.log.diffRequests()
        XCTAssertTrue(changedFiles.contains(revision.id))
        XCTAssertTrue(diffs.contains { $0.path == "Sources/Revision.swift" && $0.revision == revision.id })
    }

    func testLateDiffResponseCannotOverwriteNewerSelection() async throws {
        let provider = WorkspaceFixtureProvider(delays: ["Sources/Old.swift": 180_000_000, "Sources/New.swift": 20_000_000])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.selectChange(FileChange(path: "Sources/Old.swift", kind: .modified))
        try await waitForDiffStart("Sources/Old.swift", log: provider.log)
        model.selectChange(FileChange(path: "Sources/New.swift", kind: .modified))

        try await waitUntil { model.selectedPath == "Sources/New.swift" && model.patch?.text == "working:Sources/New.swift" }
        try await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertEqual(model.selectedPath, "Sources/New.swift")
        XCTAssertEqual(model.patch?.text, "working:Sources/New.swift")
    }

    func testRefreshKeepsHistoryReferenceAndReloadsSelectedRevision() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        let reference = "feature/demo"

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot?.revisions.first != nil }
        model.selectHistoryReference(reference)
        try await waitUntil {
            model.historyReference == reference
                && model.selectedRevisionID == "a1b2c3d4"
                && model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift"
        }

        model.refresh()
        try await waitUntil {
            model.historyReference == reference
                && model.selectedRevisionID == "a1b2c3d4"
                && model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift"
        }

        let references = await provider.log.historyReferences()
        let revisions = await provider.log.changedFileRequests()
        XCTAssertGreaterThanOrEqual(references.filter { $0 == reference }.count, 2)
        XCTAssertGreaterThanOrEqual(revisions.filter { $0 == "a1b2c3d4" }.count, 2)
    }

    func testHistoryModeSwitchesDualBindingsWithoutLoadingWorkingDiff() async throws {
        let gitLog = WorkspaceInvocationLog()
        let svnLog = WorkspaceInvocationLog()
        let git = WorkspaceFixtureProvider(log: gitLog)
        let svn = WorkspaceFixtureProvider(providerID: .svn, revisions: [Revision(id: "r42", author: "zym", date: .distantPast, message: "svn history")], log: svnLog)
        let model = WorkspaceModel(service: RepositoryService(providers: [git, svn]))

        model.setHistoryVisible(true)
        model.open(try makeDirectory())
        try await waitUntil { model.selectedBinding?.providerID == .git && model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift" }

        let svnBinding = try XCTUnwrap(model.workspace?.bindings.first(where: { $0.providerID == .svn }))
        model.selectBinding(svnBinding)
        try await waitUntil { model.selectedBinding?.providerID == .svn && model.selectedRevisionID == "r42" && model.patch?.text == "revision:r42:Sources/Revision.swift" }

        let gitDiffs = await gitLog.diffRequests()
        let svnDiffs = await svnLog.diffRequests()
        XCTAssertFalse(gitDiffs.contains { $0.revision == nil })
        XCTAssertFalse(svnDiffs.contains { $0.revision == nil })
    }

    func testHistoryModeWithEmptyHistoryDoesNotShowWorkingDiff() async throws {
        let provider = WorkspaceFixtureProvider(providerID: .svn, revisions: [])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.setHistoryVisible(true)
        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil && !model.isLoading }

        XCTAssertNil(model.selectedRevisionID)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.patch)
        let diffs = await provider.log.diffRequests()
        XCTAssertTrue(diffs.isEmpty)
    }

    func testLeavingHistoryModeRestoresWorkingDiff() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.setHistoryVisible(true)
        model.open(try makeDirectory())
        try await waitUntil { model.patch?.text == "revision:a1b2c3d4:Sources/Revision.swift" }

        model.setHistoryVisible(false)
        try await waitUntil { model.selectedRevisionID == nil && model.selectedPath == "Sources/App.swift" && model.patch?.text == "working:Sources/App.swift" }
    }

    func testFileHistoryUsesEntryDiffAndKeepsItsOwnPath() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.showFileHistory(path: "Sources/Renamed.swift")
        try await waitUntil {
            model.historyFilePath == "Sources/Renamed.swift"
                && model.selectedRevisionID == "f2e3d4c5"
                && model.selectedPath == "Sources/OldName.swift"
                && model.patch?.text == "file-revision:f2e3d4c5:Sources/OldName.swift"
        }

        XCTAssertEqual(model.historyRevisions.map(\.id), ["f2e3d4c5", "a1b2c3d4"])
        XCTAssertEqual(model.revisionFiles.map(\.path), ["Sources/OldName.swift"])
        let fileDiffs = await provider.log.fileHistoryDiffRequests()
        XCTAssertEqual(fileDiffs.last?.path, "Sources/OldName.swift")

        let older = try XCTUnwrap(model.historyRevisions.last)
        model.selectRevision(older)
        try await waitUntil { model.selectedRevisionID == "a1b2c3d4" && model.patch?.text == "file-revision:a1b2c3d4:Sources/Renamed.swift" }
        let selectedDiffs = await provider.log.fileHistoryDiffRequests()
        XCTAssertEqual(selectedDiffs.last?.revision.id, "a1b2c3d4")
    }

    func testClearFileHistoryAndChangingSourceDropsFileScope() async throws {
        let git = WorkspaceFixtureProvider()
        let svn = WorkspaceFixtureProvider(providerID: .svn)
        let model = WorkspaceModel(service: RepositoryService(providers: [git, svn]))

        model.open(try makeDirectory())
        try await waitUntil { model.workspace?.bindings.count == 2 }
        model.showFileHistory(path: "Sources/App.swift")
        try await waitUntil { model.historyFilePath == "Sources/App.swift" && !model.historyFileEntries.isEmpty }
        model.clearFileHistory()
        try await waitUntil { model.historyFilePath == nil && model.selectedRevisionID != nil }

        model.showFileHistory(path: "Sources/App.swift")
        try await waitUntil { model.historyFilePath != nil }
        let svnBinding = try XCTUnwrap(model.workspace?.bindings.first(where: { $0.providerID == .svn }))
        model.selectBinding(svnBinding)
        try await waitUntil { model.selectedBindingID == svnBinding.id && model.historyFilePath == nil }
    }

    func testLateFileHistoryResponseCannotReplaceNewerFile() async throws {
        let provider = WorkspaceFixtureProvider(fileHistoryDelays: ["Sources/Old.swift": 180_000_000, "Sources/New.swift": 20_000_000])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.showFileHistory(path: "Sources/Old.swift")
        try await waitForFileHistoryStart("Sources/Old.swift", log: provider.log)
        model.showFileHistory(path: "Sources/New.swift")
        try await waitUntil { model.historyFilePath == "Sources/New.swift" && model.patch?.text == "file-revision:f2e3d4c5:Sources/New.swift" }
        try await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertEqual(model.historyFilePath, "Sources/New.swift")
        XCTAssertEqual(model.patch?.text, "file-revision:f2e3d4c5:Sources/New.swift")
    }

    func testRefreshAndUpdateKeepFileHistoryScope() async throws {
        let log = WorkspaceInvocationLog()
        let provider = WorkspaceFixtureProvider(operationDelay: 20_000_000, log: log)
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.showFileHistory(path: "Sources/App.swift")
        try await waitUntil { model.historyFilePath == "Sources/App.swift" && model.patch != nil }
        model.refresh()
        try await waitUntil { model.historyFilePath == "Sources/App.swift" && model.patch?.text == "file-revision:f2e3d4c5:Sources/App.swift" && !model.isLoading }

        let binding = try XCTUnwrap(model.selectedBinding)
        model.performOperation(.update, on: binding)
        try await waitUntil { model.operationResult != nil && !model.isOperationInProgress }
        XCTAssertEqual(model.historyFilePath, "Sources/App.swift")
        XCTAssertEqual(model.patch?.text, "file-revision:f2e3d4c5:Sources/App.swift")
    }

    func testFileHistoryAnchorDoesNotReplaceRepositoryReferenceAndClearRestoresRepositoryScope() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))
        let branch = "feature/demo"

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.selectHistoryReference(branch)
        try await waitUntil { model.historyReference == branch && model.selectedRevisionID != nil }
        model.showFileHistory(path: "Sources/OldName.swift", reference: "f2e3d4c5")
        try await waitUntil { model.historyFileReference == "f2e3d4c5" && !model.historyFileEntries.isEmpty }

        XCTAssertEqual(model.historyReference, branch)
        model.clearFileHistory()
        try await waitUntil { model.historyFilePath == nil && model.selectedRevisionID != nil }
        XCTAssertNil(model.historyFileReference)
        XCTAssertEqual(model.historyReference, branch)
    }

    func testLeavingHistoryWithFileScopeReturnsToWorkingDiffAndRefreshDoesNotReloadFileHistory() async throws {
        let provider = WorkspaceFixtureProvider()
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.showFileHistory(path: "Sources/App.swift")
        try await waitUntil { model.historyFilePath != nil && model.patch?.text == "file-revision:f2e3d4c5:Sources/App.swift" }
        model.setHistoryVisible(false)
        try await waitUntil { model.historyFilePath == nil && model.patch?.text == "working:Sources/App.swift" }

        model.refresh()
        try await waitUntil { !model.isLoading && model.historyFilePath == nil && model.patch?.text == "working:Sources/App.swift" }
        let fileHistoryCalls = await provider.log.fileHistoryRequests()
        XCTAssertEqual(fileHistoryCalls.filter { $0 == "Sources/App.swift" }.count, 1)
    }

    func testFailedFileHistoryShowsFailureInsteadOfEmptyHistoryMessage() async throws {
        let provider = WorkspaceFixtureProvider(fileHistoryFailures: ["Sources/Unavailable.swift"])
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.snapshot != nil }
        model.showFileHistory(path: "Sources/Unavailable.swift")
        try await waitUntil { !model.isLoading && model.historyFilePath == "Sources/Unavailable.swift" && !model.historyIssues.isEmpty }

        XCTAssertTrue(model.historyFileEntries.isEmpty)
        XCTAssertNil(model.historySyncStatus)
        XCTAssertNil(model.patch)
        XCTAssertTrue(model.historyIssues.joined(separator: "\n").contains("文件历史："))
    }

    func testOperationLocksToOneBindingAndRefreshesAllBindingsAfterCompletion() async throws {
        let gitLog = WorkspaceInvocationLog()
        let svnLog = WorkspaceInvocationLog()
        let git = WorkspaceFixtureProvider(operationDelay: 120_000_000, log: gitLog)
        let svn = WorkspaceFixtureProvider(providerID: .svn, log: svnLog)
        let model = WorkspaceModel(service: RepositoryService(providers: [git, svn]))

        model.open(try makeDirectory())
        try await waitUntil { model.workspace?.bindings.count == 2 && model.snapshot != nil }
        let gitBinding = try XCTUnwrap(model.workspace?.bindings.first(where: { $0.providerID == .git }))
        let svnBinding = try XCTUnwrap(model.workspace?.bindings.first(where: { $0.providerID == .svn }))

        model.performOperation(.update, on: gitBinding)
        try await waitUntil { model.isOperationInProgress }
        model.performOperation(.update, on: svnBinding)
        model.selectBinding(svnBinding)
        XCTAssertEqual(model.selectedBindingID, gitBinding.id, "写操作期间不应切换来源")

        try await waitUntil { model.operationResult != nil && !model.isOperationInProgress }
        let gitOperations = await gitLog.operations()
        let svnOperations = await svnLog.operations()
        XCTAssertEqual(gitOperations.map(\.0), [.update])
        XCTAssertTrue(svnOperations.isEmpty, "双版本控制目录一次只能更新一个目标")
        XCTAssertNotNil(model.snapshots[gitBinding.id])
        XCTAssertNotNil(model.snapshots[svnBinding.id], "服务完成后应刷新所有已识别绑定")
    }

    func testCancellingOperationKeepsSheetStateLockedUntilRefreshedSnapshotReturns() async throws {
        let log = WorkspaceInvocationLog()
        let provider = WorkspaceFixtureProvider(operationDelay: 600_000_000, log: log)
        let model = WorkspaceModel(service: RepositoryService(providers: [provider]))

        model.open(try makeDirectory())
        try await waitUntil { model.selectedBinding != nil && model.snapshot != nil }
        let binding = try XCTUnwrap(model.selectedBinding)
        model.performOperation(.update, on: binding)
        try await waitUntil { model.isOperating }
        try await waitForOperationStart(.update, log: log)

        model.cancelOperation()
        XCTAssertTrue(model.isOperating, "请求取消后仍须等待服务层完成状态核对")
        XCTAssertTrue(model.isOperationCancelling)
        try await waitUntil {
            guard let outcome = model.operationResult?.outcome else { return false }
            if case .cancelled = outcome { return !model.isOperating }
            return false
        }

        let operations = await log.operations()
        XCTAssertEqual(operations.map(\.0), [.update])
        XCTAssertNotNil(model.snapshots[binding.id], "取消后仍应使用重新读取的工作区快照")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rephub-ui-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(
        timeout: UInt64 = 1_500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待 WorkspaceModel 完成异步读取超时")
    }

    private func waitForDiffStart(_ path: String, log: WorkspaceInvocationLog) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await log.didStartDiff(path)) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await log.didStartDiff(path)
        XCTAssertTrue(started, "等待迟到响应开始超时")
    }

    private func waitForDetectionStart(_ directory: URL, log: WorkspaceInvocationLog) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await log.didStartDetection(at: directory.standardizedFileURL.path)) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await log.didStartDetection(at: directory.standardizedFileURL.path)
        XCTAssertTrue(started, "等待打开仓库识别开始超时")
    }

    private func waitForOperationStart(_ operation: RepositoryOperationKind, log: WorkspaceInvocationLog) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await log.didStartOperation(operation)) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await log.didStartOperation(operation)
        XCTAssertTrue(started, "等待版本控制操作开始超时")
    }

    private func waitForFileHistoryStart(_ path: String, log: WorkspaceInvocationLog) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await log.didStartFileHistory(path)) && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await log.didStartFileHistory(path)
        XCTAssertTrue(started, "等待文件历史读取开始超时")
    }
}

private struct WorkspaceFixtureProvider: RepositoryOperationProvider, RepositoryHistoryProvider {
    struct DiffRequest: Sendable {
        let path: String?
        let revision: String?
    }

    let id: ProviderID
    var displayName: String { id == .svn ? "SVN 测试适配器" : "Git 测试适配器" }
    let log: WorkspaceInvocationLog
    let delays: [String: UInt64]
    let revisions: [Revision]
    let operationDelay: UInt64
    let fileHistoryDelays: [String: UInt64]
    let fileHistoryFailures: Set<String>
    let detectsRepository: Bool
    let detectError: Bool
    let detectDelays: [String: UInt64]
    let unmanagedDirectories: Set<String>

    init(providerID: ProviderID = .git, revisions: [Revision]? = nil, delays: [String: UInt64] = [:], fileHistoryDelays: [String: UInt64] = [:], fileHistoryFailures: Set<String> = [], operationDelay: UInt64 = 0, detectsRepository: Bool = true, detectError: Bool = false, detectDelays: [String: UInt64] = [:], unmanagedDirectories: Set<String> = [], log: WorkspaceInvocationLog = WorkspaceInvocationLog()) {
        self.id = providerID
        self.revisions = revisions ?? [Revision(id: providerID == .svn ? "r1" : "a1b2c3d4", author: "zym", date: .distantPast, message: "feat: 历史读取")]
        self.delays = delays
        self.operationDelay = operationDelay
        self.fileHistoryDelays = fileHistoryDelays
        self.fileHistoryFailures = fileHistoryFailures
        self.detectsRepository = detectsRepository
        self.detectError = detectError
        self.detectDelays = detectDelays
        self.unmanagedDirectories = unmanagedDirectories
        self.log = log
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? {
        await log.recordDetectionStart(at: directory.standardizedFileURL.path)
        if let delay = detectDelays[directory.standardizedFileURL.path] {
            await uncancellableDelay(nanoseconds: delay)
        }
        if detectError { throw VersionControlError.toolUnavailable("测试检测失败") }
        guard detectsRepository, !unmanagedDirectories.contains(directory.standardizedFileURL.path) else { return nil }
        return RepositoryBinding(
            providerID: id,
            providerName: displayName,
            root: directory,
            currentBranch: id == .git ? "main" : "",
            capabilities: id == .git ? [.status, .diff, .history, .branches, .commitGraph, .fetch, .update, .fileHistory, .synchronization] : [.status, .diff, .history, .update, .fileHistory, .synchronization]
        )
    }

    func perform(
        _ operation: RepositoryOperationKind,
        in binding: RepositoryBinding,
        progress: @escaping RepositoryOperationProgressHandler
    ) async throws -> RepositoryOperationResult {
        await log.recordOperation(operation, bindingID: binding.id)
        await progress(RepositoryOperationProgress("测试：正在更新 \(binding.providerName)…"))
        if operationDelay > 0 { try await Task.sleep(nanoseconds: operationDelay) }
        return RepositoryOperationResult(
            kind: operation,
            bindingID: binding.id,
            outcome: .succeeded,
            summary: "测试更新完成",
            changedFiles: [FileChange(path: "Sources/Updated.swift", kind: .modified)]
        )
    }

    func status(in binding: RepositoryBinding) async throws -> [FileChange] {
        [
            FileChange(path: "scratch.swift", kind: .untracked),
            FileChange(path: "README.md", kind: .modified),
            FileChange(path: "Sources/App.swift", kind: .modified),
            FileChange(path: "Sources/Old.swift", kind: .modified),
            FileChange(path: "Sources/New.swift", kind: .modified),
        ]
    }

    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] {
        await log.recordHistory(reference)
        return revisions
    }

    func fileHistory(in binding: RepositoryBinding, path: String, limit: Int, reference: String?) async throws -> [FileHistoryEntry] {
        await log.recordFileHistoryStart(path)
        if let delay = fileHistoryDelays[path] { await uncancellableDelay(nanoseconds: delay) }
        if fileHistoryFailures.contains(path) {
            throw VersionControlError.unsupported("测试文件历史不可用")
        }
        await log.recordFileHistory(path)
        return [
            FileHistoryEntry(revision: Revision(id: "f2e3d4c5", author: "zym", date: .distantPast, message: "rename history"), path: path == "Sources/Renamed.swift" ? "Sources/OldName.swift" : path, pegRevision: "f2e3d4c5"),
            FileHistoryEntry(revision: Revision(id: "a1b2c3d4", author: "zym", date: .distantPast, message: "older history"), path: path, pegRevision: "a1b2c3d4"),
        ]
    }

    func fileHistoryDiff(in binding: RepositoryBinding, entry: FileHistoryEntry) async throws -> RepositoryPatch {
        await log.recordFileHistoryDiff(entry)
        return RepositoryPatch(text: "file-revision:\(entry.revision.id):\(entry.path)")
    }

    func synchronization(in binding: RepositoryBinding, revisions: [Revision], path: String?) async throws -> RepositorySyncStatus {
        RepositorySyncStatus(incomingCount: 1, outgoingCount: id == .git ? 2 : nil,
                             states: Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, .incoming) }),
                             summary: "测试同步状态")
    }

    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }

    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] {
        await log.recordChangedFiles(revision)
        return [
            FileChange(path: "README.md", kind: .modified),
            FileChange(path: "Sources/Revision.swift", kind: .modified),
        ]
    }

    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        await log.recordDiffStart(path: path, revision: revision)
        if let path, let delay = delays[path] {
            // 不观察任务取消，模拟外部读取已发出后迟到返回。
            await uncancellableDelay(nanoseconds: delay)
        }
        await log.recordDiff(path: path, revision: revision)
        let label = revision.map { "revision:\($0)" } ?? "working"
        return RepositoryPatch(text: "\(label):\(path ?? "all")")
    }

    private func uncancellableDelay(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }
}

private actor WorkspaceInvocationLog {
    private var changedFiles: [String] = []
    private var diffs: [WorkspaceFixtureProvider.DiffRequest] = []
    private var startedDiffs: [WorkspaceFixtureProvider.DiffRequest] = []
    private var history: [String?] = []
    private var performedOperations: [(RepositoryOperationKind, String)] = []
    private var fileHistory: [String] = []
    private var startedFileHistory: [String] = []
    private var fileHistoryDiffs: [FileHistoryEntry] = []
    private var detectionStarts: [String] = []

    func recordChangedFiles(_ revision: String) { changedFiles.append(revision) }
    func recordHistory(_ reference: String?) { history.append(reference) }
    func recordDiffStart(path: String?, revision: String?) { startedDiffs.append(.init(path: path, revision: revision)) }
    func recordDiff(path: String?, revision: String?) { diffs.append(.init(path: path, revision: revision)) }
    func recordOperation(_ operation: RepositoryOperationKind, bindingID: String) { performedOperations.append((operation, bindingID)) }
    func recordFileHistoryStart(_ path: String) { startedFileHistory.append(path) }
    func recordFileHistory(_ path: String) { fileHistory.append(path) }
    func recordFileHistoryDiff(_ entry: FileHistoryEntry) { fileHistoryDiffs.append(entry) }
    func recordDetectionStart(at path: String) { detectionStarts.append(path) }
    func changedFileRequests() -> [String] { changedFiles }
    func historyReferences() -> [String?] { history }
    func didStartDiff(_ path: String) -> Bool { startedDiffs.contains { $0.path == path } }
    func diffRequests() -> [WorkspaceFixtureProvider.DiffRequest] { diffs }
    func operations() -> [(RepositoryOperationKind, String)] { performedOperations }
    func didStartFileHistory(_ path: String) -> Bool { startedFileHistory.contains(path) }
    func fileHistoryRequests() -> [String] { fileHistory }
    func fileHistoryDiffRequests() -> [FileHistoryEntry] { fileHistoryDiffs }
    func didStartDetection(at path: String) -> Bool { detectionStarts.contains(path) }
    func didStartOperation(_ operation: RepositoryOperationKind) -> Bool {
        performedOperations.contains { $0.0.rawValue == operation.rawValue }
    }
}
