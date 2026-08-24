import XCTest
@testable import Toolbelt

/// The rule these exist to defend: a check that could not be performed reports
/// `.unknown`, never `.ok`. The desktop Toolbelt has repeatedly shipped
/// scanners that rendered "no findings" when the truth was "could not ask" —
/// and here that would tell a user a host is fine when nothing was checked.
final class DomainScannerTests: XCTestCase {

    // MARK: - input normalisation

    func testNormaliseAcceptsPlainDomain() {
        XCTAssertEqual(DomainScanner.normalise("example.com"), "example.com")
    }

    func testNormaliseLowercasesAndStripsURL() {
        XCTAssertEqual(DomainScanner.normalise("HTTPS://Example.com/some/path"), "example.com")
    }

    func testNormaliseStripsTrailingDotFQDN() {
        XCTAssertEqual(DomainScanner.normalise("example.com."), "example.com")
    }

    func testNormaliseRejectsUnusableInput() {
        // Refusing is correct: silently scanning the wrong host is worse than
        // declining to scan.
        XCTAssertNil(DomainScanner.normalise(""))
        XCTAssertNil(DomainScanner.normalise("   "))
        XCTAssertNil(DomainScanner.normalise("not a domain"))
        XCTAssertNil(DomainScanner.normalise("localhost"))      // no dot
    }

    // MARK: - the false-clean rule

    func testUnreachableHostYieldsUnknownNotOK() async {
        // A gateway whose every request fails, i.e. the phone is offline or the
        // host does not exist.
        let gateway = Gateway(session: Self.failingSession())
        let report = await DomainScanner(gateway: gateway).scan("example.com")

        XCTAssertFalse(report.isComplete,
                       "a scan where nothing could be checked must not report complete")
        XCTAssertTrue(report.findings.isEmpty,
                      "unreachable must not manufacture findings — 'HSTS missing' when we never got a response is a fabricated result")
        XCTAssertFalse(report.unknowns.isEmpty,
                       "the failures must surface as unknown")

        for check in report.checks {
            if case .ok = check.outcome {
                XCTFail("\(check.title) reported OK despite no response")
            }
        }
    }

    func testMalformedInputReportsUnknownRatherThanScanning() async {
        let gateway = Gateway(session: Self.failingSession())
        let report = await DomainScanner(gateway: gateway).scan("not a domain")
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.checks.count, 1)
        if case .unknown = report.checks[0].outcome {} else {
            XCTFail("unusable input must be unknown, not a scan result")
        }
    }

    // MARK: - gateway contract

    func testGatewayRefusesNonHTTPS() async {
        let gateway = Gateway(session: Self.failingSession())
        do {
            _ = try await gateway.send(.init(url: URL(string: "http://example.com")!))
            XCTFail("plain http must be refused before it leaves the device")
        } catch let failure as Gateway.Failure {
            guard case .refused = failure else {
                return XCTFail("expected .refused, got \(failure)")
            }
        } catch {
            XCTFail("expected Gateway.Failure, got \(error)")
        }
    }

    func testUnreachableIsNotAnAnswer() {
        // Callers branch on this to decide whether they may render a result.
        XCTAssertFalse(Gateway.Failure.unreachable("offline").isAnswer)
        XCTAssertFalse(Gateway.Failure.refused("bad scheme").isAnswer)
        XCTAssertFalse(Gateway.Failure.malformed("junk").isAnswer)
        XCTAssertTrue(Gateway.Failure.http(status: 404).isAnswer,
                      "a 404 IS an answer — the host responded")
    }

    // MARK: - helpers

    /// A URLSession whose every request fails, without touching the network.
    private static func failingSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AlwaysFailingProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// Fails every request, so tests never depend on the network — a test that
/// silently passes because a real host happened to answer is worse than none.
final class AlwaysFailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
