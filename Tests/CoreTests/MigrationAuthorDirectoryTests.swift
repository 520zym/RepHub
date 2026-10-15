import Foundation
import RepositoryApplication
import VersionControlCore
import XCTest

@MainActor
final class MigrationAuthorDirectoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var key: String!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "RepHubTests.MigrationAuthorDirectory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        key = "directory"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        key = nil
        suite = nil
        super.tearDown()
    }

    func testResolveUsesSourceNameForPlaceholderAndDefaultSuffix() throws {
        let store = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        try store.addEmailSuffix("efb.example.com", makeDefault: true)
        let result = store.resolve(authors: ["ZhangYiMing": .init(name: "ZhangYiMing", email: "svn-987@authors.invalid")], sourceURL: "https://user:secret@svn.example.com:8443/svn/a")
        XCTAssertEqual(result["ZhangYiMing"], .init(name: "ZhangYiMing", email: "ZhangYiMing@efb.example.com"))
    }

    func testMappingsAreSeparatedByServerAndCredentialsNeverPersisted() throws {
        let store = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        try store.save(authors: ["same": .init(name: "Git A", email: "a@example.com")], sourceURL: "https://alice:secret@svn.example.com:8443/svn/a")
        try store.save(authors: ["same": .init(name: "Git B", email: "b@example.com")], sourceURL: "https://svn.other.example.com:8443/svn/a")
        XCTAssertEqual(store.resolve(authors: ["same": .init(name: "same", email: "")], sourceURL: "https://svn.example.com:8443/another")["same"]?.email, "a@example.com")
        XCTAssertEqual(store.resolve(authors: ["same": .init(name: "same", email: "")], sourceURL: "https://svn.other.example.com:8443/another")["same"]?.email, "b@example.com")
        XCTAssertFalse(String(data: defaults.data(forKey: key)!, encoding: .utf8)!.contains("secret"))
        XCTAssertFalse(String(data: defaults.data(forKey: key)!, encoding: .utf8)!.contains("alice"))
    }

    func testSaveMergesAuthorsAlreadyKnownForTheServer() throws {
        let store = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        let source = "https://svn.example.com:8443/svn/repository"
        try store.save(authors: ["alice": .init(name: "Alice", email: "alice@example.com")], sourceURL: source)
        try store.save(authors: ["bob": .init(name: "Bob", email: "bob@example.com")], sourceURL: source)
        let resolved = store.resolve(authors: ["alice": .init(name: "alice", email: ""), "bob": .init(name: "bob", email: "")], sourceURL: source)
        XCTAssertEqual(resolved["alice"]?.email, "alice@example.com")
        XCTAssertEqual(resolved["bob"]?.email, "bob@example.com")
    }

    func testSuffixPersistAndBulkReplacementCanBeLimitedToPlaceholder() throws {
        let source = "file:///tmp/svn-copy"
        let store = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        try store.save(authors: [
            "alice": .init(name: "Alice", email: "alice@authors.invalid"),
            "bob": .init(name: "Bob", email: "bob@custom.example.com")
        ], sourceURL: source)
        try store.addEmailSuffix("company.example.com", makeDefault: true)
        XCTAssertEqual(try store.applyDefaultSuffixToSavedAuthors(onlyPlaceholder: true), 1)
        let reloaded = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        let resolved = reloaded.resolve(authors: ["alice": .init(name: "alice", email: ""), "bob": .init(name: "bob", email: "")], sourceURL: source)
        XCTAssertEqual(resolved["alice"]?.email, "alice@company.example.com")
        XCTAssertEqual(resolved["bob"]?.email, "bob@custom.example.com")
    }

    func testInvalidAuthorFailsWithoutReplacingPreviousStoredValue() throws {
        let store = MigrationAuthorDirectoryStore(defaults: defaults, persistenceKey: key)
        let source = "https://svn.example.com/repository"
        try store.save(authors: ["alice": .init(name: "Alice", email: "alice@example.com")], sourceURL: source)
        XCTAssertThrowsError(try store.update(source: "alice", sourceURL: source, author: .init(name: "Alice", email: "not-an-email")))
        XCTAssertEqual(store.resolve(authors: ["alice": .init(name: "alice", email: "")], sourceURL: source)["alice"]?.email, "alice@example.com")
        XCTAssertEqual(store.feedback?.kind, .error)
    }
}
