import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// What is playing, and enough about it to show on the lock screen.
public struct PlaybackItem: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let source: String?
    public let artwork: URL?
    /// Known length in seconds. `nil` for a live stream — and a live stream is
    /// NOT a track of unknown length: a scrubber on something with no end is a
    /// control that cannot do anything.
    public let duration: Int?

    public var isLive: Bool { duration == nil }

    public init(url: URL, title: String, source: String? = nil,
                artwork: URL? = nil, duration: Int? = nil) {
        self.url = url
        self.title = title
        self.source = source
        self.artwork = artwork
        self.duration = duration
    }

    /// Podcast episode from a parsed feed item.
    public init?(episode: FeedParser.Item, feedTitle: String) {
        guard let media = episode.media, media.isAudio else { return nil }
        self.init(url: media.url, title: episode.title, source: feedTitle,
                  artwork: episode.artwork, duration: episode.durationSeconds)
    }

    /// Radio station from a playlist channel. Always live.
    public init(station: M3UPlaylist.Channel) {
        self.init(url: station.url, title: station.name,
                  source: station.group, artwork: station.logo, duration: nil)
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// Audio playback for podcasts and radio.
///
/// `AVPlayer` rather than VLCKit for audio deliberately: it is the path that
/// gets background playback, lock-screen controls and route changes for free,
/// and those are the whole point of listening on a phone. VLCKit earns its
/// place on video and IPTV, where the container zoo is the problem.
@MainActor
public final class AudioPlayer: ObservableObject {

    public static let shared = AudioPlayer()

    @Published public private(set) var current: PlaybackItem?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    /// Set when playback fails. A player that silently stops looks identical to
    /// one that finished.
    @Published public private(set) var failure: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemObservation: AnyCancellable?
    private var endObservation: AnyCancellable?

    private init() {
        configureRemoteCommands()
    }

    public func play(_ item: PlaybackItem) {
        failure = nil
        stopObserving()

        do {
            // `.playback` is what keeps audio going with the screen locked. It
            // is also what the `audio` background mode in Info.plist declares —
            // one without the other is a promise the app cannot keep.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            failure = "Could not start audio: \(error.localizedDescription)"
            return
        }

        let asset = AVURLAsset(url: item.url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        current = item
        duration = Double(item.duration ?? 0)
        position = 0

        observe(playerItem)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    public func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    public func stop() {
        player?.pause()
        stopObserving()
        player = nil
        current = nil
        isPlaying = false
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Seeking is refused on a live stream rather than silently doing nothing.
    public func seek(to seconds: Double) {
        guard let player, current?.isLive == false else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        position = seconds
        updateNowPlaying()
    }

    public func skip(by seconds: Double) {
        guard current?.isLive == false else { return }
        seek(to: max(0, min(position + seconds, duration)))
    }

    // MARK: - observation

    private func observe(_ item: AVPlayerItem) {
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds
                if self.duration == 0 {
                    let known = item.duration.seconds
                    if known.isFinite, known > 0 { self.duration = known }
                }
            }
        }

        endObservation = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            // Notifications are posted on whatever thread finished the work;
            // hop to main BEFORE assuming main-actor isolation below.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPlaying = false
                    self?.updateNowPlaying()
                }
            }

        itemObservation = NotificationCenter.default
            .publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self?.failure = error?.localizedDescription ?? "Playback stopped unexpectedly."
                    self?.isPlaying = false
                }
            }
    }

    private func stopObserving() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservation = nil
        endObservation = nil
    }

    // MARK: - lock screen

    private func configureRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying, self.player != nil else { return .commandFailed }
            self.toggle()
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            self.toggle()
            return .success
        }
        // Skip controls are disabled for live audio rather than present and
        // inert — a lock-screen button that does nothing is worse than absent.
        centre.skipForwardCommand.preferredIntervals = [30]
        centre.skipBackwardCommand.preferredIntervals = [15]
        centre.skipForwardCommand.addTarget { [weak self] _ in
            guard let self, self.current?.isLive == false else { return .commandFailed }
            self.skip(by: 30)
            return .success
        }
        centre.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self, self.current?.isLive == false else { return .commandFailed }
            self.skip(by: -15)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPNowPlayingInfoPropertyIsLiveStream: current.isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let source = current.source { info[MPMediaItemPropertyArtist] = source }
        if !current.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled = !current.isLive
        MPRemoteCommandCenter.shared().skipBackwardCommand.isEnabled = !current.isLive
    }
}
