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
        public var id: String { guid ?? link?.absoluteString ?? title }
        public let title: String
        public let link: URL?
        public let published: Date?
        public let summary: String?
        /// Feed-provided stable id. Preferred over the link for identity because
        /// some feeds reuse or rewrite links while the guid stays put.
        public let guid: String?
        /// Episode length in seconds, from `itunes:duration`.
        public let durationSeconds: Int?
        /// Present when the item carries playable media — i.e. a podcast
        /// episode. `nil` for an ordinary news item.
        public let media: Media?
        /// Episode or channel artwork.
        public let artwork: URL?

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
        /// Channel-level artwork, used when an item has none of its own.
        public let artwork: URL?
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

    /// - Parameter baseURL: the URL the feed was fetched from. Feeds legitimately
    ///   use relative links (`<link>/article/1</link>`); without a base those
    ///   parse to a URL with no host, which silently fails to open later. Absent
    ///   base means relative links are dropped rather than kept broken.
    public static func parse(_ data: Data, baseURL: URL? = nil) throws -> Feed {
        guard data.count <= maxBytes else { throw ParseError.tooLarge(bytes: data.count) }
        let delegate = Delegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Explicit, though these are the defaults: external entity resolution
        // is what turns a feed into an XXE / billion-laughs vector.
        parser.shouldResolveExternalEntities = false
        // Namespaces OFF deliberately: with them ON, XMLParser hands us the
        // LOCAL name, so `<itunes:title>` arrives as `title` and overwrites the
        // real item title — and podcast feeds carry one in almost every item.
        // Qualified names let us tell them apart.
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw ParseError.malformedXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard delegate.sawFeedRoot else { throw ParseError.notAFeed }
        return Feed(title: delegate.feedTitle, items: delegate.items, artwork: delegate.feedArtwork)
    }

    // MARK: - delegate

    internal final class Delegate: NSObject, XMLParserDelegate {
        var sawFeedRoot = false
        var feedTitle = ""
        var feedArtwork: URL?
        var items: [Item] = []

        private let baseURL: URL?
        init(baseURL: URL?) { self.baseURL = baseURL; super.init() }

        private var path: [String] = []
        private var text = ""
        private var current: Draft?

        private struct Draft {
            var title = ""
            var link: URL?
            var date: Date?
            var summary: String?
            var guid: String?
            var duration: Int?
            var media: Item.Media?
            var artwork: URL?
        }

        /// Resolve against the feed's own URL so relative links work. A relative
        /// link with no base is dropped, not kept as a host-less URL that fails
        /// silently when tapped.
        private func url(_ s: String?) -> URL? {
            guard let s, !s.isEmpty else { return nil }
            guard let u = URL(string: s, relativeTo: baseURL)?.absoluteURL else { return nil }
            return u.scheme == nil ? nil : u
        }

        func parser(_ p: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let name = element.lowercased()
            path.append(name)
            text = ""

            if name == "rss" || name == "feed" || name == "channel" { sawFeedRoot = true }

            if name == "item" || name == "entry" { current = Draft() }

            // RSS podcast enclosure, Atom's <link rel="enclosure">, and Media RSS
            // <media:content> (video podcasts and YouTube feeds use that one).
            if name == "enclosure" || name == "media:content"
                || (name == "link" && attrs["rel"] == "enclosure") {
                if let u = url(attrs["url"] ?? attrs["href"]), Self.isPlayable(u) {
                    // Media RSS carries `medium="audio"` where RSS carries a MIME
                    // type; normalise so isAudio/isVideo mean the same thing.
                    let mime = attrs["type"] ?? attrs["medium"].map { "\($0)/unknown" }
                    current?.media = Item.Media(url: u, mimeType: mime,
                                               bytes: attrs["length"].flatMap(Int.init))
                }
            }

            // Artwork: itunes:image carries it in an attribute, not as text.
            if name == "itunes:image" || name == "media:thumbnail" {
                if let u = url(attrs["href"] ?? attrs["url"]) {
                    if current != nil { current?.artwork = u } else if feedArtwork == nil { feedArtwork = u }
                }
            }

            if name == "link", attrs["rel"] == nil || attrs["rel"] == "alternate",
               let u = url(attrs["href"]), current != nil {
                current?.link = u
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
            // <image> in an RSS channel has its own <title>/<link>/<url>; those
            // are the artwork's, not the feed's.
            let inImage = path.dropLast().contains("image")
            defer { path.removeLast(); text = "" }

            let inItem = current != nil

            switch name {
            case "title":
                if inItem { current?.title = value }
                else if feedTitle.isEmpty && !inImage { feedTitle = value }
            case "url":
                if inImage, !inItem, feedArtwork == nil { feedArtwork = url(value) }
            case "link":
                if inItem, current?.link == nil { current?.link = url(value) }
            case "pubdate", "published", "updated", "date", "dc:date":
                if inItem, current?.date == nil { current?.date = Self.parseDate(value) }
            case "description", "summary", "subtitle", "itunes:summary", "content:encoded":
                if inItem, current?.summary == nil, !value.isEmpty { current?.summary = value }
            case "guid", "id":
                if inItem, current?.guid == nil, !value.isEmpty { current?.guid = value }
            case "itunes:duration":
                if inItem { current?.duration = Self.parseDuration(value) }
            case "item", "entry":
                if let c = current, !c.title.isEmpty || c.link != nil || c.media != nil {
                    items.append(Item(title: c.title.isEmpty ? "(untitled)" : c.title,
                                      link: c.link, published: c.date, summary: c.summary,
                                      guid: c.guid, durationSeconds: c.duration,
                                      media: c.media, artwork: c.artwork ?? feedArtwork))
                }
                current = nil
            default:
                break
            }
        }

        /// `itunes:duration` is "3723", "62:03" or "1:02:03" depending on the
        /// publisher. Anything else is nil — a wrong length misleads a progress
        /// bar, and no length just hides one.
        static func parseDuration(_ s: String) -> Int? {
            let parts = s.split(separator: ":").map(String.init)
            guard !parts.isEmpty, parts.count <= 3 else { return nil }
            var total = 0
            for part in parts {
                guard let n = Int(part), n >= 0 else { return nil }
                total = total * 60 + n
            }
            return total
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
