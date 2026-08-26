import XCTest
@testable import Toolbelt

@MainActor
final class DiagnosticRedactionTests: XCTestCase {

    private func redact(_ s: String) -> String { DiagnosticLog.redact(s) }

    /// Structurally a JWT so the redaction is genuinely exercised, but the
    /// payload decodes to {"FAKE":"not-a-secret"} — because a realistic-looking
    /// token in a PUBLIC repo trips secret scanners, and a scanner that cries
    /// wolf over test data trains people to ignore it. This file caused exactly
    /// that on PR #11.
    static let fakeJWT = "eyJhbGciOiJub25lIn0.eyJGQUtFIjoibm90LWEtc2VjcmV0In0.RkFLRV9OT1RfQV9TSUc"
    private let placeholder = DiagnosticLog.placeholder

    // MARK: - the case this app actually produces

    func testIPTVPlaylistCredentialsAreRemoved() {
        // The common case, not an edge one: providers put the subscription
        // username and password straight in the playlist URL, and the whole
        // point of this log is that it can be sent to someone.
        let line = "GET https://provider.example/get.php?username=FAKEUSER&password=FAKEPASS-NOT-A-SECRET&type=m3u failed"
        let out = redact(line)

        XCTAssertFalse(out.contains("FAKEUSER"))
        XCTAssertFalse(out.contains("FAKEPASS-NOT-A-SECRET"))
        XCTAssertTrue(out.contains("type=m3u"), "non-secret parameters must survive")
        XCTAssertTrue(out.contains("provider.example"), "the host is what makes the log useful")
        XCTAssertEqual(out.components(separatedBy: placeholder).count - 1, 2)
    }

    func testBearerTokensAreRemoved() {
        let out = redact("Authorization: Bearer " + Self.fakeJWT)
        XCTAssertFalse(out.contains(Self.fakeJWT))
        XCTAssertTrue(out.contains("Bearer"))
    }

    func testCredentialsInTheAuthorityAreRemoved() {
        let out = redact("connecting to https://admin:FAKEPASS-NOT-A-SECRET@host.example/api")
        XCTAssertFalse(out.contains("FAKEPASS-NOT-A-SECRET"))
        XCTAssertFalse(out.contains("admin:"))
        XCTAssertTrue(out.contains("host.example"))
    }

    func testRedactionIsCaseInsensitive() {
        for line in ["?PASSWORD=abc", "?Password=abc", "&ApiKey=abc", "Authorization: BEARER abc"] {
            XCTAssertFalse(redact(line).contains("abc"), line)
        }
    }

    func testSecretAtTheEndOfALineIsStillRemoved() {
        // No trailing delimiter to stop at — an easy off-by-one that leaks the
        // whole value.
        XCTAssertFalse(redact("https://h.example/x?token=abcdef").contains("abcdef"))
    }

    func testSecretFollowedByProseIsRemovedButTheProseSurvives() {
        // Log lines are sentences with URLs in them, not bare URLs.
        let out = redact("tried https://h.example/x?token=abc123 and it timed out")
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertTrue(out.contains("and it timed out"))
    }

    func testSeveralSecretsInOneLineAreAllRemoved() {
        let out = redact("a?user=bob&password=p1&other=keep&token=t1")
        XCTAssertFalse(out.contains("bob"))
        XCTAssertFalse(out.contains("p1"))
        XCTAssertFalse(out.contains("t1"))
        XCTAssertTrue(out.contains("other=keep"))
    }

    func testOrdinaryTextIsUntouched() {
        // Over-redacting makes the log useless, which is its own failure.
        let line = "loaded 42 items from https://news.example/feed.xml in 320ms"
        XCTAssertEqual(redact(line), line)
    }

    func testAParameterMerelyContainingSecretWordsIsNotClobbered() {
        let out = redact("?keyword=tokenring&username=bob")
        XCTAssertTrue(out.contains("keyword=tokenring"), "keyword is not key")
        XCTAssertFalse(out.contains("bob"))
    }

    // MARK: - redaction happens on the way in

    func testStoredEntriesAreAlreadyRedacted() {
        // Scrubbing only on export would leave secrets in memory and would be
        // silently bypassed by any future export path.
        let log = DiagnosticLog.shared
        log.clear()
        log.error("net", "failed https://p.example/get.php?password=FAKEPASS-NOT-A-SECRET")

        XCTAssertFalse(log.entries[0].message.contains("FAKEPASS-NOT-A-SECRET"))
        XCTAssertFalse(log.export().contains("FAKEPASS-NOT-A-SECRET"))
        log.clear()
    }

    func testTheLogIsBounded() {
        // An unbounded log on a phone is a leak that only appears in a long
        // session — exactly when the log is needed.
        let log = DiagnosticLog.shared
        log.clear()
        for i in 0..<(DiagnosticLog.capacity + 50) { log.info("test", "entry \(i)") }

        XCTAssertEqual(log.entries.count, DiagnosticLog.capacity)
        XCTAssertTrue(log.entries.last?.message.contains("\(DiagnosticLog.capacity + 49)") == true,
                      "the newest entries are the ones kept")
        log.clear()
    }

    func testLevelsAreOrderedForFiltering() {
        XCTAssertLessThan(DiagnosticLog.Level.debug.severity, DiagnosticLog.Level.error.severity)
        XCTAssertLessThan(DiagnosticLog.Level.info.severity, DiagnosticLog.Level.warning.severity)
    }
}

final class NetworkDiagnosticsTests: XCTestCase {

    func testTunnelInterfacesAreRecognised() {
        // utun is what Tailscale, WireGuard and iCloud Private Relay use.
        for name in ["utun0", "utun4", "tap0", "ppp0", "ipsec0", "UTUN1"] {
            XCTAssertTrue(NetworkDiagnostics.isTunnelInterface(name), name)
        }
    }

    func testOrdinaryInterfacesAreNotTunnels() {
        for name in ["en0", "en1", "pdp_ip0", "lo0", "awdl0", "bridge0"] {
            XCTAssertFalse(NetworkDiagnostics.isTunnelInterface(name), name)
        }
    }
}
