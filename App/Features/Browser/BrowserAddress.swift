import Foundation

/// Turns whatever the user typed — or whatever a feed item linked to — into a
/// URL the browser is allowed to open.
///
/// Kept separate from the view because this is the security-relevant half and
/// it is testable without a WebView. A browser that will open any scheme handed
/// to it by a third-party feed is a way to reach `file:`, `javascript:` and
/// custom app schemes from untrusted content.
public enum BrowserAddress {

    public enum Resolution: Equatable {
        case web(URL)
        /// Not a URL at all — treat as a search term.
        case search(String)
        /// A URL we refuse to open, with the reason to show.
        case refused(String)
    }

    /// Schemes the in-app browser will load. Everything else is refused rather
    /// than handed to the system: `javascript:` executes in page context,
    /// `file:` reads the app container, `data:` renders attacker-controlled
    /// markup under the previous page's address.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func resolve(_ raw: String) -> Resolution {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .search("") }

        // An explicit scheme is honoured or refused — never silently rewritten.
        if let scheme = explicitScheme(of: input) {
            guard allowedSchemes.contains(scheme) else {
                return .refused("\(scheme): links are not opened in the browser")
            }
            guard let url = URL(string: input), url.host != nil else {
                return .refused("that does not look like a web address")
            }
            return .web(url)
        }

        // No scheme. Something with a dot and no spaces is a host; anything
        // else is a search. "localhost" deliberately does not qualify — this
        // browser is for the public web.
        if looksLikeHost(input), let url = URL(string: "https://\(input)"), url.host != nil {
            return .web(url)
        }
        return .search(input)
    }

    static func explicitScheme(of s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let head = s[s.startIndex..<colon].lowercased()
        guard !head.isEmpty,
              head.first!.isLetter,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return head
    }

    static func looksLikeHost(_ s: String) -> Bool {
        guard !s.contains(" "), s.contains(".") else { return false }
        // A trailing dot is legal in DNS but reads as a sentence ending.
        let host = s.split(separator: "/").first.map(String.init) ?? s
        guard let label = host.split(separator: ".").last, label.count >= 2 else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// What to put in the address bar. The registrable host is shown plainly
    /// and never truncated away — a browser that hides which site you are on is
    /// a phishing aid, which is why the roadmap put "URL visible at all times"
    /// in the requirements rather than the polish list.
    public static func display(_ url: URL) -> (host: String, isSecure: Bool, full: String) {
        // `url.host` yields the punycode form for internationalised domains, so
        // a homograph attack shows as `xn--…` rather than as the lookalike.
        let host = url.host ?? url.absoluteString
        return (host, url.scheme?.lowercased() == "https", url.absoluteString)
    }

    /// Search fallback. DuckDuckGo because it does not require an account and
    /// does not personalise on identity.
    public static func searchURL(_ term: String) -> URL {
        var comps = URLComponents(string: "https://duckduckgo.com/")!
        comps.percentEncodedQuery = "q=" + WatchTitle.encodeQueryValue(term)
        return comps.url!
    }
}
