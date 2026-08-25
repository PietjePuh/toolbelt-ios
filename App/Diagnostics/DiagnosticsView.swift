import SwiftUI

/// Diagnostics: what the connection looks like, what went wrong, and how to
/// set up the parts this app cannot set up for you.
public struct DiagnosticsView: View {
    @ObservedObject private var log = DiagnosticLog.shared
    @ObservedObject private var network = NetworkDiagnostics.shared
    @State private var minimumLevel: DiagnosticLog.Level = .debug

    public init() {}

    private var visible: [DiagnosticLog.Entry] {
        log.entries
            .filter { $0.level.severity >= minimumLevel.severity }
            .reversed()
    }

    public var body: some View {
        List {
            connectionSection
            tailscaleSection
            logSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: log.export()) { Label("Share log", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { log.clear() } label: {
                        Label("Clear log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { network.refresh() }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Connection", value: network.summary)
            LabeledContent("VPN or tunnel", value: network.vpnActive ? "Active" : "Not active")
            if !network.interfaces.isEmpty {
                LabeledContent("Interfaces", value: network.interfaces.joined(separator: ", "))
                    .font(.caption)
            }
        } header: {
            Text("Network")
        } footer: {
            // Says what it actually detects. Claiming to detect Tailscale
            // specifically would be a guess presented as a fact.
            Text("This detects that a tunnel interface exists, not which VPN it belongs to. Tailscale, WireGuard and iCloud Private Relay all look the same from inside an app.")
        }
    }

    private var tailscaleSection: some View {
        Section {
            Text("This app cannot set up Tailscale, and does not try to.")
                .font(.footnote)
            Text("""
            1. Install Tailscale from the App Store and sign in to your tailnet.
            2. Allow the VPN configuration when iOS asks — that is what makes \
            100.x addresses and MagicDNS names resolve.
            3. Check the same tailnet is signed in on the machine you want to reach.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Reaching hosts over Tailscale")
        } footer: {
            Text("Once the VPN is up, tailnet addresses work in every app on the device, including this one. There is nothing to configure here.")
        }
    }

    private var logSection: some View {
        Section {
            Picker("Level", selection: $minimumLevel) {
                ForEach(DiagnosticLog.Level.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)

            if visible.isEmpty {
                Text(log.entries.isEmpty
                     ? "Nothing logged yet."
                     : "No entries at this level or above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(visible) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.level.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(colour(entry.level))
                        Text(entry.category)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.at, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.message).font(.caption)
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Recent activity")
        } footer: {
            Text("Credentials in addresses and tokens are removed as entries are recorded, not when sharing — so nothing sensitive is held here either. Read it before sending it on anyway.")
        }
    }

    private func colour(_ level: DiagnosticLog.Level) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
