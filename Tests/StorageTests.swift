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

final class SecretStoreTests: XCTestCase {

    // A per-test service keeps these from colliding with a real install.
    private func makeStore(_ name: String = #function) -> SecretStore {
        SecretStore(service: "nl.pietjepuh.toolbelt.tests.\(name)")
    }

    func testRoundTrip() throws {
        let store = makeStore()
        defer { store.removeAll() }

        XCTAssertFalse(store.isSet(.tmdbKey))
        try store.set("a-real-key", for: .tmdbKey)
        XCTAssertTrue(store.isSet(.tmdbKey))
        XCTAssertEqual(store.value(for: .tmdbKey), "a-real-key")
    }

    func testOverwriteReplacesRatherThanDuplicates() throws {
        let store = makeStore()
        defer { store.removeAll() }

        try store.set("first", for: .tmdbKey)
        try store.set("second", for: .tmdbKey)
        XCTAssertEqual(store.value(for: .tmdbKey), "second")
    }

    func testBlankSecretIsRefused() {
        let store = makeStore()
        defer { store.removeAll() }

        // A blank key would show as "configured" and fail every request.
        for blank in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try store.set(blank, for: .tmdbKey)) { err in
                XCTAssertEqual(err as? SecretStore.StoreError, .empty)
            }
        }
        XCTAssertFalse(store.isSet(.tmdbKey))
    }

    func testStoredValueIsTrimmed() throws {
        let store = makeStore()
        defer { store.removeAll() }

        // Pasting from a website drags whitespace along; a trailing newline in
        // an Authorization header is rejected by the server, not by us.
        try store.set("  key-with-spaces \n", for: .tmdbKey)
        XCTAssertEqual(store.value(for: .tmdbKey), "key-with-spaces")
    }

    func testRemove() throws {
        let store = makeStore()
        try store.set("x", for: .tmdbKey)
        XCTAssertTrue(store.remove(.tmdbKey))
        XCTAssertFalse(store.isSet(.tmdbKey))
        XCTAssertNil(store.value(for: .tmdbKey))
        XCTAssertTrue(store.remove(.tmdbKey), "removing an absent secret is not an error")
    }
}
