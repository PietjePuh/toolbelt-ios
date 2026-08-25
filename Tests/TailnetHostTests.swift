import XCTest
@testable import Toolbelt

final class TailnetHostTests: XCTestCase {

    func testTailscaleCGNATRange() {
        // 100.64.0.0/10 — second octet 64 through 127.
        for host in ["100.64.0.1", "100.100.100.100", "100.127.255.255", "100.64.0.0"] {
            XCTAssertTrue(TailnetHost.isTailscaleIP(host), host)
        }
    }

    func testAddressesOutsideTheRangeAreNotTailscale() {
        // A naive "starts with 100." check gets all of these wrong. 100.0.x and
        // 100.128.x are ordinary public addresses.
        for host in ["100.0.0.1", "100.63.255.255", "100.128.0.1", "100.200.1.1",
                     "10.64.0.1", "1.100.64.1"] {
            XCTAssertFalse(TailnetHost.isTailscaleIP(host), host)
        }
    }

    func testMalformedAddressesAreNotTailscale() {
        for host in ["100.64.0", "100.64.0.1.5", "100.64.0.999", "100.64..1",
                     "100.sixty.0.1", ""] {
            XCTAssertFalse(TailnetHost.isTailscaleIP(host), host)
        }
    }

    func testMagicDNSMatchesOnALabelBoundary() {
        XCTAssertTrue(TailnetHost.isMagicDNS("pluto.tail1234.ts.net"))
        XCTAssertTrue(TailnetHost.isMagicDNS("PLUTO.TAIL1234.TS.NET"))
        // The bug a plain `contains` or a suffix without the dot would cause:
        // a lookalike domain would be treated as trusted infrastructure.
        XCTAssertFalse(TailnetHost.isMagicDNS("evilts.net"))
        XCTAssertFalse(TailnetHost.isMagicDNS("ts.net.evil.com"))
        XCTAssertFalse(TailnetHost.isMagicDNS("nots.net"))
    }

    func testClassification() {
        XCTAssertEqual(TailnetHost.classify("100.101.102.103"), .tailnet)
        XCTAssertEqual(TailnetHost.classify("pluto.tail1234.ts.net"), .tailnet)
        XCTAssertEqual(TailnetHost.classify("192.168.1.10"), .localNetwork)
        XCTAssertEqual(TailnetHost.classify("10.0.0.5"), .localNetwork)
        XCTAssertEqual(TailnetHost.classify("172.16.0.1"), .localNetwork)
        XCTAssertEqual(TailnetHost.classify("172.32.0.1"), .publicInternet, "172.32 is public")
        XCTAssertEqual(TailnetHost.classify("pluto.local"), .localNetwork)
        XCTAssertEqual(TailnetHost.classify("example.com"), .publicInternet)
    }

    // MARK: - the point of all this

    func testATimeoutOnATailnetAddressExplainsItself() {
        // A tailnet host with Tailscale off does not REFUSE the connection, it
        // never answers — so the timeout looks exactly like a dead server and
        // sends the user looking in the wrong place.
        let hint = TailnetHost.timeoutHint(for: "100.101.102.103")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("Tailscale"))
    }

    func testALocalAddressSaysSoToo() {
        let hint = TailnetHost.timeoutHint(for: "192.168.1.10")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.lowercased().contains("network"))
    }

    func testAnOrdinaryHostGetsNoInventedHint() {
        // Adding a hint here would be guessing at a cause we do not know.
        XCTAssertNil(TailnetHost.timeoutHint(for: "example.com"))
    }
}

final class SSHHostStoreTests: XCTestCase {

    private final class MemoryStore: KeyValueStore {
        var contents: [String: Data] = [:]
        func data(forKey key: String) -> Data? { contents[key] }
        func set(_ value: Data?, forKey key: String) { contents[key] = value }
    }

