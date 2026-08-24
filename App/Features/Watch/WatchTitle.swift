import Foundation

/// A movie or series worth watching out for, and the link out to IMDb.
///
/// Discovery data comes from TMDB (free, keyed, and the only well-documented
/// catalogue API); IMDb is where the user actually wants to land. IMDb has no
/// public API, so the link is built rather than fetched — and the type is
/// explicit about whether it is an exact title link or a search, because those
/// are not the same promise.
public struct WatchTitle: Equatable, Sendable, Identifiable {

    public enum Kind: String, Sendable, Equatable {
        case movie, series
    }

    /// How confident the IMDb link is. A search URL always resolves to *a*
    /// page, so a UI that treats both the same would present a guess as a fact.
    public enum IMDbLink: Equatable, Sendable {
        /// We know the tt-id: lands on the title page.
        case exact(URL)
        /// We do not: lands on IMDb search for the title.
        case search(URL)

        public var url: URL {
            switch self {
            case .exact(let u), .search(let u): return u
            }
        }
        public var isExact: Bool {
            if case .exact = self { return true }
            return false
        }
    }

    public let id: Int
    public let kind: Kind
    public let name: String
    /// Release year, or nil. Never guessed — an invented year makes two
    /// different films look like the same one.
    public let year: Int?
    public let overview: String?
    public let posterPath: String?
    /// TMDB user score 0–10, or nil when nobody has voted. Zero votes is not a
    /// score of 0.
    public let rating: Double?
    /// IMDb tt-id when known. Trending responses do not carry it.
    public let imdbID: String?

    public init(id: Int, kind: Kind, name: String, year: Int? = nil,
                overview: String? = nil, posterPath: String? = nil,
                rating: Double? = nil, imdbID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.rating = rating
        self.imdbID = imdbID
    }

    public var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    public var imdbLink: IMDbLink {
        if let tt = Self.normaliseIMDbID(imdbID) {
            return .exact(URL(string: "https://www.imdb.com/title/\(tt)/")!)
        }
        // Encoded explicitly rather than via `queryItems`, whose setter leaves
        // some sub-delimiters alone — an ampersand in a title ("Tom & Jerry")
        // would otherwise split the query into an extra parameter and search
        // for half the name.
        var comps = URLComponents(string: "https://www.imdb.com/find/")!
        let term = year.map { "\(name) \($0)" } ?? name
        comps.percentEncodedQuery = "q=\(Self.encodeQueryValue(term))&s=tt"
        return .search(comps.url!)
    }

    /// `tt` followed by digits. Anything else is refused rather than pasted
    /// into a URL — the id comes from a third-party API, and a malformed one
    /// would silently produce a dead link that looks authoritative.
    static func normaliseIMDbID(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              s.hasPrefix("tt") else { return nil }
        let digits = s.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return s
    }

    /// Query-value encoding that also escapes the sub-delimiters which would
    /// change the SHAPE of the query rather than just its content.
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    static func encodeQueryValue(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    static func year(from dateString: String?) -> Int? {
        guard let s = dateString, s.count >= 4 else { return nil }
        let head = String(s.prefix(4))
        guard let y = Int(head), y > 1800, y < 2200 else { return nil }
        return y
    }
}

// MARK: - TMDB decoding

extension WatchTitle {

    /// One page of TMDB results. Written as an explicit decode rather than
    /// synthesised Codable because movies and series use different field names
    /// for the same thing (`title`/`name`, `release_date`/`first_air_date`) and
    /// a mixed "trending all" page contains both.
    public struct Page: Sendable {
        public let titles: [WatchTitle]
        /// Entries that could not be decoded — surfaced rather than dropped, so
        /// a schema change shows up as "8 of 20 unreadable" instead of a
        /// quietly short list.
        public let skipped: Int
    }

    public static func decodePage(_ data: Data, defaultKind: Kind? = nil) throws -> Page {
        struct Envelope: Decodable { let results: [Row] }
        struct Row: Decodable {
            let id: Int?
            let title: String?
            let name: String?
            let media_type: String?
            let release_date: String?
            let first_air_date: String?
            let overview: String?
            let poster_path: String?
            let vote_average: Double?
            let vote_count: Int?
            let imdb_id: String?
        }

        let env = try JSONDecoder().decode(Envelope.self, from: data)
        var out: [WatchTitle] = []
        var skipped = 0

        for row in env.results {
            let kind: Kind? = {
                switch row.media_type {
                case "movie": return .movie
                case "tv": return .series
                case .some: return nil          // `person`, or something new
                case nil: return defaultKind
                }
            }()
            let label = row.title ?? row.name
            guard let id = row.id, let kind, let label, !label.isEmpty else {
                skipped += 1
                continue
            }
            out.append(WatchTitle(
                id: id,
                kind: kind,
                name: label,
                year: year(from: row.release_date ?? row.first_air_date),
                overview: row.overview?.isEmpty == true ? nil : row.overview,
                posterPath: row.poster_path,
                // No votes is not a rating of zero.
                rating: (row.vote_count ?? 0) > 0 ? row.vote_average : nil,
                imdbID: row.imdb_id
            ))
        }
        return Page(titles: out, skipped: skipped)
    }
}
