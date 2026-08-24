import XCTest
@testable import Toolbelt

/// An IPTV playlist is untrusted input fetched from a URL the user pasted.
/// These pin the behaviours that decide whether a bad playlist is diagnosable
/// or merely looks empty.
final class M3UPlaylistTests: XCTestCase {

    func testParsesChannelWithAttributes() throws {
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="bbc1" tvg-logo="https://logos.example/bbc1.png" group-title="UK",BBC One
        https://stream.example/bbc1.m3u8
        """)
        XCTAssertEqual(p.channels.count, 1)
        let c = p.channels[0]
        XCTAssertEqual(c.name, "BBC One")
        XCTAssertEqual(c.group, "UK")
        XCTAssertEqual(c.tvgID, "bbc1")
        XCTAssertEqual(c.logo?.absoluteString, "https://logos.example/bbc1.png")
    }

    func testNonPlaylistThrowsRatherThanReturningEmpty() {
        // The important one. Providers serve HTML error pages with a 200, and
        // "0 channels" would read as "this provider has nothing" when the truth
        // is "we could not understand the file".
        XCTAssertThrowsError(try M3UPlaylist.parse("<html><body>404 not found</body></html>")) { err in
            XCTAssertEqual(err as? M3UPlaylist.ParseError, .notAPlaylist)
        }
    }

    func testCommaInsideAttributeDoesNotSplitTheName() throws {
        // The classic parser bug: splitting on the first comma truncates every
        // name whose attributes contain one.
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1 group-title="News, Sport",Sky News
        https://stream.example/sky
        """)
        XCTAssertEqual(p.channels.first?.name, "Sky News")
        XCTAssertEqual(p.channels.first?.group, "News, Sport")
    }

    func testRejectsFileURLFromAnUntrustedPlaylist() throws {
        // A playlist from a stranger must not be able to point the player at
        // local storage.
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1,Local
        file:///etc/passwd
        """)
        XCTAssertTrue(p.channels.isEmpty)
        XCTAssertEqual(p.skipped, 1, "a refused entry must be COUNTED, not silently dropped")
    }

    func testUnreadableEntriesAreCountedNotHidden() throws {
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1,Good
        https://stream.example/good
        #EXTINF:
        https://stream.example/orphan
        """)
        XCTAssertEqual(p.channels.count, 1)
        XCTAssertGreaterThan(p.skipped, 0,
            "a playlist that is partly junk must be able to say so — 'we showed you 288 of 300' beats silently showing 288")
    }

    func testOtherDirectivesAreIgnoredNotTreatedAsURLs() throws {
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1,Chan
        #EXTVLCOPT:network-caching=1000
        https://stream.example/chan
        """)
        XCTAssertEqual(p.channels.count, 1)
        XCTAssertEqual(p.channels[0].url.absoluteString, "https://stream.example/chan")
    }

    func testAcceptsNonHTTPStreamingSchemes() throws {
        // IPTV legitimately uses udp/rtp/rtsp for multicast and camera feeds.
        let p = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1,Multicast
        udp://@239.0.0.1:1234
        """)
        XCTAssertEqual(p.channels.count, 1)
    }

    func testOversizedPlaylistIsRefusedWithItsSize() {
        let big = Data(repeating: 0x41, count: M3UPlaylist.maxBytes + 1)
        XCTAssertThrowsError(try M3UPlaylist.parse(big)) { err in
            guard case .tooLarge(let bytes)? = err as? M3UPlaylist.ParseError else {
                return XCTFail("expected .tooLarge, got \(err)")
            }
            XCTAssertGreaterThan(bytes, M3UPlaylist.maxBytes)
        }
    }

    func testLatin1PlaylistStillParses() throws {
        // Providers are inconsistent about encoding; falling back beats failing.
        var bytes = Array("#EXTM3U\n#EXTINF:-1,Caf".utf8)
        bytes.append(0xE9)                       // 'é' in ISO-8859-1
        bytes.append(contentsOf: Array("\nhttps://stream.example/x".utf8))
        let p = try M3UPlaylist.parse(Data(bytes))
        XCTAssertEqual(p.channels.count, 1)
    }

    func testLeadingDurationIsNotTreatedAsAnAttributeName() {
        // The regression: `-1` was glued onto the first key, giving `-1 tvg-id`,
        // so every lookup missed and every channel silently lost its metadata.
        let attrs = M3UPlaylist.parseAttributes("-1 tvg-id=\"bbc1\" group-title=\"News\"")
        XCTAssertEqual(attrs["tvg-id"], "bbc1")
        XCTAssertEqual(attrs["group-title"], "News")
        XCTAssertNil(attrs["-1 tvg-id"])
    }

    func testUnquotedAttributeValues() {
        let attrs = M3UPlaylist.parseAttributes("-1 tvg-id=bbc1 tvg-shift=2")
        XCTAssertEqual(attrs["tvg-id"], "bbc1")
        XCTAssertEqual(attrs["tvg-shift"], "2")
    }
}
