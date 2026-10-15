import Foundation
import XCTest
@testable import RepHubUI
import RepositoryApplication
import VersionControlCore

@MainActor
final class RepositoryAcquisitionModelTests: XCTestCase {
    func testChangingRemoteLocationPreventsLateBrowseFromRestoringOldTree() async throws {
        let gate = LateBrowseGate()
        let provider = AcquisitionFixtureProvider { location in try await gate.waitForListing(at: location.url) }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]))
        model.selectProvider(.svn)
        model.remoteURL = "https://example.test/svn/old"
        model.browseRoot()
        await gate.waitUntilStarted()

        model.remoteURL = "https://example.test/svn/new"
        model.remoteLocationChanged()
        await gate.releaseOldListing()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(model.listings.isEmpty)
        XCTAssertNil(model.rootListingURL)
        XCTAssertNil(model.selectedRemoteURL)
    }

    func testSuggestedDirectoryNameDecodesAndHandEditedNameSurvivesDirectoryChange() async throws {
        let provider = AcquisitionFixtureProvider { location in
            RemoteDirectoryListing(url: location.url, entries: [])
        }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]))
        model.selectProvider(.svn)
        model.selectDirectory("https://example.test/svn/%E7%A0%94%E5%8F%91")
        XCTAssertEqual(model.directoryName, "研发")

        model.setDirectoryName("我自己的目录")
        model.selectDirectory("https://example.test/svn/%E6%96%B0%E7%89%88%E6%9C%AC")
        XCTAssertEqual(model.directoryName, "我自己的目录")
    }

    func testSVNWizardHidesPasswordWhenEnteringBrowseStep() async throws {
        let provider = AcquisitionFixtureProvider { location in
            RemoteDirectoryListing(url: location.url, entries: [])
        }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]))
        model.prepare()
        for _ in 0..<8 { await Task.yield() }
        model.remoteURL = "https://example.test/svn/root"
        model.togglePasswordVisibility()
        XCTAssertTrue(model.isPasswordVisible)

        model.advanceWizard()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(model.wizardStep, .browse)
        XCTAssertFalse(model.isPasswordVisible)
        XCTAssertEqual(model.rootListingURL, "https://example.test/svn/root")
    }

    func testGitWizardSkipsBrowseStepAndRequiresDestination() async throws {
        let provider = GitAcquisitionFixtureProvider()
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]))
        model.prepare()
        for _ in 0..<8 { await Task.yield() }
        model.remoteURL = "https://example.test/team/repo.git"

        model.advanceWizard()
        XCTAssertEqual(model.wizardStep, .destination)
        model.advanceWizard()
        XCTAssertEqual(model.wizardStep, .destination)
        XCTAssertEqual(model.errorMessage, "请选择本地保存位置。")
    }

    func testExpandingDirectoryDoesNotChangeCheckoutSelection() async throws {
        let provider = AcquisitionFixtureProvider { location in
            RemoteDirectoryListing(url: location.url, entries: [])
        }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]))
        model.selectProvider(.svn)
        let selectedURL = "https://example.test/svn/root"
        model.selectDirectory(selectedURL)
        let child = RemoteDirectoryEntry(
            name: "child",
            url: "https://example.test/svn/root/child",
            isDirectory: true
        )

        model.toggleDirectory(child)

        XCTAssertEqual(model.selectedRemoteURL, selectedURL)
        XCTAssertEqual(model.directoryName, "root")
    }
}

private actor LateBrowseGate {
    private var continuation: CheckedContinuation<RemoteDirectoryListing, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func waitForListing(at url: String) async throws -> RemoteDirectoryListing {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in startWaiters.append(continuation) }
    }

    func releaseOldListing() {
        continuation?.resume(returning: RemoteDirectoryListing(
            url: "https://example.test/svn/old",
            entries: [RemoteDirectoryEntry(name: "old", url: "https://example.test/svn/old/old", isDirectory: true)]
        ))
        continuation = nil
    }
}

private struct AcquisitionFixtureProvider: RepositoryAcquisitionProvider {
    let browse: @Sendable (RemoteRepositoryLocation) async throws -> RemoteDirectoryListing

    var id: ProviderID { .svn }
    var displayName: String { "Fixture SVN" }
    var acquisitionOption: RepositoryAcquisitionOption {
        RepositoryAcquisitionOption(providerID: .svn, title: "SVN", actionTitle: "检出", supportsBrowsing: true, supportsCredentials: true)
    }

    func detect(at directory: URL) async throws -> RepositoryBinding? { nil }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch {
        RepositoryPatch(text: "")
    }
    func browseRemote(_ location: RemoteRepositoryLocation) async throws -> RemoteDirectoryListing {
        try await browse(location)
    }
    func acquire(_ location: RemoteRepositoryLocation, to destination: URL,
                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        throw VersionControlError.unsupported("测试不执行获取。")
    }
}

private struct GitAcquisitionFixtureProvider: RepositoryAcquisitionProvider {
    var id: ProviderID { .git }
    var displayName: String { "Fixture Git" }
    var acquisitionOption: RepositoryAcquisitionOption {
        RepositoryAcquisitionOption(providerID: .git, title: "Git", actionTitle: "克隆")
    }
    func detect(at directory: URL) async throws -> RepositoryBinding? { nil }
    func status(in binding: RepositoryBinding) async throws -> [FileChange] { [] }
    func history(in binding: RepositoryBinding, limit: Int, reference: String?) async throws -> [Revision] { [] }
    func branches(in binding: RepositoryBinding) async throws -> [BranchReference] { [] }
    func changedFiles(in binding: RepositoryBinding, revision: String) async throws -> [FileChange] { [] }
    func diff(in binding: RepositoryBinding, path: String?, revision: String?) async throws -> RepositoryPatch { RepositoryPatch(text: "") }
    func acquire(_ location: RemoteRepositoryLocation, to destination: URL,
                 progress: @escaping RepositoryOperationProgressHandler) async throws {
        throw VersionControlError.unsupported("测试不执行获取。")
    }
}
