import XCTest
@testable import SVNAdapter
import VersionControlCore
import Security

final class KeychainRepositoryCredentialStoreTests: XCTestCase {
    func testSaveUsesCollisionFreeAccountAndStoresSecretOnlyAsData() async throws {
        let spy = KeychainSpy()
        let store = KeychainRepositoryCredentialStore(
            service: "com.zym.RepHub.tests.credentials",
            client: spy.client
        )

        try await store.save(
            RepositoryCredentials(username: "alice", password: "fixture-password"),
            forServer: "https://svn.example.test/team"
        )

        XCTAssertEqual(spy.updateCalls, 1)
        XCTAssertEqual(spy.addCalls, 1)
        XCTAssertEqual(spy.addedItem?.service, "com.zym.RepHub.tests.credentials")
        XCTAssertNotEqual(spy.addedItem?.account, "https://svn.example.test/team")
        XCTAssertFalse(spy.addedItem?.account.contains("fixture-password") ?? true)
        XCTAssertEqual(spy.addedData?.count, Data("fixture-password".utf8).count)
        XCTAssertNotEqual(
            KeychainRepositoryCredentialStore.account(server: "a:b", username: "c"),
            KeychainRepositoryCredentialStore.account(server: "a", username: "b:c")
        )
    }

    func testReadMissingAndDeleteMissingAreBothSafe() async throws {
        let spy = KeychainSpy()
        spy.readResult = (errSecItemNotFound, nil)
        spy.deleteStatus = errSecItemNotFound
        let store = KeychainRepositoryCredentialStore(service: "test", client: spy.client)

        let password = try await store.password(forServer: "https://svn.example.test", username: "alice")
        try await store.remove(forServer: "https://svn.example.test", username: "alice")

        XCTAssertNil(password)
        XCTAssertEqual(spy.deleteCalls, 1)
    }

    func testKeychainAccessDenialDoesNotAddOrExposePassword() async throws {
        let readSpy = KeychainSpy()
        readSpy.readResult = (errSecAuthFailed, nil)
        let readStore = KeychainRepositoryCredentialStore(service: "test", client: readSpy.client)

        do {
            _ = try await readStore.password(forServer: "https://svn.example.test", username: "alice")
            XCTFail("应抛出钥匙串访问错误")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("fixture-password"))
        }

        let saveSpy = KeychainSpy()
        saveSpy.updateStatus = errSecInteractionNotAllowed
        let saveStore = KeychainRepositoryCredentialStore(service: "test", client: saveSpy.client)

        do {
            try await saveStore.save(
                RepositoryCredentials(username: "alice", password: "fixture-password"),
                forServer: "https://svn.example.test"
            )
            XCTFail("应抛出钥匙串访问错误")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("fixture-password"))
        }
        XCTAssertEqual(saveSpy.updateCalls, 1)
        XCTAssertEqual(saveSpy.addCalls, 0)
    }
}

private final class KeychainSpy: @unchecked Sendable {
    var updateStatus: OSStatus = errSecItemNotFound
    var deleteStatus: OSStatus = errSecSuccess
    var readResult: (status: OSStatus, data: Data?) = (errSecItemNotFound, nil)
    var updateCalls = 0
    var addCalls = 0
    var deleteCalls = 0
    var addedItem: KeychainRepositoryCredentialItem?
    var addedData: Data?

    var client: KeychainRepositoryCredentialStoreClient {
        KeychainRepositoryCredentialStoreClient(
            read: { [self] _ in readResult },
            update: { [self] _, _ in
                updateCalls += 1
                return updateStatus
            },
            add: { [self] item, data in
                addCalls += 1
                addedItem = item
                addedData = data
                return errSecSuccess
            },
            delete: { [self] _ in
                deleteCalls += 1
                return deleteStatus
            }
        )
    }
}
