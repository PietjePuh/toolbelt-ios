import Foundation

/// Where to connect: `user@host` or `user@host:port`.
///
/// Parsed rather than accepted, because every field ends up somewhere that
/// cares. The host goes into a DNS lookup and into the known-hosts key; the
/// username goes over the wire in the authentication request. Neither should
/// be whatever the user's keyboard produced.
public struct SSHTarget: Equatable, Sendable, Hashable {

    public static let defaultPort = 22

    public let user: String
    public let host: String
    public let port: Int
    /// True for a bracketed IPv6 literal, which changes how the host is
    /// written back into a display string.
    public let isIPv6Literal: Bool

    public enum ParseError: Error, Equatable {
        case missingUser
        case missingHost
        case invalidUser(String)
        case invalidHost(String)
        case invalidPort(String)
    }

    public init(user: String, host: String, port: Int = SSHTarget.defaultPort,
                isIPv6Literal: Bool = false) {
        self.user = user
        self.host = host
        self.port = port
        self.isIPv6Literal = isIPv6Literal
    }

    /// `user@host`, `user@host:port`, `user@[::1]:22`.
    public static func parse(_ raw: String) throws -> SSHTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // An `ssh://` prefix is common muscle memory; accept and strip it.
        let body = trimmed.lowercased().hasPrefix("ssh://")
            ? String(trimmed.dropFirst("ssh://".count))
            : trimmed

        guard let at = body.lastIndex(of: "@") else { throw ParseError.missingUser }
        let user = String(body[body.startIndex..<at])
        let rest = String(body[body.index(after: at)...])

        guard !user.isEmpty else { throw ParseError.missingUser }
        guard isValidUser(user) else { throw ParseError.invalidUser(user) }
        guard !rest.isEmpty else { throw ParseError.missingHost }

        // IPv6 literals are bracketed precisely so the colons are not port
        // separators. Handled first, or `::1` splits into nonsense.
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw ParseError.invalidHost(rest) }
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !host.isEmpty, isValidIPv6(host) else { throw ParseError.invalidHost(host) }

            let after = String(rest[rest.index(after: close)...])
            let port = try parsePort(after)
            return SSHTarget(user: user, host: host, port: port, isIPv6Literal: true)
        }

        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            let host = String(parts[0])
            guard isValidHost(host) else { throw ParseError.invalidHost(host) }
            return SSHTarget(user: user, host: host)
        case 2:
            let host = String(parts[0])
            guard isValidHost(host) else { throw ParseError.invalidHost(host) }
            return SSHTarget(user: user, host: host, port: try parsePort(":\(parts[1])"))
        default:
            // Unbracketed colons: an IPv6 address written without brackets is
            // ambiguous with host:port, so it is refused rather than guessed.
            throw ParseError.invalidHost(rest)
        }
    }

    static func parsePort(_ suffix: String) throws -> Int {
        guard !suffix.isEmpty else { return defaultPort }
        guard suffix.hasPrefix(":") else { throw ParseError.invalidPort(suffix) }
        let digits = String(suffix.dropFirst())
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let port = Int(digits), (1...65535).contains(port) else {
            throw ParseError.invalidPort(digits)
        }
        return port
    }

    /// POSIX-ish: letters, digits, and `._-`, not starting with a dash. The
    /// username is sent verbatim in the auth request, so a newline or a space
    /// has no business in it.
    static func isValidUser(_ s: String) -> Bool {
        guard s.count <= 32, let first = s.first, first != "-" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// A DNS name or an IPv4 literal. Deliberately strict: this string is used
    /// as part of the known-hosts identity, so two spellings of one host must
    /// not produce two entries.
    static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
        }
        return true
    }

    static func isValidIPv6(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 45 else { return false }
        // Zone ids (fe80::1%en0) are a local concept and never valid for a
        // remote host, so they are refused rather than silently stripped.
        guard !s.contains("%") else { return false }
        return s.allSatisfy { $0.isHexDigit || $0 == ":" } && s.contains(":")
    }

    /// How the target is written back out. Round-trips through `parse`.
    public var displayString: String {
        let hostPart = isIPv6Literal ? "[\(host)]" : host
        return port == Self.defaultPort ? "\(user)@\(hostPart)" : "\(user)@\(hostPart):\(port)"
    }

    /// The identity used for host-key pinning. Port is part of it: a different
    /// service on the same machine is a different trust decision.
    public var knownHostsKey: String { "\(host):\(port)" }
}
