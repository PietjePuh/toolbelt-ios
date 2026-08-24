import Foundation

/// What the built-in player can actually play.
///
/// IPTV playlists are a zoo: HLS, progressive MP4, raw MPEG-TS over HTTP, RTSP,
/// and UDP/RTP multicast that only works on the provider's own network. AVPlayer
/// handles the first two. Rather than handing it a stream it will silently fail
/// on — a black screen with a spinner tells the user nothing — the unsupported
/// cases are named, with the reason.
public enum StreamSupport: Equatable, Sendable {

    /// AVPlayer handles this container natively — better controls, AirPlay,
    /// and picture-in-picture come with it.
    case supported
    /// AVPlayer cannot open it, but the bundled VLC engine can. Which engine
    /// runs is an implementation detail; the point is that it PLAYS.
    case needsVLC
    /// No extension to judge by. Most HLS endpoints look like this, so it is
    /// worth trying — but the UI should not promise it will work.
    case worthTrying
    /// Known not to work in this player, with a reason the user can act on.
    case unsupported(reason: String)

    public var canAttempt: Bool {
        switch self {
        case .supported, .needsVLC, .worthTrying: return true
        case .unsupported: return false
        }
    }

    /// Which engine to hand this to.
    public var usesVLC: Bool {
        if case .needsVLC = self { return true }
        return false
    }

    public static func assess(_ url: URL) -> StreamSupport {
        guard let scheme = url.scheme?.lowercased() else {
            return .unsupported(reason: "That address has no protocol.")
        }

        switch scheme {
        case "udp", "rtp":
            // VLC can decode these, but multicast does not cross the internet —
            // so this is a NETWORK limit, not a codec one, and saying "not
            // supported" would send the user looking for the wrong fix.
            return .unsupported(reason: "Multicast only works on the provider's own network — it cannot reach you over the internet.")
        case "rtsp", "rtmp", "mms":
            return .needsVLC
        case "http", "https":
            break
        default:
            return .unsupported(reason: "\(scheme): streams are not supported.")
        }

        // Query strings routinely carry tokens ending in anything at all, so
        // judge by the PATH only.
        let ext = URL(fileURLWithPath: url.path).pathExtension.lowercased()
        switch ext {
        case "m3u8":
            return .supported
        case "mp4", "m4v", "mov", "m4a", "mp3", "aac":
            return .supported
        case "ts", "mpegts", "mts", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "ogv", "webm":
            // VLC's whole reason for being here.
            return .needsVLC
        case "":
            // Very common for HLS: /live/1234 with no extension.
            return .worthTrying
        default:
            return .worthTrying
        }
    }
}
