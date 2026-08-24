import Foundation

/// Parses a magnet URI into the parts a torrent engine needs.
///
/// Written and tested before any engine is integrated, because this is the part
/// that is easy to get subtly wrong and easy to verify: a malformed infohash
/// silently produces a download that never finds a peer, with no error to show
/// the user.
///
/// Reference: BEP 9 / BEP 53. `magnet:?xt=urn:btih:<hash>&dn=<name>&tr=<tracker>`
public struct MagnetLink: Equatable, Sendable {

    /// 40-char hex (SHA-1) or 64-char hex (SHA-256, BitTorrent v2).
    public let infoHash: String
    /// Suggested display name. Advisory only — it comes from the link, i.e.
    /// from whoever wrote it, and must never be used as a filesystem path
    /// without sanitising.
    public let displayName: String?
    public let trackers: [URL]

    public enum ParseError: Error, Equatable {
        case notAMagnetURI
        case missingInfoHash
        case unsupportedInfoHash(String)
    }

    public static func parse(_ raw: String) throws -> MagnetLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { throw ParseError.notAMagnetURI }

        guard let comps = URLComponents(string: trimmed) else { throw ParseError.notAMagnetURI }
        let items = comps.queryItems ?? []

        // `xt` may appear multiple times (v1 + v2 hybrid links). Take the first
        // btih we can actually use rather than failing on an unfamiliar sibling.
        let xts = items.filter { $0.name == "xt" }.compactMap { $0.value }
        guard !xts.isEmpty else { throw ParseError.missingInfoHash }

        var found: String?
        for xt in xts {
            guard xt.lowercased().hasPrefix("urn:btih:") else { continue }
            let value = String(xt.dropFirst("urn:btih:".count))
            if let normalised = Self.normaliseInfoHash(value) { found = normalised; break }
        }
        guard let infoHash = found else {
            throw ParseError.unsupportedInfoHash(xts.joined(separator: ","))
        }

        let name = items.first { $0.name == "dn" }?.value
        let trackers = items.filter { $0.name == "tr" }
            .compactMap { $0.value }
            .compactMap(URL.init(string:))

        return MagnetLink(infoHash: infoHash, displayName: name, trackers: trackers)
    }

    /// Accepts hex (40 or 64 chars) or base32 (32 chars, older links), returning
    /// lowercase hex. Returns nil for anything else — better to refuse than to
    /// hand an engine a hash that cannot match.
    static func normaliseInfoHash(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if (s.count == 40 || s.count == 64), s.unicodeScalars.allSatisfy(hex.contains) {
            return s.lowercased()
        }
        if s.count == 32, let data = base32Decode(s.uppercased()) {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    /// RFC 4648 base32, no padding — the form older magnet links use.
    static func base32Decode(_ s: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        for ch in s where ch != "=" {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }
}
