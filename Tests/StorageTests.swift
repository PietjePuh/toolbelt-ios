import XCTest
@testable import Toolbelt

private final class MemoryStore: KeyValueStore {
    var contents: [String: Data] = [:]
    func data(forKey key: String) -> Data? { contents[key] }
    func set(_ value: Data?, forKey key: String) { contents[key] = value }
}

final class SubscriptionStoreTests: XCTestCase {

    private func makeStore() -> (SubscriptionStore, MemoryStore) {
        let backing = MemoryStore()
        return (SubscriptionStore(store: backing, key: "test"), backing)
    }

    func testAddAndList() throws {
        let (store, _) = makeStore()
        try store.add(url: URL(string: "https://example.com/feed.xml")!, title: "Example", kind: .news)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all(kind: .news).first?.title, "Example")
        XCTAssertTrue(store.all(kind: .podcast).isEmpty)
    }

    func testSurvivesAReload() throws {
        let backing = MemoryStore()
        let first = SubscriptionStore(store: backing, key: "test")
        try first.add(url: URL(string: "https://example.com/feed.xml")!, title: "Example", kind: .podcast)

        let second = SubscriptionStore(store: backing, key: "test")
        XCTAssertEqual(second.all().count, 1)
        XCTAssertEqual(second.all().first?.kind, .podcast)
    }

    func testHTTPIsRefusedWhenItIsAddedNotWhenItIsFetched() throws {
        // The gateway is https-only, so an http feed would fail on every
        // refresh — long after the user forgot adding it.
        let (store, _) = makeStore()
        XCTAssertThrowsError(try store.add(url: URL(string: "http://example.com/feed.xml")!,
                                           title: "Insecure", kind: .news)) { err in
            XCTAssertEqual(err as? SubscriptionStore.StoreError, .insecureURL)
        }
        XCTAssertTrue(store.all().isEmpty)
    }

    func testNonWebSchemesAreRefused() {
        let (store, _) = makeStore()
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/f.xml"] {
            XCTAssertThrowsError(try store.add(url: URL(string: raw)!, title: "x", kind: .news),
                                 "\(raw) should be refused")
        }
    }

    func testDuplicateReportsTheExistingRow() throws {
        let (store, _) = makeStore()
        let original = try store.add(url: URL(string: "https://example.com/feed.xml")!,
                                     title: "Example", kind: .news)
        // Same feed, cosmetically different URL.
        XCTAssertThrowsError(try store.add(url: URL(string: "HTTPS://Example.com/feed.xml#top")!,
                                           title: "Dup", kind: .news)) { err in
            guard case .duplicate(let existing)? = err as? SubscriptionStore.StoreError else {
                return XCTFail("expected .duplicate")
            }
            XCTAssertEqual(existing.id, original.id)
        }
        XCTAssertEqual(store.all().count, 1)
    }

    func testQueryStringDistinguishesFeeds() throws {
        // Plenty of sites serve every feed off one path: ?feed=rss vs ?feed=atom.
        let (store, _) = makeStore()
        try store.add(url: URL(string: "https://example.com/?feed=rss")!, title: "A", kind: .news)
        try store.add(url: URL(string: "https://example.com/?feed=atom")!, title: "B", kind: .news)
        XCTAssertEqual(store.all().count, 2)
    }

    func testTrailingSlashIsTheSameFeed() throws {
        let (store, _) = makeStore()
        try store.add(url: URL(string: "https://example.com/feed/")!, title: "A", kind: .news)
        XCTAssertThrowsError(try store.add(url: URL(string: "https://example.com/feed")!,
                                           title: "B", kind: .news))
    }

    func testEmptyTitleFallsBackToTheHost() throws {
        let (store, _) = makeStore()
        let sub = try store.add(url: URL(string: "https://news.example.com/feed.xml")!,
                                title: "   ", kind: .news)
        XCTAssertEqual(sub.title, "news.example.com")
    }

    func testRemoveAndRename() throws {
        let (store, _) = makeStore()
        let sub = try store.add(url: URL(string: "https://example.com/f.xml")!, title: "A", kind: .news)
        try store.rename(id: sub.id, to: "Renamed")
        XCTAssertEqual(store.all().first?.title, "Renamed")
        try store.rename(id: sub.id, to: "   ")
        XCTAssertEqual(store.all().first?.title, "Renamed", "a blank rename is ignored")
        try store.remove(id: sub.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: - the property that matters

    func testCorruptDataIsReportedAndNeverOverwritten() {
        // The failure mode this prevents: a bad read presents as an empty list,
        // the next add writes it back, and the user's feeds are gone for good.
        let backing = MemoryStore()
        backing.contents["test"] = Data("{not json at all".utf8)

        let store = SubscriptionStore(store: backing, key: "test")
        XCTAssertTrue(store.isUnreadable)
        XCTAssertTrue(store.all().isEmpty)

        XCTAssertThrowsError(try store.add(url: URL(string: "https://example.com/f.xml")!,
                                           title: "New", kind: .news)) { err in
            XCTAssertEqual(err as? SubscriptionStore.StoreError, .unreadable)
        }
        XCTAssertEqual(backing.contents["test"], Data("{not json at all".utf8),
                       "the unreadable blob must still be there")
    }

    func testExplicitResetIsTheOnlyWayToDiscard() throws {
        let backing = MemoryStore()
        backing.contents["test"] = Data("garbage".utf8)
        let store = SubscriptionStore(store: backing, key: "test")
        XCTAssertTrue(store.isUnreadable)

        try store.resetAfterCorruption()
        XCTAssertFalse(store.isUnreadable)
        try store.add(url: URL(string: "https://example.com/f.xml")!, title: "New", kind: .news)
        XCTAssertEqual(store.all().count, 1)
    }

    func testAbsentStoreIsEmptyNotCorrupt() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isUnreadable, "never-saved is not the same as unreadable")
        XCTAssertTrue(store.all().isEmpty)
    }
}

