import Foundation

/// Scans a domain from **this device, over this connection**.
///
/// Each check is independent and reports its own outcome. A check that could
/// not be performed reports `.unknown` with the reason — never a clean result.
/// The desktop Toolbelt has been bitten repeatedly by scanners that render
/// "no findings" when what actually happened was "could not ask", and the same
/// mistake here would be worse: a user would conclude a host is fine.
public struct DomainScanner: Sendable {

    public enum Outcome: Sendable, Equatable {
        case ok(String)
        case finding(String)
        /// Could not determine. Carries why, and must never render as a pass.
        case unknown(String)
    }

    public struct Check: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let outcome: Outcome
    }

    public struct Report: Sendable, Equatable {
        public let domain: String
        public let checks: [Check]
        public let startedAt: Date
        public let finishedAt: Date

        /// True only if every check produced a definite result. Used by the UI
        /// to avoid saying "looks good" over a partial scan.
        public var isComplete: Bool {
            checks.allSatisfy { if case .unknown = $0.outcome { return false } else { return true } }
        }

        public var findings: [Check] {
            checks.filter { if case .finding = $0.outcome { return true } else { return false } }
        }

        public var unknowns: [Check] {
            checks.filter { if case .unknown = $0.outcome { return true } else { return false } }
        }
    }

    private let gateway: Gateway

    public init(gateway: Gateway) {
        self.gateway = gateway
    }

    /// Normalise user input into a bare host, or nil if it is not usable.
    /// Accepts "example.com", "https://example.com/path", "EXAMPLE.com.".
    public static func normalise(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }
        if let url = URL(string: s), let host = url.host { s = host }
        if s.hasSuffix(".") { s.removeLast() }          // trailing dot is a valid FQDN form
        guard !s.isEmpty, !s.contains(" "), s.contains(".") else { return nil }
        // Reject anything with a scheme or path left over — a malformed entry
        // silently scanning the wrong host is worse than refusing.
        guard !s.contains("/"), !s.contains(":") else { return nil }
        return s
    }

    public func scan(_ rawDomain: String) async -> Report {
        let started = Date()
        guard let domain = Self.normalise(rawDomain) else {
            return Report(
                domain: rawDomain,
                checks: [Check(id: "input", title: "Domain", outcome: .unknown("not a usable hostname"))],
                startedAt: started,
                finishedAt: Date()
            )
        }

        // Run independently and concurrently — one host being slow must not
        // stop the others reporting.
        async let headers = securityHeaders(domain)
        async let certs = certificateTransparency(domain)
        async let dns = dnsRecords(domain)

        let checks = await [headers, certs, dns].flatMap { $0 }
        return Report(domain: domain, checks: checks, startedAt: started, finishedAt: Date())
    }

    // MARK: - checks

    /// The check a web app cannot do at all: reading another origin's response
    /// headers. CORS forbids it in a browser; URLSession is not bound by CORS.
    private func securityHeaders(_ domain: String) async -> [Check] {
        guard let url = URL(string: "https://\(domain)/") else {
            return [Check(id: "hdr", title: "Security headers", outcome: .unknown("could not form URL"))]
        }
        do {
            let res = try await gateway.send(.init(url: url, method: "HEAD", timeout: 10))
            let want: [(String, String)] = [
                ("strict-transport-security", "HSTS"),
                ("content-security-policy", "Content-Security-Policy"),
                ("x-content-type-options", "X-Content-Type-Options"),
                ("referrer-policy", "Referrer-Policy"),
            ]
            return want.map { key, label in
                if res.headers[key] != nil {
                    return Check(id: key, title: label, outcome: .ok("present"))
                }
                return Check(id: key, title: label, outcome: .finding("missing"))
            }
        } catch {
            // One unknown, not four false findings. Reporting "HSTS missing"
            // because the host was unreachable would be a fabricated result.
            let why = (error as? Gateway.Failure).map(Self.describe) ?? error.localizedDescription
            return [Check(id: "hdr", title: "Security headers", outcome: .unknown(why))]
        }
    }

    /// Certificates issued for the domain, via crt.sh.
    private func certificateTransparency(_ domain: String) async -> [Check] {
        guard let url = URL(string: "https://crt.sh/?q=\(domain)&output=json") else {
            return [Check(id: "ct", title: "Certificate transparency", outcome: .unknown("could not form URL"))]
        }
        struct Entry: Decodable { let name_value: String? }
        do {
            let entries = try await gateway.json([Entry].self, from: .init(url: url, timeout: 20))
            let names = Set(entries.compactMap { $0.name_value }
                .flatMap { $0.split(separator: "\n").map(String.init) })
            return [Check(
                id: "ct",
                title: "Certificate transparency",
                outcome: .ok("\(names.count) name(s) seen in CT logs")
            )]
        } catch {
            let why = (error as? Gateway.Failure).map(Self.describe) ?? error.localizedDescription
            return [Check(id: "ct", title: "Certificate transparency", outcome: .unknown(why))]
        }
    }

    /// DNS over HTTPS. iOS gives no raw resolver API, and DoH is the honest way
    /// to do this from an app without a helper daemon.
    private func dnsRecords(_ domain: String) async -> [Check] {
        guard let url = URL(string: "https://cloudflare-dns.com/dns-query?name=\(domain)&type=A") else {
            return [Check(id: "dns", title: "DNS", outcome: .unknown("could not form URL"))]
        }
        struct Answer: Decodable { let data: String? }
        struct DoH: Decodable { let Status: Int; let Answer: [Answer]? }
        do {
            let doh = try await gateway.json(
                DoH.self,
                from: .init(url: url, headers: ["accept": "application/dns-json"], timeout: 10)
            )
            guard doh.Status == 0 else {
                return [Check(id: "dns", title: "DNS", outcome: .finding("resolver status \(doh.Status)"))]
            }
            let addrs = (doh.Answer ?? []).compactMap { $0.data }
            if addrs.isEmpty {
                return [Check(id: "dns", title: "DNS", outcome: .finding("no A record"))]
            }
            return [Check(id: "dns", title: "DNS", outcome: .ok(addrs.joined(separator: ", ")))]
        } catch {
            let why = (error as? Gateway.Failure).map(Self.describe) ?? error.localizedDescription
            return [Check(id: "dns", title: "DNS", outcome: .unknown(why))]
        }
    }

    static func describe(_ failure: Gateway.Failure) -> String {
        switch failure {
        case .unreachable(let why): return "unreachable — \(why)"
        case .http(let status): return "responded \(status)"
        case .malformed(let why): return "unexpected response — \(why)"
        case .refused(let why): return "refused — \(why)"
        }
    }
}
