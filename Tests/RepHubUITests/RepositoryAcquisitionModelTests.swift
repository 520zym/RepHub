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

    func testSuccessfulSVNBrowseRecordsRootAddressAndCredentials() async throws {
        let secrets = MemoryRepositoryCredentialStore()
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: secrets)
        let provider = AcquisitionFixtureProvider { location in
            RemoteDirectoryListing(url: location.url, entries: [])
        }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.selectProvider(.svn)
        model.remoteURL = "https://example.test:8443/svn/root"
        model.username = "zym"
        model.password = "secret"
        model.browseRoot()
        var credentials: RepositoryCredentials?
        for _ in 0..<25 {
            credentials = try await history.credentials(for: "https://example.test:8443/svn/another-path")
            if credentials != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(history.entries(for: .svn).map(\.url), ["https://example.test:8443/svn/root"])
        XCTAssertEqual(credentials?.username, "zym")
        XCTAssertEqual(credentials?.password, "secret")
    }

    func testChangingSVNServerDoesNotLetLateCredentialFillOverwriteManualInput() async throws {
        let secrets = MemoryRepositoryCredentialStore()
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: secrets)
        try await history.remember(RepositoryCredentials(username: "old", password: "old-password"),
                                   for: "https://old.example.test/svn/root")
        try await history.remember(RepositoryCredentials(username: "new", password: "new-password"),
                                   for: "https://new.example.test/svn/root")
        let provider = AcquisitionFixtureProvider { location in RemoteDirectoryListing(url: location.url, entries: []) }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.selectProvider(.svn)
        model.setRemoteURLFromUser("https://old.example.test/svn/root")
        model.setRemoteURLFromUser("https://new.example.test/svn/root")
        model.setUsernameFromUser("manual")
        model.setPasswordFromUser("manual-password")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(model.username, "manual")
        XCTAssertEqual(model.password, "manual-password")
        XCTAssertFalse(model.isLoadingSavedCredentials)
    }

    func testEditingPathOnSameServerKeepsPendingAutofill() async throws {
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: MemoryRepositoryCredentialStore())
        try await history.remember(RepositoryCredentials(username: "zym", password: "saved-password"),
                                   for: "https://same.example.test/svn/first")
        let provider = AcquisitionFixtureProvider { location in RemoteDirectoryListing(url: location.url, entries: []) }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.selectProvider(.svn)
        model.setRemoteURLFromUser("https://same.example.test/svn/first")
        model.setRemoteURLFromUser("https://same.example.test/svn/second")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(model.username, "zym")
        XCTAssertEqual(model.password, "saved-password")
        XCTAssertFalse(model.isLoadingSavedCredentials)
    }

    func testForgettingAccountInvalidatesLateCredentialRead() async throws {
        let secrets = DelayedCredentialStore()
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: secrets)
        try await history.remember(RepositoryCredentials(username: "zym", password: "saved-password"),
                                   for: "https://forget.example.test/svn/root")
        await secrets.delayReads()
        let provider = AcquisitionFixtureProvider { location in RemoteDirectoryListing(url: location.url, entries: []) }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.selectProvider(.svn)
        model.setRemoteURLFromUser("https://forget.example.test/svn/root")
        await secrets.waitUntilReadStarted()
        model.removeSavedAccount(try XCTUnwrap(history.accounts.first))
        await secrets.releaseRead()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.username.isEmpty)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertFalse(model.isLoadingSavedCredentials)
    }

    func testFailedBrowseDoesNotReplaceSavedCredentials() async throws {
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: MemoryRepositoryCredentialStore())
        try await history.remember(RepositoryCredentials(username: "old", password: "old-password"),
                                   for: "https://failure.example.test/svn/root")
        let provider = AcquisitionFixtureProvider { _ in throw VersionControlError.unsupported("fixture failure") }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.selectProvider(.svn)
        model.remoteURL = "https://failure.example.test/svn/root"
        model.username = "new"
        model.password = "new-password"
        model.browseRoot()
        try await Task.sleep(for: .milliseconds(80))

        let retained = try await history.credentials(for: "https://failure.example.test/svn/other")
        XCTAssertEqual(retained?.username, "old")
        XCTAssertEqual(retained?.password, "old-password")
    }

    func testAddressHistoryRestoresFromPersistentDefaults() {
        let suite = "RepHub.RepositoryAcquisitionModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RemoteRepositoryHistoryStore(defaults: defaults, secrets: MemoryRepositoryCredentialStore())
        first.record(providerID: .git, url: "https://example.test/team/repo.git")
        let restored = RemoteRepositoryHistoryStore(defaults: defaults, secrets: MemoryRepositoryCredentialStore())

        XCTAssertEqual(restored.entries(for: .git).map(\.url), ["https://example.test/team/repo.git"])
    }

    func testClosingAndReopeningRehydratesSavedCredentials() async throws {
        let history = RemoteRepositoryHistoryStore(defaults: nil, secrets: MemoryRepositoryCredentialStore())
        try await history.remember(RepositoryCredentials(username: "zym", password: "saved-password"),
                                   for: "https://reopen.example.test/svn/root")
        let provider = AcquisitionFixtureProvider { location in RemoteDirectoryListing(url: location.url, entries: []) }
        let model = RepositoryAcquisitionModel(service: RepositoryService(providers: [provider]), remoteHistory: history)
        await prepare(model)
        model.setRemoteURLFromUser("https://reopen.example.test/svn/root")
        try await Task.sleep(for: .milliseconds(400))
        model.endSession()
        XCTAssertTrue(model.password.isEmpty)
        model.prepare()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(model.username, "zym")
        XCTAssertEqual(model.password, "saved-password")
    }

    private func prepare(_ model: RepositoryAcquisitionModel) async {
        model.prepare()
        for _ in 0..<16 { await Task.yield() }
    }

    func testSuccessfulGitAcquisitionRecordsAddressAndReopensConnectionPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepHub-GitHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = RemoteRepositoryHistoryStore()
        let model = RepositoryAcquisitionModel(
            service: RepositoryService(providers: [GitAcquisitionFixtureProvider(createsWorkingCopy: true)]),
            remoteHistory: history)
        await prepare(model)
        let source = "https://example.test/team/new-repository.git"
        model.setRemoteURLFromUser(source)
        XCTAssertEqual(model.directoryName, "new-repository")
        model.setDirectoryName("custom-name")
        model.selectRecentRemote(RemoteRepositoryHistoryEntry(providerID: .git, url: source, lastUsedAt: Date()))
        XCTAssertEqual(model.directoryName, "custom-name")
        model.destinationParent = root
        let finished = expectation(description: "Git acquisition finishes")
        model.acquire { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(history.entries(for: .git).map(\.url), [source])

        model.endSession()
        model.prepare()
        XCTAssertEqual(model.wizardStep, .connection)
        XCTAssertFalse(model.transferHasFinished)
        XCTAssertEqual(model.recentRemoteEntries.map(\.url), [source])
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

private actor DelayedCredentialStore: RepositoryCredentialStore {
    private var values: [String: String] = [:]
    private var shouldDelayReads = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<Void, Never>?

    func delayReads() { shouldDelayReads = true }

    func password(forServer server: String, username: String) async throws -> String? {
        let value = values[key(server, username)]
        if shouldDelayReads {
            let waiters = readWaiters
            readWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { readContinuation = $0 }
        }
        return value
    }

    func save(_ credentials: RepositoryCredentials, forServer server: String) async throws {
        values[key(server, credentials.username)] = credentials.password
    }

    func remove(forServer server: String, username: String) async throws {
        values.removeValue(forKey: key(server, username))
    }

    func waitUntilReadStarted() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    private func key(_ server: String, _ username: String) -> String { server + "\u{0}" + username }
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
    var createsWorkingCopy = false
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
        if createsWorkingCopy {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            return
        }
        throw VersionControlError.unsupported("测试不执行获取。")
    }
}
