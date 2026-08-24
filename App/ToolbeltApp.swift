import SwiftUI

@main
struct ToolbeltApp: App {
    /// One gateway for the whole app — the single place outbound requests,
    /// timeouts and failure descriptions are owned. Mirrors the desktop
    /// Toolbelt's shape, minus the server.
    private let gateway = Gateway()

    var body: some Scene {
        WindowGroup {
            RootView(gateway: gateway)
        }
    }
}

struct RootView: View {
    let gateway: Gateway

    var body: some View {
        TabView {
            DomainScanView(scanner: DomainScanner(gateway: gateway))
                .tabItem { Label("Scan", systemImage: "magnifyingglass") }

            BrowserView(url: URL(string: "https://duckduckgo.com/")!)
                .tabItem { Label("Browse", systemImage: "safari") }

            // Feeds, watchlist and finance land here as each one works end to
            // end. Deliberately not stubbed with placeholder tabs: an empty tab
            // that looks like a feature is the "cosmetic thing that does not
            // work" the parent repo just spent a PR deleting.
        }
    }
}
