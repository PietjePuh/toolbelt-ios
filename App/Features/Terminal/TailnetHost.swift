import Foundation

/// Recognising a Tailscale address, so a failure can say something useful.
///
/// THERE IS NOTHING TO CONNECT. An iOS app cannot embed Tailscale — the
/// official app installs a system-wide VPN, and while it is up, `100.x`
/// addresses and MagicDNS names resolve for every app on the device including
/// this one. No connector, no library, no entitlement.
///
/// What IS worth building is recognition. A tailnet host with Tailscale
/// switched off does not refuse the connection, it simply never answers — so
/// the user gets a timeout that looks identical to a server being down, and
/// goes looking in the wrong place. Naming the address type turns that into
/// one sentence.
public enum TailnetHost {

    public enum Kind: Equatable, Sendable {
        /// A Tailscale CGNAT address (100.64.0.0/10) or a MagicDNS name.
        case tailnet
        /// RFC1918 or link-local — reachable only on the same network.
        case localNetwork
        case publicInternet

        public var needsTailscale: Bool { self == .tailnet }
    }

    /// Tailscale hands out addresses from the carrier-grade NAT range
    /// 100.64.0.0/10 — second octet 64 through 127. Note 100.0.x and 100.128.x
    /// are NOT in it, which a naive "starts with 100." check gets wrong.
    public static func isTailscaleIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        guard let first = Int(parts[0]), first == 100,
              let second = Int(parts[1]), (64...127).contains(second) else { return false }
        // The remaining octets still have to be octets.
        return parts[2...3].allSatisfy { part in
            guard let n = Int(part), (0...255).contains(n), !part.isEmpty else { return false }
            return true
        }
    }

    /// MagicDNS names live under `.ts.net`. Matched on a label boundary, so
    /// `evilts.net` and `nots.net` do not qualify.
    public static func isMagicDNS(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "ts.net" || lower.hasSuffix(".ts.net")
    }

    public static func classify(_ host: String) -> Kind {
        if isTailscaleIP(host) || isMagicDNS(host) { return .tailnet }
        if isPrivateIPv4(host) || isLinkLocal(host) || host.lowercased().hasSuffix(".local") {
            return .localNetwork
        }
        return .publicInternet
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts[2...3].allSatisfy({ Int($0) != nil }) else { return false }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 127 { return true }
        return false
    }

    static func isLinkLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), a == 169, b == 254 {
            return true
        }
        return host.lowercased().hasPrefix("fe80:")
    }

    /// What to tell the user when a connection to this host times out.
    /// Returns nil for an ordinary internet host, where the generic message is
    /// already the right one.
    public static func timeoutHint(for host: String) -> String? {
        switch classify(host) {
        case .tailnet:
            return "This is a Tailscale address. It only answers while Tailscale is connected — check the Tailscale app, and that this device and the host are both signed in to the same tailnet."
        case .localNetwork:
            return "This address is only reachable on the same network. Check you are on the right Wi-Fi rather than mobile data."
        case .publicInternet:
            return nil
        }
    }
}
