import SwiftUI

#if canImport(VLCKit)
import VLCKit

/// VLC playback surface, for the containers AVPlayer will not open.
///
/// Kept behind `canImport` so the app still builds and everything else still
/// works if the VLCKit dependency is ever unavailable — the AVPlayer path
/// covers HLS and MP4, which is most of what a playlist contains.
struct VLCVideoSurface: UIViewRepresentable {
    let url: URL
    let onFailure: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        let player = VLCMediaPlayer()
        player.drawable = view
        player.media = VLCMedia(url: url)
        player.delegate = context.coordinator
        context.coordinator.player = player
        player.play()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player?.stop()
        coordinator.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var player: VLCMediaPlayer?
        private let onFailure: (String) -> Void

        init(onFailure: @escaping (String) -> Void) { self.onFailure = onFailure }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            guard let player else { return }
            if player.state == .error {
                onFailure("The stream could not be opened. The address may have expired, or the provider may be refusing this connection.")
            }
        }
    }
}

let vlcEngineAvailable = true
#else
/// VLCKit absent. The AVPlayer path still covers HLS and MP4.
struct VLCVideoSurface: View {
    let url: URL
    let onFailure: (String) -> Void
    var body: some View {
        Color.black.onAppear {
            onFailure("This channel needs the VLC engine, which is not available in this build.")
        }
    }
}

let vlcEngineAvailable = false
#endif
