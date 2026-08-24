import SwiftUI

/// News and podcasts: the subscription list, and one feed's items.
///
/// The list starts EMPTY. Nothing is pre-seeded — the parent project shipped
/// hard-coded "favourites" that were not the user's, and the owner's complaint
/// about it was the reason a whole PR went into removing them. Suggestions are
/// offered, clearly labelled as suggestions, and nothing is subscribed until
/// it is tapped.
public struct FeedsView: View {
    @StateObject private var model: FeedsViewModel
    @State private var showingAdd = false

    public init(gateway: Gateway) {
        _model = StateObject(wrappedValue: FeedsViewModel(gateway: gateway))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.store.isUnreadable {
                    unreadableNotice
                } else if model.subscriptions.isEmpty {
                    emptyState
                } else {
                    subscriptionList
                }
            }
            .navigationTitle("Feeds")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .disabled(model.store.isUnreadable)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddFeedView(model: model)
            }
        }
    }

    private var subscriptionList: some View {
        List {
            ForEach(Subscription.Kind.allCases, id: \.self) { kind in
                let subs = model.subscriptions.filter { $0.kind == kind }
                if !subs.isEmpty {
                    Section(kind.label) {
                        ForEach(subs) { sub in
                            NavigationLink {
                                FeedItemsView(subscription: sub, loader: model.loader)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.title)
                                    Text(sub.url.host ?? sub.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            model.remove(offsets.map { subs[$0].id })
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No feeds yet", systemImage: "dot.radiowaves.up.forward")
        } description: {
            Text("Add a news feed or a podcast. Nothing is subscribed for you — this list is yours.")
        } actions: {
            Button("Add a feed") { showingAdd = true }
        }
    }

    private var unreadableNotice: some View {
        ContentUnavailableView {
            Label("Your feed list could not be read", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The stored list is damaged. It has NOT been deleted, and nothing new can be saved until this is resolved — starting over would make the loss permanent.")
        } actions: {
            Button("Start a new list", role: .destructive) { model.resetStore() }
        }
    }
}

// MARK: - adding

struct AddFeedView: View {
    @ObservedObject var model: FeedsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var checking = false
    @State private var problem: String?

    /// Offered, never applied. The user taps one or types their own.
    private let suggestions: [(String, String)] = [
        ("BBC News — World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
        ("NU.nl — Algemeen", "https://www.nu.nl/rss/Algemeen"),
        ("Tweakers", "https://feeds.feedburner.com/tweakers/mixed"),
        ("Krebs on Security", "https://krebsonsecurity.com/feed/"),
        ("The Register — Security", "https://www.theregister.com/security/headlines.atom")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(checking ? "Checking…" : "Add feed") { Task { await add() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                } header: {
                    Text("Feed address")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.orange)
                    } else {
                        Text("The address is fetched once before it is saved, so you find out now whether it is a feed — and whether it is a podcast — rather than on the first refresh.")
                    }
                }

                Section {
                    ForEach(suggestions, id: \.1) { name, url in
                        Button(name) { address = url; Task { await add() } }
                    }
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text("Nothing here is subscribed unless you tap it.")
                }
            }
            .navigationTitle("Add feed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add() async {
        checking = true
        problem = nil
        defer { checking = false }

        switch await model.add(address) {
        case .added:
            dismiss()
        case .failed(let why):
            problem = why
        }
    }
}

// MARK: - one feed

struct FeedItemsView: View {
    let subscription: Subscription
    let loader: FeedLoader

    @State private var items: [FeedParser.Item] = []
    @State private var error: FeedLoader.LoadError?
    @State private var loading = true
    @State private var openURL: URL?

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let error {
                ContentUnavailableView {
                    Label(error.summary, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.detail)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if items.isEmpty {
                // Reached only when the feed genuinely parsed with no items —
                // never as a stand-in for a failure.
                ContentUnavailableView("Nothing published yet",
                                       systemImage: "tray",
                                       description: Text("This feed loaded correctly and currently has no items."))
            } else {
                List(items) { item in
                    Button {
                        openURL = item.link
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.body)
                            HStack(spacing: 8) {
                                if let published = item.published {
                                    Text(published, style: .relative)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let seconds = item.durationSeconds {
                                    Text(Self.duration(seconds))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if item.media?.isAudio == true {
                                    Image(systemName: "headphones")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(item.link == nil)
                }
            }
        }
        .navigationTitle(subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $openURL) { url in BrowserView(url: url) }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            items = try await loader.load(subscription.url).items
        } catch let e as FeedLoader.LoadError {
            error = e
            items = []
        } catch {
            self.error = .unreachable(error.localizedDescription)
            items = []
        }
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - model

@MainActor
final class FeedsViewModel: ObservableObject {

    enum AddResult { case added, failed(String) }

    @Published private(set) var subscriptions: [Subscription] = []

    let store = SubscriptionStore()
    let loader: FeedLoader

    init(gateway: Gateway) {
        loader = FeedLoader(gateway: gateway)
        subscriptions = store.all()
    }

    func add(_ raw: String) async -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return .failed("That does not look like a web address.")
        }

        // Fetch first: the kind is set from what the feed carries, and a
        // non-feed is caught before it becomes a permanently broken row.
        let inspected: (title: String, kind: Subscription.Kind)
        do {
            inspected = try await loader.inspect(url)
        } catch let e as FeedLoader.LoadError {
            return .failed("\(e.summary). \(e.detail)")
        } catch {
            return .failed(error.localizedDescription)
        }

        do {
            _ = try store.add(url: url, title: inspected.title, kind: inspected.kind)
            subscriptions = store.all()
            return .added
        } catch SubscriptionStore.StoreError.duplicate(let existing) {
            return .failed("Already subscribed as “\(existing.title)”.")
        } catch SubscriptionStore.StoreError.insecureURL {
            return .failed("Only https feeds are supported, so the connection cannot be read in transit.")
        } catch SubscriptionStore.StoreError.notAWebURL {
            return .failed("That is not a web address.")
        } catch {
            return .failed("Could not save this feed.")
        }
    }

    func remove(_ ids: [UUID]) {
        for id in ids { try? store.remove(id: id) }
        subscriptions = store.all()
    }

    func resetStore() {
        try? store.resetAfterCorruption()
        subscriptions = store.all()
    }
}
