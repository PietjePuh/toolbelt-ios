import XCTest
@testable import Toolbelt

final class PlaybackItemTests: XCTestCase {

    // MARK: - what is playable

    func testEpisodeFromAnAudioFeedItem() throws {
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>A Show</title>
          <item><title>Episode 1</title>
            <itunes:duration>1:02:03</itunes:duration>
            <enclosure url="https://cdn.example/1.mp3" type="audio/mpeg" length="99"/>
          </item>
        </channel></rss>
        """.utf8))

        let item = try XCTUnwrap(PlaybackItem(episode: feed.items[0], feedTitle: feed.title))
        XCTAssertEqual(item.title, "Episode 1")
        XCTAssertEqual(item.source, "A Show")
        XCTAssertEqual(item.duration, 3723)
        XCTAssertFalse(item.isLive)
    }

    func testArticleWithoutAudioIsNotPlayable() throws {
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>News</title>
          <item><title>An article</title><link>https://news.example/1</link></item>
        </channel></rss>
        """.utf8))
        XCTAssertNil(PlaybackItem(episode: feed.items[0], feedTitle: "News"),
                     "a news item must not become a playable track")
    }

    func testVideoEnclosureIsNotAnAudioTrack() throws {
        // The audio player would present a video as if it were a podcast.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
        <channel><title>Vids</title>
          <item><title>V</title>
            <media:content url="https://cdn.example/v.mp4" type="video/mp4"/></item>
        </channel></rss>
        """.utf8))
        XCTAssertNil(PlaybackItem(episode: feed.items[0], feedTitle: "Vids"))
    }

    // MARK: - live vs on-demand

    func testRadioStationIsAlwaysLive() throws {
        let playlist = try M3UPlaylist.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-logo="https://cdn.example/logo.png" group-title="Radio",NPO Radio 2
        https://stream.example/radio2.aac
        """)
        let station = try XCTUnwrap(playlist.channels.first)
        let item = PlaybackItem(station: station)

        XCTAssertEqual(item.title, "NPO Radio 2")
        XCTAssertEqual(item.source, "Radio")
        XCTAssertEqual(item.artwork?.absoluteString, "https://cdn.example/logo.png")
        XCTAssertTrue(item.isLive, "a stream has no end, so it must not offer a scrubber")
        XCTAssertNil(item.duration)
    }

    func testEpisodeWithNoStatedDurationIsNotTreatedAsLive() throws {
        // Absent metadata is not the same as an endless stream — the length is
        // simply not known yet, and AVPlayer fills it in once loaded.
        let feed = try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>S</title>
          <item><title>E</title>
            <enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8))
        let item = try XCTUnwrap(PlaybackItem(episode: feed.items[0], feedTitle: "S"))
        XCTAssertNil(item.duration)
        XCTAssertTrue(item.isLive,
                      "documented consequence: with no stated duration it starts as live and gains a scrubber once the length is known")
    }

    // MARK: - formatting

    func testTimeFormatting() {
        XCTAssertEqual(PlaybackItem.formatTime(0), "0:00")
        XCTAssertEqual(PlaybackItem.formatTime(61), "1:01")
        XCTAssertEqual(PlaybackItem.formatTime(3723), "1:02:03")
        // AVPlayer reports NaN/infinite before an item is ready; a label must
        // not render "nan:nan".
        XCTAssertEqual(PlaybackItem.formatTime(.nan), "--:--")
        XCTAssertEqual(PlaybackItem.formatTime(.infinity), "--:--")
        XCTAssertEqual(PlaybackItem.formatTime(-1), "--:--")
    }
}
