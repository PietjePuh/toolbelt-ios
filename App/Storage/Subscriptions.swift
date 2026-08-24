import Foundation

/// The user's saved feeds, podcasts and playlists.
///
/// This is the first thing in the app that persists anything, so it sets the
/// pattern: a small injectable backing store (so it is testable without
/// touching the real defaults), JSON encoding, and — the part that matters —
/// **it will not overwrite data it could not read.** A decode failure means the
/// list is reported as unreadable, not silently replaced with an empty one that
/// the next save would make permanent.
public struct Subscription: Codable, Equatable, Sendable, Identifiable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case news, podcast, liveTV, music

        public var label: String {
            switch self {
            case .news:    return "News"
            case .podcast: return "Podcasts"
            case .liveTV:  return "Live TV"
            case .music:   return "Radio"
            }
        }
    }

    public let id: UUID
    public let url: URL
    public var title: String
    public var kind: Kind
    public let addedAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, kind: Kind, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.kind = kind
        self.addedAt = addedAt
    }
}

/// Minimal persistence seam. `UserDefaults` in the app, a dictionary in tests.
public protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
}

extension UserDefaults: KeyValueStore {
    public func set(_ value: Data?, forKey key: String) {
        if let value { set(value as Any?, forKey: key) } else { removeObject(forKey: key) }
    }
}

public final class SubscriptionStore {

    public enum StoreError: Error, Equatable {
        /// Refused at the point the user can fix it. Everything outbound goes
        /// through the gateway, which is https-only, so an http feed would fail
        /// on every refresh instead — long after the user forgot adding it.
        case insecureURL
        case notAWebURL
        /// Already subscribed. Distinct from a generic failure so the UI can
        /// point at the existing row rather than saying "could not add".
        case duplicate(existing: Subscription)
        /// Stored data could not be decoded. No write is performed while this
        /// is true — a corrupt read must not become a permanent empty list.
        case unreadable
    }

    private let store: KeyValueStore
    private let key: String
    private var cache: [Subscription] = []

    /// True when the stored blob exists but could not be decoded. Surfaced so
    /// the UI can say "your list could not be read" and offer an explicit reset
    /// rather than quietly starting over.
    public private(set) var isUnreadable = false

    public init(store: KeyValueStore = UserDefaults.standard,
                key: String = "toolbelt.subscriptions.v1") {
        self.store = store
        self.key = key
        load()
    }

    private func load() {
        guard let data = store.data(forKey: key) else {
            cache = []
            isUnreadable = false
            return
        }
        do {
            cache = try JSONDecoder().decode([Subscription].self, from: data)
            isUnreadable = false
        } catch {
            cache = []
            isUnreadable = true
        }
    }

    public func all() -> [Subscription] { cache }

    public func all(kind: Subscription.Kind) -> [Subscription] {
        cache.filter { $0.kind == kind }
    }

    @discardableResult
    public func add(url rawURL: URL, title: String, kind: Subscription.Kind) throws -> Subscription {
        guard !isUnreadable else { throw StoreError.unreadable }

        guard let scheme = rawURL.scheme?.lowercased() else { throw StoreError.notAWebURL }
        guard scheme == "http" || scheme == "https" else { throw StoreError.notAWebURL }
        guard scheme == "https" else { throw StoreError.insecureURL }
        guard rawURL.host != nil else { throw StoreError.notAWebURL }

        let canonical = Self.canonical(rawURL)
        if let existing = cache.first(where: { Self.canonical($0.url) == canonical }) {
            throw StoreError.duplicate(existing: existing)
        }

        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = Subscription(
            url: rawURL,
            title: name.isEmpty ? (rawURL.host ?? rawURL.absoluteString) : name,
            kind: kind
        )
        cache.append(sub)
        try persist()
        return sub
    }

    public func remove(id: UUID) throws {
        guard !isUnreadable else { throw StoreError.unreadable }
        cache.removeAll { $0.id == id }
        try persist()
    }

    public func rename(id: UUID, to title: String) throws {
        guard !isUnreadable else { throw StoreError.unreadable }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].title = name
        try persist()
    }

    /// Deliberate, user-initiated recovery from an unreadable store. The only
    /// path that discards data.
    public func resetAfterCorruption() throws {
        cache = []
        isUnreadable = false
        try persist()
    }

    private func persist() throws {
        store.set(try JSONEncoder().encode(cache), forKey: key)
    }

    /// Compares two feed URLs for "the same subscription": scheme and host
    /// case-folded, a default port dropped, one trailing slash ignored, and the
    /// fragment discarded — a fragment never changes which document is fetched.
    /// The query is KEPT: plenty of feeds are `?feed=rss` on a shared path.
    static func canonical(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        comps.fragment = nil
        if (comps.scheme == "https" && comps.port == 443) ||
           (comps.scheme == "http" && comps.port == 80) {
            comps.port = nil
        }
        if comps.path.count > 1 && comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        return comps.url?.absoluteString ?? url.absoluteString.lowercased()
    }
}
