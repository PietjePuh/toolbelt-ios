import XCTest
@testable import Toolbelt

final class SSHTargetTests: XCTestCase {

    func testParsesUserAndHost() throws {
        let t = try SSHTarget.parse("tim@pluto.local")
        XCTAssertEqual(t.user, "tim")
        XCTAssertEqual(t.host, "pluto.local")
        XCTAssertEqual(t.port, 22)
        XCTAssertFalse(t.isIPv6Literal)
    }

    func testParsesExplicitPort() throws {
        let t = try SSHTarget.parse("root@example.com:2222")
        XCTAssertEqual(t.port, 2222)
    }

    func testStripsSSHScheme() throws {
        // Common muscle memory; accepted rather than rejected on a technicality.
        XCTAssertEqual(try SSHTarget.parse("ssh://tim@host.example"),
                       try SSHTarget.parse("tim@host.example"))
    }

    func testTrimsSurroundingWhitespace() throws {
        // A pasted address usually drags a space or newline along.
        XCTAssertEqual(try SSHTarget.parse("  tim@host.example \n").host, "host.example")
    }

    // MARK: - IPv6

    func testBracketedIPv6WithPort() throws {
        let t = try SSHTarget.parse("tim@[fd7a::1]:2222")
        XCTAssertEqual(t.host, "fd7a::1")
        XCTAssertEqual(t.port, 2222)
        XCTAssertTrue(t.isIPv6Literal)
    }

    func testBracketedIPv6WithoutPort() throws {
        let t = try SSHTarget.parse("tim@[::1]")
        XCTAssertEqual(t.host, "::1")
        XCTAssertEqual(t.port, 22)
    }

    func testUnbracketedIPv6IsRefusedNotGuessed() {
        // `tim@::1` is genuinely ambiguous with host:port. Guessing either way
        // would connect somewhere the user did not name.
        XCTAssertThrowsError(try SSHTarget.parse("tim@fd7a::1"))
        XCTAssertThrowsError(try SSHTarget.parse("tim@::1"))
    }

    func testIPv6ZoneIdIsRefused() {
        // fe80::1%en0 names an interface on THIS device; it can never identify
        // a remote host, so it is refused rather than silently stripped.
        XCTAssertThrowsError(try SSHTarget.parse("tim@[fe80::1%en0]:22"))
    }

    // MARK: - refusals

    func testMissingUserIsRefused() {
        // No implicit username. Guessing "root" would be a security decision
        // made on the user's behalf.
        for raw in ["example.com", "example.com:22", "@example.com", ""] {
            XCTAssertThrowsError(try SSHTarget.parse(raw), raw)
        }
    }

    func testMissingHostIsRefused() {
        XCTAssertThrowsError(try SSHTarget.parse("tim@"))
    }

    func testInvalidPortsAreRefused() {
        for raw in ["tim@h.example:0", "tim@h.example:65536", "tim@h.example:-1",
                    "tim@h.example:abc", "tim@h.example:"] {
            XCTAssertThrowsError(try SSHTarget.parse(raw), raw)
        }
    }

    func testUsernameCannotCarryControlCharactersOrSpaces() {
        // The username is written verbatim into the authentication request.
        for bad in ["ti m@h.example", "tim\n@h.example", "-tim@h.example",
                    "ti;m@h.example", "ti/m@h.example"] {
            XCTAssertThrowsError(try SSHTarget.parse(bad), bad)
        }
    }

    func testMalformedHostsAreRefused() {
        for bad in ["tim@-host.example", "tim@host-.example", "tim@.host.example",
                    "tim@host..example", "tim@host.example.", "tim@ho st.example",
                    "tim@host/../evil"] {
            XCTAssertThrowsError(try SSHTarget.parse(bad), bad)
        }
    }

    func testAnExtraAtCannotRedirectTheConnection() {
        // The danger in `a@b@real.example` is splitting on the FIRST @, which
        // would treat "b@real.example" as the host and connect somewhere the
        // user never named.
        //
        // Splitting on the LAST @ makes the host real.example — correct — and
        // the username "a@b", which is then refused because @ is not a legal
        // username character. Refusing the whole address is the better outcome
        // than connecting with a username no server will accept: either way it
        // does not reach b@real.example, and this way the user is told.
        XCTAssertThrowsError(try SSHTarget.parse("a@b@real.example")) { err in
            XCTAssertEqual(err as? SSHTarget.ParseError, .invalidUser("a@b"))
        }
    }

    func testTheHostIsTakenFromTheLastAt() throws {
        // The same split, on an address where the username IS legal — proving
        // the behaviour above comes from last-@ parsing rather than from the
        // address happening to be rejected.
        let t = try SSHTarget.parse("tim@real.example")
        XCTAssertEqual(t.host, "real.example")
        XCTAssertEqual(t.user, "tim")
    }

    // MARK: - identity and round-trip

    func testKnownHostsKeyIncludesThePort() {
        // A different service on the same machine is a different trust
        // decision, so it must not share a pinned host key.
        let a = SSHTarget(user: "tim", host: "h.example", port: 22)
        let b = SSHTarget(user: "tim", host: "h.example", port: 2222)
        XCTAssertNotEqual(a.knownHostsKey, b.knownHostsKey)
    }

    func testKnownHostsKeyIgnoresTheUsername() {
        // The host key belongs to the HOST, not to whoever is logging in.
        let a = SSHTarget(user: "tim", host: "h.example")
        let b = SSHTarget(user: "root", host: "h.example")
        XCTAssertEqual(a.knownHostsKey, b.knownHostsKey)
    }

    func testDisplayStringRoundTrips() throws {
        for raw in ["tim@host.example", "root@host.example:2222",
                    "tim@[fd7a::1]:2222", "tim@[::1]"] {
            let parsed = try SSHTarget.parse(raw)
            XCTAssertEqual(try SSHTarget.parse(parsed.displayString), parsed, raw)
        }
    }

    func testDefaultPortIsOmittedFromDisplay() {
        XCTAssertEqual(SSHTarget(user: "tim", host: "h.example").displayString, "tim@h.example")
        XCTAssertEqual(SSHTarget(user: "tim", host: "h.example", port: 2222).displayString,
                       "tim@h.example:2222")
    }
}
