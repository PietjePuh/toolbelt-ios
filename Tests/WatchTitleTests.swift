import XCTest
@testable import Toolbelt

final class WatchTitleTests: XCTestCase {

    // MARK: - IMDb linking

    func testExactIMDbLinkWhenIDKnown() {
        let t = WatchTitle(id: 1, kind: .movie, name: "Dune", imdbID: "tt1160419")
        XCTAssertEqual(t.imdbLink, .exact(URL(string: "https://www.imdb.com/title/tt1160419/")!))
        XCTAssertTrue(t.imdbLink.isExact)
    }

    func testSearchLinkWhenIDUnknown() {
        // Trending responses carry no imdb_id, which is the common case. A
        // search link is honest; a fabricated tt-id would not be.
        let t = WatchTitle(id: 1, kind: .movie, name: "Dune", year: 2021)
        guard case .search(let url) = t.imdbLink else { return XCTFail("expected a search link") }
        XCTAssertFalse(t.imdbLink.isExact)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.imdb.com/find/"))
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "Dune 2021")
    }

    func testTitleWithSpecialCharactersIsEncoded() {
        let t = WatchTitle(id: 1, kind: .series, name: "Tom & Jerry: 100% Fun?")
        let url = t.imdbLink.url
        let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? ""
        XCTAssertFalse(rawQuery.contains(" "), "unencoded space in the query")
        // …and it round-trips back to exactly what we asked for.
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "Tom & Jerry: 100% Fun?")
    }

    func testMalformedIMDbIDIsRefusedNotPastedIntoAURL() {
        // The id comes from a third party. A malformed one must not become a
        // dead link that looks authoritative — fall back to search instead.
        for bad in ["nm0000138", "tt", "1160419", "tt12a34", "", "tt1160419/../evil"] {
            let t = WatchTitle(id: 1, kind: .movie, name: "X", imdbID: bad)
            XCTAssertFalse(t.imdbLink.isExact, "\(bad) should not produce an exact link")
        }
    }

    func testIMDbIDIsCaseAndWhitespaceTolerant() {
        let t = WatchTitle(id: 1, kind: .movie, name: "X", imdbID: "  TT1160419 ")
        XCTAssertEqual(t.imdbLink, .exact(URL(string: "https://www.imdb.com/title/tt1160419/")!))
    }

    // MARK: - decoding

    func testDecodesMixedTrendingPage() throws {
        let page = try WatchTitle.decodePage(Data("""
        {"results":[
          {"id":1,"media_type":"movie","title":"A Film","release_date":"2026-03-01",
           "vote_average":7.4,"vote_count":812,"poster_path":"/a.jpg","overview":"x"},
          {"id":2,"media_type":"tv","name":"A Series","first_air_date":"2025-11-20",
           "vote_average":8.1,"vote_count":40},
          {"id":3,"media_type":"person","name":"Someone"}
        ]}
        """.utf8))
        XCTAssertEqual(page.titles.count, 2)
        XCTAssertEqual(page.skipped, 1, "a person is not something to watch")
        XCTAssertEqual(page.titles[0].kind, .movie)
        XCTAssertEqual(page.titles[0].year, 2026)
        XCTAssertEqual(page.titles[1].kind, .series)
        XCTAssertEqual(page.titles[1].name, "A Series")
        XCTAssertEqual(page.titles[1].year, 2025)
    }

    func testDefaultKindAppliesWhenEndpointIsSingleType() throws {
        // /movie/upcoming omits media_type entirely.
        let page = try WatchTitle.decodePage(Data("""
        {"results":[{"id":9,"title":"Upcoming","release_date":"2026-12-01"}]}
        """.utf8), defaultKind: .movie)
        XCTAssertEqual(page.titles.first?.kind, .movie)
    }

    func testZeroVotesIsNotARatingOfZero() throws {
        let page = try WatchTitle.decodePage(Data("""
        {"results":[{"id":1,"title":"Unrated","vote_average":0.0,"vote_count":0}]}
        """.utf8), defaultKind: .movie)
        XCTAssertNil(page.titles.first?.rating, "no votes must read as no rating, not 0/10")
    }

    func testMissingOrJunkDateYieldsNilYear() throws {
        let page = try WatchTitle.decodePage(Data("""
        {"results":[{"id":1,"title":"A","release_date":""},
                    {"id":2,"title":"B","release_date":"soon"},
                    {"id":3,"title":"C"}]}
        """.utf8), defaultKind: .movie)
        XCTAssertEqual(page.titles.count, 3)
        XCTAssertTrue(page.titles.allSatisfy { $0.year == nil })
    }

    func testUnreadableRowsAreCountedNotSilentlyDropped() throws {
        let page = try WatchTitle.decodePage(Data("""
        {"results":[{"id":1,"title":"Good"},{"title":"No id"},{"id":3}]}
        """.utf8), defaultKind: .movie)
        XCTAssertEqual(page.titles.count, 1)
        XCTAssertEqual(page.skipped, 2)
    }

    func testGarbageResponseThrows() {
        XCTAssertThrowsError(try WatchTitle.decodePage(Data("<html>nope</html>".utf8)))
    }

    func testPosterURLOnlyWhenPathPresent() {
        XCTAssertNil(WatchTitle(id: 1, kind: .movie, name: "X").posterURL)
        XCTAssertNil(WatchTitle(id: 1, kind: .movie, name: "X", posterPath: "").posterURL)
        XCTAssertEqual(WatchTitle(id: 1, kind: .movie, name: "X", posterPath: "/p.jpg").posterURL?
            .absoluteString, "https://image.tmdb.org/t/p/w342/p.jpg")
    }

    // MARK: - catalogue

    func testNoKeyIsNotConfiguredNotAnEmptyList() async {
        // The distinction the UI depends on: "you have not set this up" must
        // never render as "nothing is trending".
        for key in [nil, "", "   "] as [String?] {
            let catalog = WatchCatalog(apiKey: key)
            XCTAssertFalse(catalog.isConfigured)
            do {
                _ = try await catalog.load(.trendingMovies)
                XCTFail("expected notConfigured")
            } catch {
                XCTAssertEqual(error as? WatchCatalog.CatalogError, .notConfigured)
            }
        }
    }

    func testKeyNeverAppearsInTheURL() {
        // Query strings end up in logs, proxies and Referer headers.
        for feed in WatchCatalog.Feed.allCases {
            let url = WatchCatalog.url(for: feed).absoluteString
            XCTAssertFalse(url.lowercased().contains("api_key"))
            XCTAssertTrue(url.hasPrefix("https://api.themoviedb.org/3/"))
        }
    }
}
