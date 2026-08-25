import Foundation

/// An in-app log the user can read and send on.
///
/// It exists because this app is used away from a computer: when a feed will
/// not load or a host will not answer, there is no console to look at. Without
/// this, "it does not work" is the entire bug report.
///
/// THE LOG IS MEANT TO BE SHARED, so redaction is not a nicety. This app
/// handles IPTV playlist URLs that carry `username=` and `password=` in the
/// query string, a TMDB bearer token, and SSH usernames. Anything that reaches
/// a log the user might paste into a message has to be scrubbed on the way in
/// — scrubbing on export would leave the secrets sitting in memory and in any
/// future export path someone adds later.
@MainActor
public final class DiagnosticLog: ObservableObject {

    public static let shared = DiagnosticLog()

    public enum Level: String, Sendable, CaseIterable {
        case debug, info, warning, error

        public var label: String { rawValue.uppercased() }
        /// Ordering for the level filter.
        public var severity: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }
    }

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let at: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    /// Bounded on purpose. An unbounded log on a phone is a memory leak that
    /// only shows up after a long session, which is exactly when you need it.
    public static let capacity = 500

    @Published public private(set) var entries: [Entry] = []

    private init() {}

    public func log(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(at: Date(), level: level, category: category,
                          message: Self.redact(message))
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public func clear() { entries.removeAll() }

    /// Plain text, for sharing. Already redacted, because redaction happened
    /// on the way in.
    public func export() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let body = entries.map { entry in
            "\(formatter.string(from: entry.at)) [\(entry.level.label)] \(entry.category): \(entry.message)"
        }.joined(separator: "\n")

        return """
        Toolbelt diagnostics
        \(entries.count) entries (cap \(Self.capacity))

        Credentials in URLs and tokens are removed automatically. Read it \
        before sending it on anyway.

        \(body)
        """
    }

    // MARK: - redaction

    /// Query parameters whose values are credentials. IPTV providers put
    /// `username` and `password` straight in the playlist URL, so this is the
    /// common case rather than an edge one.
    static let secretParameters: Set<String> = [
        "password", "pass", "pwd", "username", "user",
        "token", "access_token", "auth", "auth_token",
        "api_key", "apikey", "key", "secret", "session", "sid"
    ]

    public static let placeholder = "‹redacted›"

    /// Applied on the way IN, so a secret is never in memory as an entry and
    /// cannot leak through a future export path that forgets to scrub.
    public static func redact(_ raw: String) -> String {
        var out = redactQueryParameters(in: raw)
        out = redactBearerTokens(in: out)
        out = redactURLUserInfo(in: out)
        return out
    }

    static func redactQueryParameters(in raw: String) -> String {
        // Deliberately textual rather than URL-parsed: log lines contain URLs
        // embedded in prose, and a strict parser would miss those and leak.
        var result = raw
        for name in secretParameters {
            for separator in ["?", "&", ";"] {
                result = replaceParameter(name, separator: separator, in: result)
            }
        }
        return result
    }

    private static func replaceParameter(_ name: String, separator: String,
                                         in text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        let needle = "\(separator)\(name)="

        while let range = remainder.range(of: needle, options: .caseInsensitive) {
            result += remainder[remainder.startIndex..<range.upperBound]
            let after = remainder[range.upperBound...]
            // The value ends at the next delimiter, or at whitespace when the
            // URL is sitting inside a sentence.
            let end = after.firstIndex { $0 == "&" || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\"" }
                ?? after.endIndex
            result += placeholder
            remainder = after[end...]
        }
        return result + remainder
    }

    static func redactBearerTokens(in raw: String) -> String {
        var result = ""
        var remainder = Substring(raw)
        while let range = remainder.range(of: "Bearer ", options: .caseInsensitive) {
            result += remainder[remainder.startIndex..<range.upperBound]
            let after = remainder[range.upperBound...]
            let end = after.firstIndex { $0 == " " || $0 == "\n" || $0 == "\"" } ?? after.endIndex
            result += placeholder
            remainder = after[end...]
        }
        return result + remainder
    }

    /// `https://user:pass@host/…` — credentials in the authority.
    static func redactURLUserInfo(in raw: String) -> String {
        var result = ""
        var remainder = Substring(raw)
        while let schemeRange = remainder.range(of: "://") {
            let afterScheme = remainder[schemeRange.upperBound...]
            let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == " " || $0 == "\n" }
                ?? afterScheme.endIndex
            let authority = afterScheme[afterScheme.startIndex..<authorityEnd]

            result += remainder[remainder.startIndex..<schemeRange.upperBound]
            if let at = authority.lastIndex(of: "@") {
                result += placeholder + authority[at...]
            } else {
                result += authority
            }
            remainder = afterScheme[authorityEnd...]
        }
        return result + remainder
    }
}
