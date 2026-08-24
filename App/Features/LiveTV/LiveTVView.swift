import AVKit
import SwiftUI

/// Live TV from a user-supplied M3U playlist.
///
/// No playlist ships with the app and none is suggested: IPTV sources are the
/// user's own business, and bundling any would be both a legal and an editorial
/// claim this project has no reason to make.
public struct LiveTVView: View {
    @StateObject private var model: LiveTVViewModel
    @State private var showingAdd = false

    public init(gateway: Gateway) {
        _model = StateObject(wrappedValue: LiveTVViewModel(gateway: gateway))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No playlist yet", systemImage: "tv")
                    } description: {
                        Text("Add the M3U address your provider gave you. Nothing is bundled with this app.")
                    } actions: {
                        Button("Add a playlist") { showingAdd = true }
                    }
                } else {
                    List {
                        ForEach(model.playlists) { playlist in
                            NavigationLink {
                                ChannelListView(playlist: playlist, loader: model.loader)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title)
                                    Text(playlist.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { model.remove($0) }
                    }
                }
            }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddPlaylistView(model: model) }
        }
    }
}

struct AddPlaylistView: View {
    @ObservedObject var model: LiveTVViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var name = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://provider.example/get.php?…", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name (optional)", text: $name)
                    Button(checking ? "Checking…" : "Add playlist") { Task { await add() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.orange)
                    } else {
                        Text("The playlist is fetched once before it is saved, so an expired or wrong address fails here rather than looking like an empty channel list.")
                    }
                }
            }
            .navigationTitle("Add playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add() async {
        checking = true; problem = nil
        defer { checking = false }
        switch await model.add(address, name: name) {
        case .added: dismiss()
        case .failed(let why): problem = why
        }
    }
}

// MARK: - channels

struct ChannelListView: View {
    let playlist: Subscription
    let loader: PlaylistLoader

    @State private var channels: [M3UPlaylist.Channel] = []
    @State private var skipped = 0
    @State private var group: String?
    @State private var search = ""
    @State private var error: PlaylistLoader.LoadError?
    @State private var loading = true
    @State private var playing: M3UPlaylist.Channel?

    private var groups: [String] {
        Array(Set(channels.compactMap(\.group))).sorted()
    }

    private var visible: [M3UPlaylist.Channel] {
        channels.filter { channel in
            (group == nil || channel.group == group) &&
            (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

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
            } else {
                List {
                    if skipped > 0 {
                        // A silently short list reads as "my provider has fewer
                        // channels than I paid for".
                        Text("\(skipped) entries in this playlist could not be read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !groups.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    groupChip(nil, label: "All")
                                    ForEach(groups, id: \.self) { groupChip($0, label: $0) }
                                }
                            }
                        }
                    }
                    ForEach(visible) { channel in
                        let support = StreamSupport.assess(channel.url)
                        Button {
                            if support.canAttempt { playing = channel }
                        } label: {
                            HStack(spacing: 10) {
                                logo(channel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name).lineLimit(1)
                                    if case .unsupported(let reason) = support {
                                        Text(reason)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .lineLimit(2)
                                    } else if let group = channel.group {
                                        Text(group).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(!support.canAttempt)
                    }
                }
                .searchable(text: $search, prompt: "Search channels")
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playing) { channel in
            LiveVideoView(channel: channel)
        }
    }

    private func groupChip(_ value: String?, label: String) -> some View {
        Button {
            group = (group == value && value != nil) ? nil : value
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(group == value ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func logo(_ channel: M3UPlaylist.Channel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let url = channel.logo {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Image(systemName: "tv").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "tv").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let parsed = try await loader.load(playlist.url)
            channels = parsed.channels
            skipped = parsed.skipped
        } catch let e as PlaylistLoader.LoadError {
            error = e
        } catch {
            self.error = .unreachable(error.localizedDescription)
        }
    }
}

// MARK: - playback

struct LiveVideoView: View {
    let channel: M3UPlaylist.Channel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }

            if let failure {
                // A black screen with a spinner tells the user nothing.
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text("This channel would not play").font(.headline)
                    Text(failure).font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(32)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .task { start() }
        .onDisappear { player?.pause(); player = nil }
    }

    private func start() {
        let item = AVPlayerItem(url: channel.url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        avPlayer.play()

        // Report the failure instead of leaving a black rectangle.
        Task { @MainActor in
            for await status in item.publisher(for: \.status).values {
                if status == .failed {
                    failure = item.error?.localizedDescription
                        ?? "The stream could not be opened. It may use a format the built-in player does not support."
                    return
                }
                if status == .readyToPlay { return }
            }
        }
    }
}

// MARK: - model

@MainActor
final class LiveTVViewModel: ObservableObject {

    enum AddResult { case added, failed(String) }

    @Published private(set) var playlists: [Subscription] = []

    let loader: PlaylistLoader
    private let store = SubscriptionStore()

    init(gateway: Gateway) {
        loader = PlaylistLoader(gateway: gateway)
        playlists = store.all(kind: .liveTV)
    }

    func add(_ raw: String, name: String) async -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return .failed("That does not look like a web address.")
        }

        do {
            let parsed = try await loader.load(url)
            guard !parsed.channels.isEmpty else {
                return .failed("That playlist loaded but contains no playable channels.")
            }
            let title = name.trimmingCharacters(in: .whitespaces)
            _ = try store.add(url: url,
                              title: title.isEmpty ? (url.host ?? "Playlist") : title,
                              kind: .liveTV)
            playlists = store.all(kind: .liveTV)
            return .added
        } catch let e as PlaylistLoader.LoadError {
            return .failed("\(e.summary). \(e.detail)")
        } catch SubscriptionStore.StoreError.duplicate(let existing) {
            return .failed("Already added as “\(existing.title)”.")
        } catch SubscriptionStore.StoreError.insecureURL {
            return .failed("Only https playlists are supported, so your provider credentials in the URL are not sent in the clear.")
        } catch {
            return .failed("Could not save this playlist.")
        }
    }

    func remove(_ offsets: IndexSet) {
        for index in offsets { try? store.remove(id: playlists[index].id) }
        playlists = store.all(kind: .liveTV)
    }
}
