import XCTest
@testable import Toolbelt

final class QuoteTests: XCTestCase {

    private func makeQuote(asOf: Date, state: Quote.MarketState) -> Quote {
        Quote(symbol: "AAPL", name: "Apple", price: 100, currency: "USD",
              change: 1, changePercent: 1, asOf: asOf, marketState: state)
    }

    // MARK: - staleness, the point of this type

    func testOpenAndRecentIsLive() {
        let now = Date()
        let quote = makeQuote(asOf: now.addingTimeInterval(-60), state: .regular)
        XCTAssertEqual(quote.staleness(now: now), .live)
    }

    func testClosedMarketReportsPreviousCloseNotStale() {
        // A closed market is not a broken feed. Calling it stale would cry wolf
        // every evening and train the user to ignore the warning.
        let now = Date()
        let quote = makeQuote(asOf: now.addingTimeInterval(-20 * 3600), state: .closed)
        XCTAssertEqual(quote.staleness(now: now), .lastClose)
    }

    func testOpenButNotUpdatingIsReportedAsStale() {
        // The dangerous case: the venue says it is open, so the number LOOKS
        // live, but nothing has arrived for an hour.
        let now = Date()
        let quote = makeQuote(asOf: now.addingTimeInterval(-60 * 60), state: .regular)
        guard case .stale(let minutes) = quote.staleness(now: now) else {
            return XCTFail("expected .stale")
        }
        XCTAssertEqual(minutes, 60)
    }

    func testMissingTimestampIsUnknownAgeNotLive() {
        // An absent exchange timestamp must not be dressed up as either fresh
        // or "previous close" — the age is genuinely unknown.
        let quote = Quote(symbol: "X", name: nil, price: 1, currency: "USD",
                          change: nil, changePercent: nil,
                          asOf: Date(timeIntervalSince1970: 0), marketState: .regular)
        XCTAssertFalse(quote.hasTimestamp)
        XCTAssertEqual(quote.staleness(now: Date()), .unknownAge)
    }

    func testPreAndPostMarketAreTreatedAsTrading() {
        let now = Date()
        for state: Quote.MarketState in [.pre, .post] {
            XCTAssertEqual(makeQuote(asOf: now.addingTimeInterval(-30), state: state)
                .staleness(now: now), .live)
        }
    }

    // MARK: - parsing

    func testParsesAQuote() throws {
        let body = Data("""
        {"chart":{"result":[{"meta":{
          "symbol":"AAPL","currency":"USD","regularMarketPrice":214.5,
          "previousClose":210.0,"regularMarketTime":1756000000,
          "marketState":"REGULAR","longName":"Apple Inc."}}]}}
        """.utf8)
        let quote = try QuoteService.parse(body, symbol: "AAPL")

        XCTAssertEqual(quote.symbol, "AAPL")
        XCTAssertEqual(quote.name, "Apple Inc.")
        XCTAssertEqual(quote.price, 214.5)
        XCTAssertEqual(quote.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(quote.change), 4.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), 2.142857, accuracy: 0.0001)
        XCTAssertEqual(quote.marketState, .regular)
        XCTAssertTrue(quote.hasTimestamp)
    }

    func testUnknownPreviousCloseYieldsNilChangeNotZero() throws {
        // "Flat" and "we do not know" are different claims about the market,
        // and a green 0.00% is the wrong one to make up.
        let body = Data("""
        {"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10.0,
         "marketState":"CLOSED"}}]}}
        """.utf8)
        let quote = try QuoteService.parse(body, symbol: "X")
        XCTAssertNil(quote.change)
        XCTAssertNil(quote.changePercent)
    }

    func testZeroPreviousCloseDoesNotProduceInfinity() throws {
        let body = Data("""
        {"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10.0,
         "previousClose":0.0,"marketState":"CLOSED"}}]}}
        """.utf8)
        let quote = try QuoteService.parse(body, symbol: "X")
        XCTAssertNil(quote.changePercent, "division by a zero close must not produce infinity")
    }

    func testMissingTimestampDoesNotBecomeNow() throws {
        // The failure this prevents: stamping `now` on an undated price
        // relabels an unknown-age number as live.
        let body = Data("""
        {"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10.0,
         "marketState":"REGULAR"}}]}}
        """.utf8)
        let quote = try QuoteService.parse(body, symbol: "X")
        XCTAssertFalse(quote.hasTimestamp)
    }

    func testNoPriceThrowsRatherThanReturningZero() {
        let body = Data("""
        {"chart":{"result":[{"meta":{"symbol":"X","marketState":"CLOSED"}}]}}
        """.utf8)
        XCTAssertThrowsError(try QuoteService.parse(body, symbol: "X")) { err in
            XCTAssertEqual(err as? QuoteService.ServiceError, .noData(symbol: "X"))
        }
    }

    func testEmptyOrGarbageResponseThrows() {
        for body in ["{}", "{\"chart\":{\"result\":[]}}", "<html>nope</html>"] {
            XCTAssertThrowsError(try QuoteService.parse(Data(body.utf8), symbol: "X"), body)
        }
    }

    func testUnknownMarketStateFallsBackRatherThanThrowing() throws {
        let body = Data("""
        {"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":1.0,
         "regularMarketTime":1756000000,"marketState":"HALTED"}}]}}
        """.utf8)
        let quote = try QuoteService.parse(body, symbol: "X")
        XCTAssertEqual(quote.marketState, .unknown)
        XCTAssertEqual(quote.staleness(now: Date()), .lastClose,
                       "an unrecognised state must not be treated as live trading")
    }

    // MARK: - symbols

    func testSymbolNormalisation() {
        XCTAssertEqual(QuoteService.normalise("  aapl "), "AAPL")
        XCTAssertEqual(QuoteService.normalise("asml.as"), "ASML.AS")
        XCTAssertEqual(QuoteService.normalise("^aex"), "^AEX")
        XCTAssertEqual(QuoteService.normalise("brk-b"), "BRK-B")
        XCTAssertEqual(QuoteService.normalise("EURUSD=X"), "EURUSD=X")
    }

    func testSymbolCannotSmuggleAPathOrQuery() {
        // The symbol goes into the URL path. A slash or a question mark would
        // let a pasted string retarget the request.
        XCTAssertEqual(QuoteService.normalise("AAPL/../../admin"), "AAPL....ADMIN")
        XCTAssertEqual(QuoteService.normalise("AAPL?x=1"), "AAPLX1")
        XCTAssertFalse(QuoteService.normalise("A/B").contains("/"))
    }

    func testBuiltURLIsTheExpectedEndpoint() {
        let url = QuoteService.url(for: "ASML.AS").absoluteString
        XCTAssertTrue(url.hasPrefix("https://query1.finance.yahoo.com/v8/finance/chart/ASML.AS"))
    }
}
