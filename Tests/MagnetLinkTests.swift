import XCTest
@testable import Toolbelt

/// Magnet parsing is written and tested before any torrent engine exists,
/// because a subtly wrong infohash produces a download that never finds a peer
/// and shows the user no error at all — the hardest kind of failure to
/// diagnose from the outside.
final class MagnetLinkTests: XCTestCase {

    func testParsesHexInfoHash() throws {
        let hash = String(repeating: "a1", count: 20)   // 40 hex chars
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(hash)&dn=Example&tr=https://tracker.example/announce")
        XCTAssertEqual(m.infoHash, hash)
        XCTAssertEqual(m.displayName, "Example")
        XCTAssertEqual(m.trackers.count, 1)
    }

    func testLowercasesHexSoComparisonsMatch() throws {
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(String(repeating: "AB", count: 20))")
        XCTAssertEqual(m.infoHash, String(repeating: "ab", count: 20))
    }

    func testAcceptsV2SixtyFourCharHash() throws {
        let hash = String(repeating: "c", count: 64)
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(hash)")
        XCTAssertEqual(m.infoHash, hash)
    }

    func testHybridLinkTakesTheUsableHash() throws {
        // v1+v2 hybrid links carry several xt values. An unfamiliar sibling
        // must not cause the whole link to be rejected.
        let good = String(repeating: "d1", count: 20)
        let m = try MagnetLink.parse("magnet:?xt=urn:sha1:whatever&xt=urn:btih:\(good)")
        XCTAssertEqual(m.infoHash, good)
    }

    func testMultipleTrackersAllKept() throws {
        let m = try MagnetLink.parse(
            "magnet:?xt=urn:btih:\(String(repeating: "e1", count: 20))"
            + "&tr=https://a.example/announce&tr=https://b.example/announce")
        XCTAssertEqual(m.trackers.count, 2)
    }

    func testRejectsNonMagnet() {
        XCTAssertThrowsError(try MagnetLink.parse("https://example.com/file.torrent"))
    }

    func testRejectsMissingInfoHash() {
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?dn=NoHashHere"))
    }

    func testRejectsMalformedHashRatherThanGuessing() {
        // 39 chars, one short. Refusing beats handing an engine a hash that can
        // never match anything.
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:\(String(repeating: "a", count: 39))"))
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:zzzz"))
    }

    func testBase32HashIsConvertedToHex() throws {
        // Older links use 32-char base32. It must normalise to hex so two links
        // pointing at the same torrent compare equal.
        let hexBytes: [UInt8] = Array(repeating: 0x00, count: 20)
        let b32 = String(repeating: "A", count: 32)          // 32 x 'A' == 20 zero bytes
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(b32)")
        XCTAssertEqual(m.infoHash, hexBytes.map { String(format: "%02x", $0) }.joined())
    }

    func testDisplayNameIsAdvisoryOnly() throws {
        // The name comes from whoever wrote the link. It is carried through,
        // but the type does not treat it as a path — a traversal attempt must
        // survive as data, to be sanitised at the point of use.
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(String(repeating: "f1", count: 20))&dn=../../etc/passwd")
        XCTAssertEqual(m.displayName, "../../etc/passwd")
    }
}
