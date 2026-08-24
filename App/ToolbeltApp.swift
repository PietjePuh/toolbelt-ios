import SwiftUI

@main
struct ToolbeltApp: App {
    /// One gateway for the whole app — the single place outbound requests,
    /// timeouts and failure descriptions are owned. Mirrors the desktop
    /// Toolbelt's shape, minus the server.
    private let gateway = Gateway()
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup {
            RootView(gateway: gateway)
                .environmentObject(settings)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.value.appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct RootView: View {
    let gateway: Gateway
    @StateObject private var player = AudioPlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            tabs
            // Outside the TabView so playback survives switching tabs.
            NowPlayingBar(player: player)
        }
    }

    private var tabs: some View {
        TabView {
            DomainScanView(scanner: DomainScanner(gateway: gateway))
                .tabItem { Label("Scan", systemImage: "magnifyingglass") }

            FeedsView(gateway: gateway)
                .tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }

            WatchView(gateway: gateway)
                .tabItem { Label("Watch", systemImage: "film") }

            LiveTVView(gateway: gateway)
                .tabItem { Label("Live TV", systemImage: "tv") }

            BrowserView(url: URL(string: "https://duckduckgo.com/")!)
                .tabItem { Label("Browse", systemImage: "safari") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            // Live TV, the terminal and finance land here as each one works end
            // to end. Deliberately not stubbed with placeholder tabs: an empty
            // tab that looks like a feature is the "cosmetic thing that does
            // not work" the parent repo just spent a PR deleting.
        }
    }
}
