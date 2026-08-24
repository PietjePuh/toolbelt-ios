import XCTest
@testable import Toolbelt

/// Feed XML is the most hostile input in the app: arbitrary hosts, no schema,
/// and a format with well-known attack shapes. These pin both the parsing and
/// the refusals.
final class FeedParserTests: XCTestCase {

    func testParsesRSSItems() throws {
        let feed = try FeedParser.parse(Data("""
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Example News</title>
          <item>
            <title>First</title>
            <link>https://example.com/1</link>
            <pubDate>Tue, 19 Aug 2026 09:00:00 +0000</pubDate>
            <description>Something happened</description>
          </item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.title, "Example News")
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.items[0].link?.absoluteString, "https://example.com/1")
        XCTAssertNotNil(feed.items[0].published)
        XCTAssertFalse(feed.isPodcast)
    }

    func testPodcastEnclosureBecomesPlayableMedia() throws {
        // A podcast IS an RSS feed with an audio enclosure — one parser, both
        // features.
        let feed = try FeedParser.parse(Data("""
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>A Podcast</title>
          <item>
            <title>Episode 1</title>
            <enclosure url="https://cdn.example/ep1.mp3" type="audio/mpeg" length="12345"/>
          </item>
        </channel></rss>
        """.utf8))
        XCTAssertTrue(feed.isPodcast)
        let media = try XCTUnwrap(feed.items.first?.media)
        XCTAssertTrue(media.isAudio)
        XCTAssertEqual(media.bytes, 12345)
        XCTAssertEqual(media.url.absoluteString, "https://cdn.example/ep1.mp3")
    }

    func testAtomEntriesParse() throws {
        let feed = try FeedParser.parse(Data("""
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Example</title>
          <entry>
            <title>Hello</title>
            <link rel="alternate" href="https://example.com/a"/>
            <updated>2026-08-19T09:00:00Z</updated>
          </entry>
        </feed>
        """.utf8))
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.items[0].link?.absoluteString, "https://example.com/a")
        XCTAssertNotNil(feed.items[0].published)
    }

    // MARK: - refusals

    func testNonFeedXMLThrowsRatherThanReturningEmpty() {
        // The distinction that matters: "we could not understand this" must not
        // render as "this feed has no items".
        XCTAssertThrowsError(try FeedParser.parse(Data("<html><body>hi</body></html>".utf8))) { err in
            XCTAssertEqual(err as? FeedParser.ParseError, .notAFeed)
        }
    }

    func testMalformedXMLIsReportedAsMalformed() {
        XCTAssertThrowsError(try FeedParser.parse(Data("<rss><channel><title>oops".utf8))) { err in
            guard case .malformedXML? = err as? FeedParser.ParseError else {
                return XCTFail("expected .malformedXML, got \(err)")
            }
        }
    }

    func testBillionLaughsDoesNotExpand() throws {
        // XMLParser leaves shouldResolveExternalEntities false, and the parser
        // sets it explicitly. If that ever changed, this input would expand
        // exponentially instead of parsing to nothing useful.
        let bomb = """
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
         <!ENTITY lol "lol">
         <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
         <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        ]>
        <rss version="2.0"><channel><title>&lol3;</title></channel></rss>
        """
        // Either it throws or it yields a small title — what must NOT happen is
        // a multi-megabyte expansion.
        if let feed = try? FeedParser.parse(Data(bomb.utf8)) {
            XCTAssertLessThan(feed.title.count, 10_000, "entities must not have expanded")
        }
    }

    func testFileEnclosureIsRefused() throws {
        // A feed from a stranger must not hand the player a local path.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>x</title>
          <item><title>Bad</title><enclosure url="file:///etc/passwd" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8))
        XCTAssertNil(feed.items.first?.media, "file:// must never become playable media")
    }

    func testUnparsableDateIsNilNotNow() throws {
        // A wrong timestamp is worse than an absent one: it silently reorders
        // the feed and the user cannot tell.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>x</title>
          <item><title>T</title><pubDate>not a date</pubDate></item>
        </channel></rss>
        """.utf8))
        XCTAssertNil(feed.items.first?.published)
    }

    func testOversizedFeedRefusedWithSize() {
        let big = Data(repeating: 0x20, count: FeedParser.maxBytes + 1)
        XCTAssertThrowsError(try FeedParser.parse(big)) { err in
            guard case .tooLarge? = err as? FeedParser.ParseError else {
                return XCTFail("expected .tooLarge, got \(err)")
            }
        }
    }

    func testCDATATitleIsRead() throws {
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title><![CDATA[Wrapped & Escaped]]></title>
          <item><title><![CDATA[Item One]]></title><link>https://e.example/1</link></item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.title, "Wrapped & Escaped")
        XCTAssertEqual(feed.items.first?.title, "Item One")
    }

    // MARK: - the gaps found on review

    func testItunesTitleDoesNotOverwriteItemTitle() throws {
        // The bug this pins: with XML namespace processing ON, XMLParser hands
        // the delegate the LOCAL name, so <itunes:title> arrives as "title" and
        // clobbers the real one. Podcast feeds carry one in nearly every item,
        // so this would have been wrong for most real podcasts.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>Show</title>
          <item>
            <title>Real Title</title>
            <itunes:title>Short Title</itunes:title>
            <link>https://e.example/1</link>
          </item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.items.first?.title, "Real Title")
    }

    func testGuidIsCapturedAndDrivesIdentity() throws {
        // Some feeds rewrite links between fetches while the guid stays put, so
        // guid wins for identity — otherwise read/unread state resets.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>x</title>
          <item><title>T</title><guid>urn:uuid:abc</guid><link>https://e.example/1</link></item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.items.first?.guid, "urn:uuid:abc")
        XCTAssertEqual(feed.items.first?.id, "urn:uuid:abc")
    }

    func testRelativeLinkResolvesAgainstFeedURL() throws {
        let base = URL(string: "https://news.example/feed.xml")!
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>x</title>
          <item><title>T</title><link>/article/1</link></item>
        </channel></rss>
        """.utf8), baseURL: base)
        XCTAssertEqual(feed.items.first?.link?.absoluteString, "https://news.example/article/1")
    }

    func testRelativeLinkWithoutBaseIsDroppedNotKeptBroken() throws {
        // A host-less URL looks fine in a struct and fails silently when tapped.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>x</title>
          <item><title>T</title><link>/article/1</link></item>
        </channel></rss>
        """.utf8))
        XCTAssertNil(feed.items.first?.link)
    }

    func testItunesDurationForms() {
        XCTAssertEqual(FeedParser.Delegate.parseDuration("3723"), 3723)
        XCTAssertEqual(FeedParser.Delegate.parseDuration("62:03"), 3723)
        XCTAssertEqual(FeedParser.Delegate.parseDuration("1:02:03"), 3723)
        XCTAssertNil(FeedParser.Delegate.parseDuration("about an hour"))
        XCTAssertNil(FeedParser.Delegate.parseDuration("1:2:3:4"))
    }

    func testArtworkFallsBackToChannel() throws {
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>Show</title>
          <itunes:image href="https://cdn.example/show.jpg"/>
          <item><title>Ep</title><enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.artwork?.absoluteString, "https://cdn.example/show.jpg")
        XCTAssertEqual(feed.items.first?.artwork?.absoluteString, "https://cdn.example/show.jpg")
    }

    func testChannelImageBlockDoesNotBecomeTheFeedTitle() throws {
        // <image> in an RSS channel has its own <title> and <link>.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel>
          <image><url>https://cdn.example/logo.png</url><title>Logo Alt Text</title></image>
          <title>Real Feed Title</title>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(feed.title, "Real Feed Title")
        XCTAssertEqual(feed.artwork?.absoluteString, "https://cdn.example/logo.png")
    }

    func testMediaRSSContentBecomesVideo() throws {
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
        <channel><title>Vids</title>
          <item><title>V</title>
            <media:content url="https://cdn.example/v.mp4" type="video/mp4"/>
          </item>
        </channel></rss>
        """.utf8))
        XCTAssertTrue(feed.items.first?.media?.isVideo == true)
        XCTAssertFalse(feed.isPodcast, "video is not audio")
    }
}
