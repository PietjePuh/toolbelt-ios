import Foundation
import Network

/// What the device's connection actually looks like, so a failure can be
/// attributed rather than guessed at.
///
/// The VPN question matters here specifically: this app cannot set Tailscale up
/// — that is the user's own doing, in Apple's Settings and the Tailscale app —
/// so the least it can do is say whether a VPN is currently carrying traffic.
/// "Cannot reach 100.101.102.103" plus "no VPN interface is active" is a
/// diagnosis; the first line alone is a shrug.
@MainActor
public final class NetworkDiagnostics: ObservableObject {

    public static let shared = NetworkDiagnostics()

    @Published public private(set) var connection: NetworkStatus.Connection = .wifi
    @Published public private(set) var vpnActive = false
    @Published public private(set) var interfaces: [String] = []

    private let monitor = NWPathMonitor()

    private init() {
        refresh()
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = NetworkStatus.classify(path)
            let names = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                self?.connection = connection
                self?.interfaces = names
                self?.vpnActive = Self.hasVPNInterface()
            }
        }
        monitor.start(queue: DispatchQueue(label: "nl.pietjepuh.toolbelt.diagnostics"))
    }

    public func refresh() {
        vpnActive = Self.hasVPNInterface()
    }

    /// iOS has no public "is a VPN up" API. The scoped proxy settings do list
    /// the active interfaces, and a VPN shows as one of the tunnel families —
    /// which is how every app that reports this does it.
    ///
    /// It reports the presence of a TUNNEL, not that Tailscale specifically is
    /// running, and the UI says exactly that. Claiming to detect Tailscale
    /// itself would be a guess dressed as a fact.
    nonisolated static func hasVPNInterface() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?
                .takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { isTunnelInterface($0) }
    }

    /// utun is what Tailscale, WireGuard and iCloud Private Relay use; ppp,
    /// ipsec and tap cover the older VPN types.
    /// `nonisolated` for the same reason as its caller: it is pure, and
    /// `hasVPNInterface()` — which IS nonisolated — cannot call a main-actor
    /// method. Marking one and not the other is what broke the build.
    nonisolated static func isTunnelInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        for prefix in ["utun", "tap", "tun", "ppp", "ipsec"] where lower.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// One line describing the current state, for the diagnostics screen and
    /// for the log.
    public var summary: String {
        let base: String
        switch connection {
        case .wifi:     base = "Wi-Fi"
        case .cellular: base = "Mobile data"
        case .wired:    base = "Wired"
        case .none:     base = "Offline"
        }
        return vpnActive ? "\(base), VPN or tunnel active" : "\(base), no VPN interface"
    }
}