/// In-memory stand-in for the Keychain. The real Keychain returns
/// `errSecMissingEntitlement` (-34018) to an UNSIGNED test host, and this
/// project builds unsigned on purpose, so exercising Apple's storage here is
/// not possible. What IS ours — named slots, trimming, refusing a blank
/// secret, replace-not-duplicate — is tested properly against this.
private final class MemorySecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var writeCount = 0

    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
        writeCount += 1
    }
    func read(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }
    func exists(account: String) -> Bool { read(account: account) != nil }
    @discardableResult func delete(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
        return true
    }
    var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.keys)
    }
}

final class SecretStoreTests: XCTestCase {

    func testRoundTrip() throws {
        let backend = MemorySecretBackend()
        let store = SecretStore(backend: backend)

        XCTAssertFalse(store.isSet(.tmdbKey))
        try store.set("a-real-key", for: .tmdbKey)
        XCTAssertTrue(store.isSet(.tmdbKey))
        XCTAssertEqual(store.value(for: .tmdbKey), "a-real-key")
    }

    func testOverwriteReplacesRatherThanDuplicates() throws {
        let backend = MemorySecretBackend()
        let store = SecretStore(backend: backend)

        try store.set("first", for: .tmdbKey)
        try store.set("second", for: .tmdbKey)
        XCTAssertEqual(store.value(for: .tmdbKey), "second")
        XCTAssertEqual(backend.accounts.count, 1, "must not accumulate a second item")
    }

    func testBlankSecretIsRefusedAndNeverWritten() {
        let backend = MemorySecretBackend()
        let store = SecretStore(backend: backend)

        // A blank key would show as "configured" and fail every request.
        for blank in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try store.set(blank, for: .tmdbKey)) { err in
                XCTAssertEqual(err as? SecretStore.StoreError, .empty)
            }
        }
        XCTAssertFalse(store.isSet(.tmdbKey))
        XCTAssertEqual(backend.writeCount, 0, "a refused secret must not reach storage")
    }

    func testStoredValueIsTrimmed() throws {
        let store = SecretStore(backend: MemorySecretBackend())
        // Pasting from a website drags whitespace along; a trailing newline in
        // an Authorization header is rejected by the server, not by us.
        try store.set("  key-with-spaces \n", for: .tmdbKey)
        XCTAssertEqual(store.value(for: .tmdbKey), "key-with-spaces")
    }

    func testRemove() throws {
        let store = SecretStore(backend: MemorySecretBackend())
        try store.set("x", for: .tmdbKey)
        XCTAssertTrue(store.remove(.tmdbKey))
        XCTAssertFalse(store.isSet(.tmdbKey))
        XCTAssertNil(store.value(for: .tmdbKey))
        XCTAssertTrue(store.remove(.tmdbKey), "removing an absent secret is not an error")
    }

    func testRemoveAllClearsEverySlot() throws {
        let backend = MemorySecretBackend()
        let store = SecretStore(backend: backend)
        for slot in SecretStore.Secret.allCases { try store.set("v", for: slot) }
        store.removeAll()
        XCTAssertTrue(backend.accounts.isEmpty)
        XCTAssertTrue(SecretStore.Secret.allCases.allSatisfy { !store.isSet($0) })
    }

    func testSlotsUseDistinctAccounts() throws {
        // A shared account name would make one secret silently overwrite
        // another; this catches it the moment a second slot is added.
        let names = SecretStore.Secret.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class SSHIdentityLifecycleTests: XCTestCase {

    func testHasIdentityDoesNotCreateOne() throws {
        // Settings shows the fingerprint, and `fingerprint()` creates a key on
        // first use — so merely opening Settings would mint an identity the
        // user never asked for. `hasIdentity` must be a pure question.
        let store = SSHKeyStore(service: "nl.pietjepuh.toolbelt.tests.lifecycle",
                                account: "probe")
        try? store.destroy()
        XCTAssertFalse(store.hasIdentity)

        do {
            _ = try store.identity()
        } catch SSHKeyStore.StoreError.keychain(let status) where status == -34018 {
            // errSecMissingEntitlement: unsigned test host, no Keychain. Skip
            // rather than pass — a test that could not run must not report as
            // one that did.
            throw XCTSkip("Keychain unavailable to an unsigned test host (-34018)")
        }

        XCTAssertTrue(store.hasIdentity)
        try store.destroy()
        XCTAssertFalse(store.hasIdentity)
    }
}
