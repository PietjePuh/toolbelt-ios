import Foundation

/// Read-only market data.
///
/// There is no order path here and there never will be. The desktop Toolbelt's
/// trading guarantees hold because exactly one component can place an order;
/// adding a second one on a device that can be lost or stolen would give that
/// up for a convenience nobody asked for. This fetches numbers and shows them.
public struct QuoteService: Sendable {

    public enum ServiceError: Error, Equatable {
        case unreachable(String)
        case http(status: Int)
        /// The response parsed, but carried no usable price.
        case noData(symbol: String)
        case unknownSymbol(String)

        public var summary: String {
            switch self {
            case .unreachable:            return "Could not reach market data"
            case .http(let status):       return "The data provider answered with \(status)"
            case .noData(let symbol):     return "No price available for \(symbol)"
            case .unknownSymbol(let s):   return "\(s) is not a symbol the provider knows"
            }
        }
    }

    private let gateway: Gateway

    public init(gateway: Gateway = Gateway()) { self.gateway = gateway }

    public func quote(for symbol: String) async throws -> Quote {
        let clean = Self.normalise(symbol)
        guard !clean.isEmpty else { throw ServiceError.unknownSymbol(symbol) }

        let response: Gateway.Response
        do {
            response = try await gateway.send(.init(url: Self.url(for: clean), timeout: 15))
        } catch let f as Gateway.Failure {
            switch f {
            case .unreachable(let why), .refused(let why), .malformed(let why):
                throw ServiceError.unreachable(why)
            case .http(let status):
                // The provider returns 404 for a symbol it does not know, which
                // is a different thing for the user to fix than an outage.
                throw status == 404 ? ServiceError.unknownSymbol(clean)
                                    : ServiceError.http(status: status)
            }
        }

        if response.status == 404 { throw ServiceError.unknownSymbol(clean) }
        guard (200..<300).contains(response.status) else {
            throw ServiceError.http(status: response.status)
        }
        return try Self.parse(response.body, symbol: clean)
    }

    /// Symbols are uppercase, no whitespace. A stray lowercase ticker is a
    /// typo, not a different instrument.
    static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "^" || $0 == "=" }
    }

    static func url(for symbol: String) -> URL {
        var comps = URLComponents(string: "https://query1.finance.yahoo.com")!
        comps.path = "/v8/finance/chart/\(symbol)"
        comps.queryItems = [
            .init(name: "range", value: "1d"),
            .init(name: "interval", value: "1d")
        ]
        return comps.url!
    }

    static func parse(_ data: Data, symbol: String) throws -> Quote {
        struct Envelope: Decodable {
            struct Chart: Decodable {
                struct Result: Decodable {
                    struct Meta: Decodable {
                        let symbol: String?
                        let currency: String?
                        let regularMarketPrice: Double?
                        let chartPreviousClose: Double?
                        let previousClose: Double?
                        let regularMarketTime: Double?
                        let marketState: String?
                        let longName: String?
                        let shortName: String?
                    }
                    let meta: Meta?
                }
                let result: [Result]?
            }
            let chart: Chart?
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let meta = env.chart?.result?.first?.meta,
              let price = meta.regularMarketPrice else {
            throw ServiceError.noData(symbol: symbol)
        }

        let previous = meta.previousClose ?? meta.chartPreviousClose
        // An unknown previous close yields nil, NOT a change of zero — "flat"
        // and "we do not know" are different claims about the market.
        let change = previous.map { price - $0 }
        let percent: Double? = {
            guard let previous, previous != 0, let change else { return nil }
            return change / previous * 100
        }()

        // An absent timestamp must not become `now` — that would relabel an
        // unknown-age price as live, which is the exact failure this feature is
        // built to avoid.
        let stamped = meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) }

        return Quote(
            symbol: meta.symbol ?? symbol,
            name: meta.longName ?? meta.shortName,
            price: price,
            currency: meta.currency ?? "",
            change: change,
            changePercent: percent,
            asOf: stamped ?? Date(timeIntervalSince1970: 0),
            marketState: Quote.MarketState(rawValue: (meta.marketState ?? "").lowercased()) ?? .unknown
        )
    }
}
