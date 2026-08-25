import Foundation

/// A price, and — just as important — how old it is.
///
/// The rule this type exists to enforce: a stale price must never be presented
/// as a current one. Markets close, feeds lag, and a phone can be offline for
/// hours; a number with no time attached invites someone to act on a figure
/// that stopped being true yesterday. So `asOf` is not optional and the UI is
/// given `staleness` rather than being trusted to work it out.
public struct Quote: Equatable, Sendable, Identifiable {

    public var id: String { symbol }
    public let symbol: String
    public let name: String?
    public let price: Double
    public let currency: String
    /// Absolute change against the previous close. `nil` when the previous
    /// close is unknown — a change of 0 and an unknown change are not the same
    /// claim.
    public let change: Double?
    public let changePercent: Double?
    /// When the exchange stamped this price. Not when we fetched it.
    public let asOf: Date
    /// The venue's own view of whether it is open. Trusted over guessing from
    /// the clock, because holidays and half-days exist.
    public let marketState: MarketState

    public enum MarketState: String, Sendable, Equatable {
        case regular, pre, post, closed, unknown

        public var label: String {
            switch self {
            case .regular: return "Open"
            case .pre:     return "Pre-market"
            case .post:    return "After hours"
            case .closed:  return "Closed"
            case .unknown: return "Unknown"
            }
        }
    }

    public init(symbol: String, name: String?, price: Double, currency: String,
                change: Double?, changePercent: Double?, asOf: Date,
                marketState: MarketState) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.currency = currency
        self.change = change
        self.changePercent = changePercent
        self.asOf = asOf
        self.marketState = marketState
    }

    /// A price with no exchange timestamp. The provider omits it occasionally,
    /// and the age of such a print is genuinely unknown.
    public var hasTimestamp: Bool { asOf.timeIntervalSince1970 > 0 }

    public enum Staleness: Equatable, Sendable {
        /// The provider gave a price but no timestamp. Reported as its own
        /// state rather than guessed at: an unknown age must not be dressed up
        /// as either "live" or "last close".
        case unknownAge
        /// Live-ish: the venue is open and the print is recent.
        case live
        /// The venue is closed. Not a problem — but it IS the previous
        /// session's price, and must be labelled as such.
        case lastClose
        /// The venue says it is open, yet the price has not moved for a long
        /// time. Something is wrong with the feed, and that is worth saying
        /// rather than showing a confident number.
        case stale(minutes: Int)
    }

    /// Deliberately takes `now` rather than reading the clock, so this is
    /// testable and cannot drift between the view and the model.
    public func staleness(now: Date, tolerance: TimeInterval = 15 * 60) -> Staleness {
        guard hasTimestamp else { return .unknownAge }

        let age = now.timeIntervalSince(asOf)
        switch marketState {
        case .closed, .unknown:
            return .lastClose
        case .regular, .pre, .post:
            return age > tolerance ? .stale(minutes: Int(age / 60)) : .live
        }
    }
}
