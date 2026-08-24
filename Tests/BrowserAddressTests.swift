import XCTest
@testable import Toolbelt

final class BrowserAddressTests: XCTestCase {

    func testBareHostGetsHTTPS() {
        XCTAssertEqual(BrowserAddress.resolve("example.com"), .web(URL(string: "https://example.com")!))
        XCTAssertEqual(BrowserAddress.resolve(" example.com/a/b "), .web(URL(string: "https://example.com/a/b")!))
    }

    func testExplicitHTTPIsHonouredNotSilentlyUpgraded() {
        // Silently rewriting http→https makes the padlock lie about what
        // actually happened on the wire.
        XCTAssertEqual(BrowserAddress.resolve("http://example.com"),
                       .web(URL(string: "http://example.com")!))
    }

    func testDangerousSchemesAreRefused() {
        // These arrive from feeds and scan results, not just from typing.
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>x</script>",
                    "ftp://example.com", "tel:+3112345678", "itms-apps://x"] {
            guard case .refused = BrowserAddress.resolve(raw) else {
                return XCTFail("\(raw) should be refused")
            }
        }
    }

    func testSchemeRefusalIsCaseInsensitive() {
        guard case .refused = BrowserAddress.resolve("JavaScript:alert(1)") else {
            return XCTFail("case must not bypass the allow-list")
        }
    }

    func testNonURLTextBecomesASearch() {
        XCTAssertEqual(BrowserAddress.resolve("best iptv players"), .search("best iptv players"))
        XCTAssertEqual(BrowserAddress.resolve("hello"), .search("hello"))
        XCTAssertEqual(BrowserAddress.resolve(""), .search(""))
    }

    func testSchemelessWithSpacesIsASearchNotAHost() {
        XCTAssertEqual(BrowserAddress.resolve("what is example.com"),
                       .search("what is example.com"))
    }

    func testSearchTermIsEncodedIncludingAmpersand() {
        let url = BrowserAddress.searchURL("tom & jerry")
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        XCTAssertFalse(raw.contains(" "))
        XCTAssertEqual(raw.filter { $0 == "&" }.count, 0, "& must not become a second parameter")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value, "tom & jerry")
    }

    // MARK: - what the address bar shows

    func testDisplayShowsHostAndTLSState() {
        let secure = BrowserAddress.display(URL(string: "https://example.com/deep/path?x=1")!)
        XCTAssertEqual(secure.host, "example.com")
        XCTAssertTrue(secure.isSecure)

        let plain = BrowserAddress.display(URL(string: "http://example.com")!)
        XCTAssertFalse(plain.isSecure)
    }

    func testUserinfoCannotDisguiseTheHost() {
        // https://www.google.com@evil.example/ is served by evil.example. The
        // address bar must say so — this is the classic phishing URL.
        let shown = BrowserAddress.display(URL(string: "https://www.google.com@evil.example/login")!)
        XCTAssertEqual(shown.host, "evil.example")
    }

    func testInternationalisedHostIsShownAsPunycode() {
        // A lookalike domain must not render as the letters it imitates.
        let url = URL(string: "https://xn--80ak6aa92e.com/")!
        XCTAssertEqual(BrowserAddress.display(url).host, "xn--80ak6aa92e.com")
    }
}
