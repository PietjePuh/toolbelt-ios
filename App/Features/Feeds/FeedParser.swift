import Foundation

/// RSS 2.0 / Atom parsing, covering news feeds **and podcasts** — a podcast is
/// an RSS feed whose items carry an audio `<enclosure>`, so one parser serves
/// both and the player just gets a URL.
///
/// This eats XML from arbitrary hosts, which is the most hostile input in the
/// app. `XMLParser` is used in its default configuration deliberately:
/// `shouldResolveExternalEntities` stays **false**, which is what prevents
/// billion-laughs expansion and XXE reads of local files. That default is the
/// security control, so it is asserted in the tests rather than assumed.
public struct FeedParser {

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { link?.absoluteString ?? guid ?? title }
        public let title: String
        public let link: URL?
        public let published: Date?
        public let summary: String?
        /// Present when the item carries playable media — i.e. a podcast
        /// episode. `nil` for an ordinary news item.
        public let media: Media?

        public struct Media: Equatable, Sendable {
            public let url: URL
            public let mimeType: String?
            public let bytes: Int?
            public var isAudio: Bool { (mimeType ?? "").hasPrefix("audio/") }
            public var isVideo: Bool { (mimeType ?? "").hasPrefix("video/") }
        }
    }

    public struct Feed: Equatable, Sendable {
        public let title: String
        public let items: [Item]
        /// True when at least one item carries audio — the app can then offer
        /// it as a podcast rather than a reading list.
        public var isPodcast: Bool { items.contains { $0.media?.isAudio == true } }
    }

    public enum ParseError: Error, Equatable {
        /// Parsed as XML but carried no channel/feed element. Distinct from an
        /// EMPTY feed: "we could not understand this" must not render as "this
        /// feed has no items".
        case notAFeed
        case malformedXML(String)
        case tooLarge(bytes: Int)
    }

    /// Feeds are text. Anything past this is a mistake or hostile, and a phone
    /// should not stream it into memory to find out.
    public static let maxBytes = 16 * 1024 * 1024

    public static func parse(_ data: Data) throws -> Feed {
        guard data.count <= maxBytes else { throw ParseError.tooLarge(bytes: data.count) }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Explicit, though these are the defaults: external entity resolution
        // is what turns a feed into an XXE / billion-laughs vector.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            throw ParseError.malformedXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard delegate.sawFeedRoot else { throw ParseError.notAFeed }
        return Feed(title: delegate.feedTitle, items: delegate.items)
    }

    // MARK: - delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawFeedRoot = false
        var feedTitle = ""
        var items: [Item] = []

        private var path: [String] = []
        private var text = ""
        private var current: (title: String, link: URL?, date: Date?, summary: String?, media: Item.Media?)?

        func parser(_ p: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let name = element.lowercased()
            path.append(name)
            text = ""

            if name == "rss" || name == "feed" || name == "channel" { sawFeedRoot = true }

            if name == "item" || name == "entry" {
                current = (title: "", link: nil, date: nil, summary: nil, media: nil)
            }

            // RSS podcast enclosure, and Atom's <link rel="enclosure">.
            if name == "enclosure" || (name == "link" && attrs["rel"] == "enclosure") {
                let href = attrs["url"] ?? attrs["href"]
                if let href, let url = URL(string: href), Self.isPlayable(url) {
                    current?.media = Item.Media(
                        url: url,
                        mimeType: attrs["type"],
                        bytes: attrs["length"].flatMap(Int.init)
                    )
                }
            }

            // Atom's <link href="..."> for the item page itself.
            if name == "link", attrs["rel"] == nil || attrs["rel"] == "alternate",
               let href = attrs["href"], let url = URL(string: href), current != nil {
                current?.link = url
            }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ p: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = element.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { path.removeLast(); text = "" }

            let inItem = current != nil

            switch name {
            case "title":
                if inItem { current?.title = value } else if feedTitle.isEmpty { feedTitle = value }
            case "link":
                if inItem, current?.link == nil, let url = URL(string: value) { current?.link = url }
            case "pubdate", "published", "updated", "date":
                if inItem, current?.date == nil { current?.date = Self.parseDate(value) }
            case "description", "summary", "subtitle":
                if inItem, current?.summary == nil, !value.isEmpty { current?.summary = value }
            case "guid", "id":
                break
            case "item", "entry":
                if let c = current, !c.title.isEmpty || c.link != nil || c.media != nil {
                    items.append(Item(title: c.title.isEmpty ? "(untitled)" : c.title,
                                      link: c.link, published: c.date, summary: c.summary, media: c.media))
                }
                current = nil
            default:
                break
            }
        }

        /// Refuse anything the player has no business opening from a feed —
        /// notably `file:`. Same rule as the M3U parser.
        static func isPlayable(_ url: URL) -> Bool {
            guard let s = url.scheme?.lowercased() else { return false }
            return ["http", "https", "rtsp", "rtmp"].contains(s)
        }

        /// RFC 822 (RSS) and ISO 8601 (Atom). An unparsable date becomes nil
        /// rather than `now` — a wrong timestamp is worse than an absent one,
        /// because it silently reorders the feed.
        static func parseDate(_ s: String) -> Date? {
            if let d = rfc822.date(from: s) { return d }
            if let d = iso8601.date(from: s) { return d }
            if let d = iso8601NoFraction.date(from: s) { return d }
            return nil
        }

        private static let rfc822: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f
        }()
        private static let iso8601: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let iso8601NoFraction = ISO8601DateFormatter()
    }
}
