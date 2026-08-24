import SwiftUI

/// "What to watch out for" — four shelves, tap through to IMDb.
public struct WatchView: View {
    @StateObject private var model: WatchViewModel
    @State private var openURL: URL?

    public init(gateway: Gateway) {
        _model = StateObject(wrappedValue: WatchViewModel(gateway: gateway))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    ProgressView("Loading…")
                case .needsKey:
                    needsKey
                case .keyRejected:
                    notice(
                        icon: "key.slash",
                        title: "That key was rejected",
                        detail: "TMDB did not accept the key stored on this device. Check it in Settings — retrying will not help until it is replaced."
                    )
                case .unreachable(let why):
                    notice(
                        icon: "wifi.exclamationmark",
                        title: "Could not reach TMDB",
                        detail: why
                    )
                case .loaded(let shelves):
                    if shelves.allSatisfy({ $0.titles.isEmpty }) {
                        notice(icon: "film", title: "Nothing listed right now",
                               detail: "TMDB answered, but returned no titles. This is not a setup problem.")
                    } else {
                        shelfList(shelves)
                    }
                }
            }
            .navigationTitle("Watch")
            .refreshable { await model.load() }
        }
        .task { await model.load() }
        .sheet(item: $openURL) { url in BrowserView(url: url) }
    }

    private func shelfList(_ shelves: [WatchViewModel.Shelf]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(shelves) { shelf in
                    if !shelf.titles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(shelf.feed.label).font(.headline)
                                Spacer()
                                if shelf.skipped > 0 {
                                    // Say so rather than showing a quietly
                                    // short list.
                                    Text("\(shelf.skipped) unreadable")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(shelf.titles) { title in
                                        Button { openURL = title.imdbLink.url } label: {
                                            posterCard(title)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    private func posterCard(_ title: WatchTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                AsyncImage(url: title.posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: title.kind == .movie ? "film" : "tv")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 116, height: 174)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                if let year = title.year {
                    Text(String(year)).font(.caption2).foregroundStyle(.secondary)
                }
                if let rating = title.rating {
                    Text(String(format: "★ %.1f", rating))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !title.imdbLink.isExact {
                    // The link is a search, not the title page. Saying so beats
                    // presenting a guess as a fact.
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Opens an IMDb search")
                }
            }
        }
        .frame(width: 116, alignment: .leading)
    }

    private var needsKey: some View {
        notice(
            icon: "key",
            title: "Add your TMDB key",
            detail: "Film and series listings come from TMDB. Keys are free at themoviedb.org — none is shipped with this app, because a key inside a public app is a published key. Add it in Settings."
        )
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

@MainActor
final class WatchViewModel: ObservableObject {

    struct Shelf: Identifiable {
        var id: String { feed.rawValue }
        let feed: WatchCatalog.Feed
        let titles: [WatchTitle]
        let skipped: Int
    }

    /// Four states the UI must not conflate. "You have not set this up",
    /// "your key is wrong", "we could not reach them" and "they have nothing"
    /// need four different answers from the user.
    enum State {
        case idle
        case loading
        case needsKey
        case keyRejected
        case unreachable(String)
        case loaded([Shelf])
    }

    @Published private(set) var state: State = .idle

    private let gateway: Gateway
    private let secrets = SecretStore()

    init(gateway: Gateway) { self.gateway = gateway }

    func load() async {
        state = .loading
        let catalog = WatchCatalog(gateway: gateway, apiKey: secrets.value(for: .tmdbKey))
        guard catalog.isConfigured else {
            state = .needsKey
            return
        }

        var shelves: [Shelf] = []
        for feed in WatchCatalog.Feed.allCases {
            do {
                let page = try await catalog.load(feed)
                shelves.append(Shelf(feed: feed, titles: page.titles, skipped: page.skipped))
            } catch WatchCatalog.CatalogError.notConfigured {
                state = .needsKey
                return
            } catch WatchCatalog.CatalogError.keyRejected {
                // Fail the whole screen: a bad key affects every shelf, and
                // three empty shelves plus one error would read as "TMDB is
                // quiet today".
                state = .keyRejected
                return
            } catch {
                // One shelf failing is not the whole screen failing — keep the
                // others. Only report unreachable if nothing at all loaded.
                continue
            }
        }

        if shelves.isEmpty {
            state = .unreachable("No shelf could be loaded. Check your connection and try again.")
        } else {
            state = .loaded(shelves)
        }
    }
}

/// `sheet(item:)` needs Identifiable; a URL is its own identity here.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
