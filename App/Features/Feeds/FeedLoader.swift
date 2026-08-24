import Foundation

/// Fetches a feed and parses it, keeping the failure modes distinct all the way
/// to the UI.
///
/// The distinction that costs users time: "this feed is empty today" and "we
/// could not read this feed" look identical if both end up as an empty array.
/// Providers serve HTML error pages with a 200, so this is not hypothetical.
public struct FeedLoader: Sendable {

    public enum LoadError: Error, Equatable {
        case unreachable(String)
        case http(status: Int)
        /// Fetched fine, but the bytes are not a feed. Almost always a login
        /// wall or an error page served with a 200.
        case notAFeed
        case malformed(String)
        case tooLarge

        public var summary: String {
            switch self {
            case .unreachable:      return "Could not reach this feed"
            case .http(let status): return "The site answered with \(status)"
            case .notAFeed:         return "That address is not a feed"
            case .malformed:        return "This feed is malformed"
            case .tooLarge:         return "This feed is too large to read"
            }
        }

        public var detail: String {
            switch self {
            case .unreachable(let why): return why
            case .http(let status) where status == 404:
                return "The feed has moved or been withdrawn."
            case .http(let status) where status == 403 || status == 401:
                return "The site refused the request. Some feeds require a subscription."
            case .http:
                return "This is the site's problem, not your setup — it may work later."
            case .notAFeed:
                return "The address loaded, but returned a web page rather than a feed. Sites often serve a login page this way."
            case .malformed(let why): return why
            case .tooLarge:
                return "The feed exceeded the size limit this app will read into memory."
            }
        }
    }

    private let gateway: Gateway

    public init(gateway: Gateway = Gateway()) {
        self.gateway = gateway
    }

    public func load(_ url: URL) async throws -> FeedParser.Feed {
        let response: Gateway.Response
        do {
            response = try await gateway.send(.init(url: url, headers: [
                "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml"
            ]))
        } catch let f as Gateway.Failure {
            switch f {
            case .unreachable(let why): throw LoadError.unreachable(why)
            case .refused(let why):     throw LoadError.unreachable(why)
            case .http(let status):     throw LoadError.http(status: status)
            case .malformed(let why):   throw LoadError.malformed(why)
            }
        }

        guard (200..<300).contains(response.status) else {
            throw LoadError.http(status: response.status)
        }

        do {
            // The feed's own URL is the base, so relative item links resolve.
            return try FeedParser.parse(response.body, baseURL: url)
        } catch FeedParser.ParseError.notAFeed {
            throw LoadError.notAFeed
        } catch FeedParser.ParseError.tooLarge {
            throw LoadError.tooLarge
        } catch FeedParser.ParseError.malformedXML(let why) {
            // Real-world HTML is not well-formed XML, so a login page fails as
            // a PARSE error rather than as "no feed element". Reporting
            // "malformed feed (NSXMLParserErrorDomain 111)" is true and
            // useless — the user needs to know they pasted a web page.
            //
            // Sniffed only after parsing has already failed, so a genuine feed
            // served with a wrong content-type still loads.
            if Self.looksLikeHTML(response.body, contentType: response.headers["content-type"]) {
                throw LoadError.notAFeed
            }
            throw LoadError.malformed(why)
        }
    }

    /// Cheap HTML sniff over the first bytes. Only consulted once parsing has
    /// failed, so a false positive cannot hide a working feed.
    static func looksLikeHTML(_ body: Data, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("text/html") { return true }

        let head = String(decoding: body.prefix(1024), as: UTF8.self)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["<!doctype html", "<html", "<head", "<body"] where head.contains(marker) {
            return true
        }
        return false
    }

    /// Fetch a candidate URL to decide what it is before subscribing — so the
    /// user finds out at the moment of adding, not on the first refresh, and so
    /// the kind is set from what the feed CARRIES rather than from a guess.
    public func inspect(_ url: URL) async throws -> (title: String, kind: Subscription.Kind) {
        let feed = try await load(url)
        return (feed.title.isEmpty ? (url.host ?? url.absoluteString) : feed.title,
                feed.isPodcast ? .podcast : .news)
    }
}
