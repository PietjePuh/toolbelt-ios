import SwiftUI

/// Persistent playback bar. Shown only while something is loaded, so it is
/// never an empty control taking up space.
struct NowPlayingBar: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var settings: Settings
    @State private var expanded = false

    var body: some View {
        if let item = player.current {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    artwork(item)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.footnote.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            if item.isLive {
                                Text("LIVE")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4)
                                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            } else if player.duration > 0 {
                                Text("\(PlaybackItem.formatTime(player.position)) / \(PlaybackItem.formatTime(player.duration))")
                                    .font(.caption2).monospacedDigit()
                            }
                            if let source = item.source {
                                Text(source).font(.caption2).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    // Skip controls are absent on live audio, not disabled: a
                    // button that cannot do anything is worse than no button.
                    if !item.isLive {
                        Button {
                            player.skip(by: -Double(settings.value.skipBackwardSeconds))
                        } label: {
                            Image(systemName: "gobackward")
                        }
                        .accessibilityLabel("Skip back \(settings.value.skipBackwardSeconds) seconds")
                    }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if let failure = player.failure {
                    // Silence is indistinguishable from "finished", so say it.
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
            }
            .background(.thinMaterial)
        }
    }

    @ViewBuilder
    private func artwork(_ item: PlaybackItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let url = item.artwork {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: item.isLive ? "dot.radiowaves.left.and.right" : "headphones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: item.isLive ? "dot.radiowaves.left.and.right" : "headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
