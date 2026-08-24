import Foundation

/// "What to watch out for" — trending and upcoming movies and series.
///
/// The API key is the USER's, entered in settings. None is shipped: a key
/// baked into a public sideloaded app is a key that is published, and the
/// whole design of this app is that the user brings their own connection and
/// credentials. TMDB keys are free and self-service.
public struct WatchCatalog: Sendable {

    public enum Feed: String, CaseIterable, Sendable {
        case trendingMovies, trendingSeries, upcomingMovies, airingSeries

        var path: String {
            switch self {
            case .trendingMovies: return "/3/trending/movie/week"
            case .trendingSeries: return "/3/trending/tv/week"
            case .upcomingMovies: return "/3/movie/upcoming"
            case .airingSeries:   return "/3/tv/on_the_air"
            }
        }
        var kind: WatchTitle.Kind {
            switch self {
            case .trendingMovies, .upcomingMovies: return .movie
            case .trendingSeries, .airingSeries:   return .series
            }
        }
        public var label: String {
            switch self {
            case .trendingMovies: return "Trending films"
            case .trendingSeries: return "Trending series"
            case .upcomingMovies: return "In cinemas soon"
            case .airingSeries:   return "Airing now"
            }
        }
    }

    public enum CatalogError: Error, Equatable {
        /// No API key set. DISTINCT from an empty result: "you have not set this
        /// up" and "there is nothing trending this week" must not look alike.
        case notConfigured
        /// The key was rejected. Also distinct — it tells the user to fix the
        /// key rather than to retry later.
        case keyRejected
        case gateway(Gateway.Failure)
    }

    private let gateway: Gateway
    private let apiKey: String?

    public init(gateway: Gateway = Gateway(), apiKey: String?) {
        self.gateway = gateway
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        !(apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func load(_ feed: Feed) async throws -> WatchTitle.Page {
        guard isConfigured, let key = apiKey else { throw CatalogError.notConfigured }

        let request = Gateway.Request(
            url: Self.url(for: feed),
            headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json"
            ]
        )

        let response: Gateway.Response
        do {
            response = try await gateway.send(request)
        } catch let f as Gateway.Failure {
            throw CatalogError.gateway(f)
        }

        // 401 is the user's key; every other status is the service's problem.
        // Conflating them sends people to re-check a key that was fine.
        if response.status == 401 || response.status == 403 { throw CatalogError.keyRejected }
        guard (200..<300).contains(response.status) else {
            throw CatalogError.gateway(.http(status: response.status))
        }

        do {
            return try WatchTitle.decodePage(response.body, defaultKind: feed.kind)
        } catch {
            throw CatalogError.gateway(.malformed("unexpected catalogue response"))
        }
    }

    static func url(for feed: Feed) -> URL {
        var comps = URLComponents(string: "https://api.themoviedb.org")!
        comps.path = feed.path
        // The key goes in the Authorization header, never the query string:
        // query strings land in logs, proxies and Referer headers.
        comps.queryItems = [.init(name: "language", value: "en-US")]
        return comps.url!
    }
}
