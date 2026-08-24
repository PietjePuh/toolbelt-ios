import XCTest
@testable import Toolbelt

/// Serves canned responses so the loader's failure mapping is tested for real
/// rather than by inspection. Keyed by URL so parallel tests cannot collide.
final class StubProtocol: URLProtocol, @unchecked Sendable {

    enum Outcome {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcomes: [String: Outcome] = [:]

    static func set(_ outcome: Outcome, for url: String) {
        lock.lock(); defer { lock.unlock() }
        outcomes[url] = outcome
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        outcomes.removeAll()
    }
    private static func outcome(for url: URL?) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        return url.flatMap { outcomes[$0.absoluteString] }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let outcome = Self.outcome(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch outcome {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class FeedLoaderTests: XCTestCase {

    private let feedURL = "https://news.example/feed.xml"

    private func makeLoader() -> FeedLoader {
        FeedLoader(gateway: Gateway(session: StubProtocol.session()))
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    func testLoadsAFeed() async throws {
        StubProtocol.set(.response(status: 200, body: Data("""
        <rss version="2.0"><channel><title>News</title>
          <item><title>One</title><link>https://news.example/1</link></item>
        </channel></rss>
        """.utf8)), for: feedURL)

        let feed = try await makeLoader().load(URL(string: feedURL)!)
        XCTAssertEqual(feed.title, "News")
        XCTAssertEqual(feed.items.count, 1)
    }

    func testHTMLServedWith200IsNotAFeedNotAnEmptyList() async {
        // The case that makes this whole type exist: sites serve login pages
        // and error pages with a 200. Reporting "no items" would be a lie.
        StubProtocol.set(.response(status: 200, body: Data("""
        <!doctype html><html><body><h1>Sign in to continue</h1></body></html>
        """.utf8)), for: feedURL)

        do {
            _ = try await makeLoader().load(URL(string: feedURL)!)
            XCTFail("expected notAFeed")
        } catch {
            XCTAssertEqual(error as? FeedLoader.LoadError, .notAFeed)
        }
    }

    func testHTTPStatusIsPreserved() async {
        StubProtocol.set(.response(status: 404, body: Data()), for: feedURL)
        do {
            _ = try await makeLoader().load(URL(string: feedURL)!)
            XCTFail("expected http(404)")
        } catch {
            XCTAssertEqual(error as? FeedLoader.LoadError, .http(status: 404))
            XCTAssertTrue((error as! FeedLoader.LoadError).detail.contains("moved"))
        }
    }

    func testOfflineIsUnreachableNotAParseFailure() async {
        StubProtocol.set(.failure(.notConnectedToInternet), for: feedURL)
        do {
            _ = try await makeLoader().load(URL(string: feedURL)!)
            XCTFail("expected unreachable")
        } catch {
            guard case .unreachable? = error as? FeedLoader.LoadError else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        }
    }

    func testPlainHTTPIsRefusedBeforeAnyRequest() async {
        do {
            _ = try await makeLoader().load(URL(string: "http://news.example/feed.xml")!)
            XCTFail("expected a refusal")
        } catch {
            guard case .unreachable? = error as? FeedLoader.LoadError else {
                return XCTFail("expected the https refusal, got \(error)")
            }
        }
    }

    func testRelativeItemLinksResolveAgainstTheFeedURL() async throws {
        StubProtocol.set(.response(status: 200, body: Data("""
        <rss version="2.0"><channel><title>News</title>
          <item><title>One</title><link>/article/1</link></item>
        </channel></rss>
        """.utf8)), for: feedURL)

        let feed = try await makeLoader().load(URL(string: feedURL)!)
        XCTAssertEqual(feed.items.first?.link?.absoluteString, "https://news.example/article/1")
    }

    // MARK: - inspect

    func testInspectDetectsAPodcastFromWhatItCarries() async throws {
        StubProtocol.set(.response(status: 200, body: Data("""
        <rss version="2.0"><channel><title>A Show</title>
          <item><title>Ep 1</title>
            <enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8)), for: feedURL)

        let result = try await makeLoader().inspect(URL(string: feedURL)!)
        XCTAssertEqual(result.title, "A Show")
        XCTAssertEqual(result.kind, .podcast, "kind comes from the enclosure, not from a guess")
    }

    func testInspectFallsBackToTheHostWhenAFeedHasNoTitle() async throws {
        StubProtocol.set(.response(status: 200, body: Data("""
        <rss version="2.0"><channel>
          <item><title>One</title><link>https://news.example/1</link></item>
        </channel></rss>
        """.utf8)), for: feedURL)

        let result = try await makeLoader().inspect(URL(string: feedURL)!)
        XCTAssertEqual(result.title, "news.example")
        XCTAssertEqual(result.kind, .news)
    }

    func testInspectFailsBeforeSubscribingToANonFeed() async {
        StubProtocol.set(.response(status: 200, body: Data("<html>not a feed</html>".utf8)),
                         for: feedURL)
        do {
            _ = try await makeLoader().inspect(URL(string: feedURL)!)
            XCTFail("a non-feed must not be subscribable")
        } catch {
            XCTAssertEqual(error as? FeedLoader.LoadError, .notAFeed)
        }
    }
}
