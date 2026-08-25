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

    /// FIVE tabs, deliberately. iOS folds anything past the fifth into a
    /// system "More" list, which buries features behind a generic label and
    /// orders them by nothing at all. With seven features that fold was about
    /// to happen by accident, so the grouping is chosen here instead.
    ///
    /// Grouped by what the person wants, not by which module implements it:
    /// Films & series and Live TV are one intent ("something to watch"), and
    /// the browser is plumbing every other tab already opens for you rather
    /// than a destination.
    private var tabs: some View {
        TabView {
            FeedsView(gateway: gateway)
                .tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }

            MediaView(gateway: gateway)
                .tabItem { Label("Media", systemImage: "play.tv") }

            FinanceView(gateway: gateway)
                .tabItem { Label("Finance", systemImage: "chart.line.uptrend.xyaxis") }

            DomainScanView(scanner: DomainScanner(gateway: gateway))
                .tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }

            MoreView(gateway: gateway)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
    }
}

/// Films & series and Live TV are switched, not nested. Nesting one under the
/// other would make it a second-class feature for no reason.
struct MediaView: View {
    let gateway: Gateway
    @State private var section: Section = .watch

    enum Section: String, CaseIterable {
        case watch = "Films & series"
        case live  = "Live TV"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Media section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 6)

            switch section {
            case .watch: WatchView(gateway: gateway)
            case .live:  LiveTVView(gateway: gateway)
            }
        }
    }
}

/// Plumbing: reached when needed rather than competing for a tab slot with
/// something you actually came here to do.
struct MoreView: View {
    let gateway: Gateway
    @State private var browsing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { browsing = true } label: {
                        Label("Browser", systemImage: "safari")
                    }
                } footer: {
                    Text("Opens with no stored cookies, and leaves none behind.")
                }

                Section {
                    NavigationLink { SettingsView() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("More")
            .fullScreenCover(isPresented: $browsing) {
                BrowserView(url: URL(string: "https://duckduckgo.com/")!)
            }
        }
    }
}
