import Crypto
import Foundation
import NIOSSH

/// Turning a host key into something that can be stored and compared.
///
/// This is the bridge between NIOSSH and the existing `KnownHosts`, and it is
/// its own file because getting it wrong breaks host-key pinning silently.
///
/// THE TRAP THIS AVOIDS: `NIOSSHPublicKey` is `Hashable`, which makes
/// `hashValue` look like an obvious way to remember a key. It is not. Swift's
/// hasher is **seeded per process**, so the value changes on every launch —
/// pinning a key by its hash would make every restart look like the host key
/// had changed. Under TOFU rules a changed key is a hard failure, so the app
/// would refuse to connect to a host it had already trusted, and the error
/// would say the host was compromised. A security control that cries wolf on
/// every launch is worse than none.
///
/// `String(openSSHPublicKey:)` is public and produces the canonical
/// `"ssh-ed25519 AAAA…"` form, which is stable, round-trippable through
/// `NIOSSHPublicKey(openSSHPublicKey:)`, and identical to what lands in
/// `authorized_keys`.
public enum SSHHostKey {

    public struct Canonical: Equatable, Sendable {
        /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, …
        public let type: String
        /// The SSH wire-format blob — the same bytes `ssh-keygen` hashes.
        public let blob: Data
        /// The full OpenSSH line, as stored.
        public let openSSH: String
    }

    public enum KeyError: Error, Equatable {
        case malformed(String)
    }

    /// Canonical form of a key offered by a server.
    public static func canonical(_ key: NIOSSHPublicKey) throws -> Canonical {
        try canonical(openSSH: String(openSSHPublicKey: key))
    }

    /// Same, from the stored text. Used when reading back a pinned key.
    public static func canonical(openSSH line: String) throws -> Canonical {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { throw KeyError.malformed("expected 'type base64'") }

        let type = String(fields[0])
        guard type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-") || type.hasPrefix("sk-") else {
            throw KeyError.malformed("unrecognised key type \(type)")
        }
        guard let blob = Data(base64Encoded: String(fields[1])) else {
            throw KeyError.malformed("key body is not base64")
        }

        // Deliberately excludes any trailing comment. A key is the same key
        // whether or not somebody wrote their laptop's name after it, and
        // storing the comment would make a cosmetic edit look like a key change.
        return Canonical(type: type, blob: blob, openSSH: "\(type) \(fields[1])")
    }

    /// `SHA256:…` exactly as `ssh-keygen -lf` prints it, so a user can compare
    /// what the app shows against what they run on the server. Any other
    /// format would force them to trust rather than check.
    public static func fingerprint(_ canonical: Canonical) -> String {
        let digest = SHA256.hash(data: canonical.blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    public static func fingerprint(openSSH line: String) throws -> String {
        fingerprint(try canonical(openSSH: line))
    }
}
