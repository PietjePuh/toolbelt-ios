import Foundation

/// Extended-M3U parser for IPTV playlists.
///
/// The input is a URL the user pasted, fetched over the network, and there is
/// no schema — providers emit whatever they like. So this is written defensively
/// and, like the magnet parser, tested before anything renders it:
///
///  - a **malformed** playlist reports as malformed. It must never come back as
///    an empty channel list, because "0 channels" reads as "this provider has
///    nothing" when the truth is "we could not understand the file".
///  - attributes are **data**, never markup or paths. `tvg-logo` is a URL from
///    a stranger; `group-title` ends up in a UI label.
///  - unparsable lines are **skipped and counted**, not silently dropped, so a
///    playlist that is 90% junk can say so.
public struct M3UPlaylist: Equatable, Sendable {

    public struct Channel: Equatable, Sendable, Identifiable {
        public var id: String { "\(name)|\(url.absoluteString)" }
        public let name: String
        public let url: URL
        public let group: String?
        public let logo: URL?
        public let tvgID: String?
    }

    public enum ParseError: Error, Equatable {
        /// Does not begin with #EXTM3U. Usually an HTML error page served with
        /// a 200, which is exactly the case that would otherwise look like an
        /// empty playlist.
        case notAPlaylist
        case tooLarge(bytes: Int)
    }

    public let channels: [Channel]
    /// Entries that could not be parsed. Surfaced so the UI can say "12 of 300
    /// entries were unreadable" instead of quietly showing 288.
    public let skipped: Int

    /// Generous but finite. A playlist is text; anything this large is either a
    /// mistake or hostile, and streaming it into memory on a phone is not free.
    public static let maxBytes = 8 * 1024 * 1024

    public static func parse(_ data: Data) throws -> M3UPlaylist {
        guard data.count <= maxBytes else { throw ParseError.tooLarge(bytes: data.count) }
        // Providers are inconsistent about encoding; fall back rather than fail.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> M3UPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }),
              first.uppercased().hasPrefix("#EXTM3U") else {
            throw ParseError.notAPlaylist
        }

        var channels: [Channel] = []
        var skipped = 0
        var pending: (name: String, attrs: [String: String])?

        for line in lines.dropFirst() {
            if line.isEmpty { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                pending = parseExtInf(line)
                if pending == nil { skipped += 1 }
                continue
            }

            // Any other #-directive (#EXTGRP, #EXTVLCOPT, …) is metadata we do
            // not use. Ignore rather than treat as a URL.
            if line.hasPrefix("#") { continue }

            guard let info = pending else {
                // A bare URL with no preceding #EXTINF. Still playable, but it
                // has no name — count it rather than inventing one.
                if URL(string: line) != nil { skipped += 1 }
                continue
            }
            pending = nil

            guard let url = URL(string: line), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "rtsp", "rtmp", "udp", "rtp"].contains(scheme) else {
                // Refuse `file:` and anything unrecognised: a playlist from a
                // stranger must not be able to point the player at local
                // storage.
                skipped += 1
                continue
            }

            channels.append(Channel(
                name: info.name,
                url: url,
                group: info.attrs["group-title"],
                logo: info.attrs["tvg-logo"].flatMap(URL.init(string:)),
                tvgID: info.attrs["tvg-id"]
            ))
        }

        return M3UPlaylist(channels: channels, skipped: skipped)
    }

    /// `#EXTINF:-1 tvg-id="x" tvg-logo="https://…" group-title="News",Channel Name`
    static func parseExtInf(_ line: String) -> (name: String, attrs: [String: String])? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rest = String(line[line.index(after: colon)...])

        // The display name is everything after the LAST comma that is not
        // inside quotes — attribute values legitimately contain commas.
        var inQuotes = false
        var splitAt: String.Index?
        for idx in rest.indices {
            let ch = rest[idx]
            if ch == "\"" { inQuotes.toggle() }
            if ch == "," && !inQuotes { splitAt = idx }
        }
        guard let comma = splitAt else { return nil }

        let head = String(rest[rest.startIndex..<comma])
        let name = String(rest[rest.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return (name, parseAttributes(head))
    }

    /// `key="value"` pairs. Values are returned verbatim — they are data.
    static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = false
        var inValue = false

        for ch in s {
            if inValue {
                if ch == "\"" {
                    out[key.trimmingCharacters(in: .whitespaces).lowercased()] = value
                    key = ""; value = ""; inValue = false
                } else {
                    value.append(ch)
                }
                continue
            }
            if ch == "=" { inKey = false; continue }
            if ch == "\"" { inValue = true; continue }
            if ch == " " && !inKey { key = ""; inKey = true; continue }
            key.append(ch)
            inKey = true
        }
        return out
    }
}
