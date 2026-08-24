import Foundation
import CryptoKit

/// Remembers which host key belongs to which host, and refuses quietly-changed
/// ones.
///
/// This is the part of SSH that people skip, and skipping it removes the whole
/// point: without host-key verification, anything that can sit between the
/// phone and the host can present its own key, accept the connection, and read
/// the session. On a phone — hostile Wi-Fi, captive portals, untrusted
/// networks — that is not a theoretical threat.
///
/// Policy here is trust-on-first-use, with two rules that matter:
///
///  1. First sight is a QUESTION, not a silent accept. The fingerprint is shown
///     and the user confirms it. An automatic first-use accept is indistinguishable
///     from an attacker being present on the very first connection.
///  2. A CHANGED key is a hard failure, never a prompt to "accept new key".
///     That prompt is how people click through an actual interception, because
///     it looks like the same routine question they answered before.
public struct KnownHosts: Sendable {

    public enum Verdict: Sendable, Equatable {
        /// Seen before, key matches. Proceed.
        case known
        /// Never seen. Show `fingerprint` and ask the user.
        case unknown(fingerprint: String)
        /// Seen before with a DIFFERENT key. Refuse.
        case mismatch(expected: String, got: String)
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let host: String
        public let port: Int
        public let keyType: String
        /// SHA256 fingerprint, not the key itself — enough to detect a change,
        /// and nothing sensitive if the file is read.
        public let fingerprint: String
        public let firstSeen: Date
    }

    private let storeURL: URL

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("known_hosts.json")
    }

    /// `SHA256:...`, matching what `ssh-keygen -lf` and OpenSSH print, so a user
    /// can compare it against the host directly.
    public static func fingerprint(forKeyBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    public func verdict(host: String, port: Int, keyBlob: Data) -> Verdict {
        let fp = Self.fingerprint(forKeyBlob: keyBlob)
        guard let entry = load().first(where: { $0.host == host && $0.port == port }) else {
            return .unknown(fingerprint: fp)
        }
        if entry.fingerprint == fp { return .known }
        return .mismatch(expected: entry.fingerprint, got: fp)
    }

    /// Record a key the user has explicitly confirmed.
    ///
    /// Deliberately refuses to overwrite a differing entry: "remember this
    /// instead" must be an explicit `forget` first, so a mismatch can never be
    /// resolved by the same tap that caused it.
    @discardableResult
    public func remember(host: String, port: Int, keyType: String, keyBlob: Data) throws -> Entry {
        var entries = load()
        let fp = Self.fingerprint(forKeyBlob: keyBlob)
        if let existing = entries.first(where: { $0.host == host && $0.port == port }) {
            guard existing.fingerprint == fp else {
                throw NSError(domain: "KnownHosts", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "refusing to overwrite a different key for \(host):\(port) — forget it explicitly first",
                ])
            }
            return existing
        }
        let entry = Entry(host: host, port: port, keyType: keyType, fingerprint: fp, firstSeen: Date())
        entries.append(entry)
        try persist(entries)
        return entry
    }

    public func forget(host: String, port: Int) throws {
        try persist(load().filter { !($0.host == host && $0.port == port) })
    }

    public func all() -> [Entry] { load() }

    // MARK: - storage

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func persist(_ entries: [Entry]) throws {
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
    }
}