    private func makeStore() -> (SSHHostStore, MemoryStore) {
        let backing = MemoryStore()
        return (SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s"), backing)
    }

    func testAddAndPersistHosts() throws {
        let backing = MemoryStore()
        let first = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        try first.add(try SSHTarget.parse("tim@pluto.tail1234.ts.net"), label: "Pluto")

        let second = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        XCTAssertEqual(second.allHosts().count, 1)
        XCTAssertEqual(second.allHosts().first?.label, "Pluto")
        XCTAssertEqual(second.allHosts().first?.reachability, .tailnet)
    }

    func testLabelFallsBackToTheAddress() throws {
        let (store, _) = makeStore()
        let saved = try store.add(try SSHTarget.parse("tim@host.example:2222"))
        XCTAssertEqual(saved.label, "tim@host.example:2222")
    }

    func testSameMachineUnderTwoUsernamesIsTwoEntries() throws {
        // They are two different logins, not a duplicate.
        let (store, _) = makeStore()
        try store.add(try SSHTarget.parse("tim@host.example"))
        try store.add(try SSHTarget.parse("root@host.example"))
        XCTAssertEqual(store.allHosts().count, 2)
    }

    func testTheSameLoginTwiceIsRefused() throws {
        let (store, _) = makeStore()
        let original = try store.add(try SSHTarget.parse("tim@host.example"))
        XCTAssertThrowsError(try store.add(try SSHTarget.parse("tim@HOST.example"))) { err in
            guard case .duplicate(let existing)? = err as? SSHHostStore.StoreError else {
                return XCTFail("expected .duplicate")
            }
            XCTAssertEqual(existing.id, original.id)
        }
    }

    func testDifferentPortIsADifferentHost() throws {
        let (store, _) = makeStore()
        try store.add(try SSHTarget.parse("tim@host.example"))
        try store.add(try SSHTarget.parse("tim@host.example:2222"))
        XCTAssertEqual(store.allHosts().count, 2)
    }

    func testTargetRoundTripsThroughTheSavedHost() throws {
        let (store, _) = makeStore()
        let saved = try store.add(try SSHTarget.parse("tim@host.example:2222"))
        XCTAssertEqual(saved.target, try SSHTarget.parse("tim@host.example:2222"))
    }

    // MARK: - snippets

    func testSnippetsDefaultToInsertNotRun() {
        // Some saved commands are destructive. `docker system prune -af` should
        // land on the prompt for a look, not fire on a mis-tap.
        let snippet = Snippet(title: "Prune", command: "docker system prune -af")
        XCTAssertFalse(snippet.runImmediately)
        XCTAssertEqual(snippet.payload, "docker system prune -af")
        XCTAssertFalse(snippet.payload.hasSuffix("\n"))
    }

    func testARunImmediatelySnippetSendsTheNewline() {
        let snippet = Snippet(title: "Uptime", command: "uptime", runImmediately: true)
        XCTAssertEqual(snippet.payload, "uptime\n")
    }

    func testSnippetTitleFallsBackToTheCommand() throws {
        let (store, _) = makeStore()
        let saved = try store.add(snippet: Snippet(title: "  ", command: "journalctl -xe"))
        XCTAssertEqual(saved.title, "journalctl -xe")
    }

    func testEmptyCommandIsNotSaved() throws {
        let (store, _) = makeStore()
        try store.add(snippet: Snippet(title: "Nothing", command: "   "))
        XCTAssertTrue(store.allSnippets().isEmpty)
    }

    func testSnippetsPersist() throws {
        let backing = MemoryStore()
        let first = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        try first.add(snippet: Snippet(title: "Logs", command: "docker compose logs -f", runImmediately: true))

        let second = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        XCTAssertEqual(second.allSnippets().count, 1)
        XCTAssertTrue(second.allSnippets()[0].runImmediately)
    }

    // MARK: - corruption

    func testUnreadableDataIsNeverOverwritten() {
        let backing = MemoryStore()
        backing.contents["h"] = Data("{not json".utf8)

        let store = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        XCTAssertTrue(store.isUnreadable)
        XCTAssertThrowsError(try store.add(try SSHTarget.parse("tim@h.example")))
        XCTAssertEqual(backing.contents["h"], Data("{not json".utf8))
    }

    func testResetIsTheOnlyWayOut() throws {
        let backing = MemoryStore()
        backing.contents["s"] = Data("garbage".utf8)
        let store = SSHHostStore(store: backing, hostsKey: "h", snippetsKey: "s")
        XCTAssertTrue(store.isUnreadable)

        try store.resetAfterCorruption()
        XCTAssertFalse(store.isUnreadable)
        try store.add(snippet: Snippet(title: "x", command: "ls"))
        XCTAssertEqual(store.allSnippets().count, 1)
    }
}
