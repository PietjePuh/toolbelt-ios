import XCTest
import CryptoKit
@testable import Toolbelt

/// SSH is only as good as its host-key handling. These pin the two rules that
/// people most often relax, both of which convert SSH back into an unprotected
/// channel:
///
///   - a CHANGED host key must be a hard failure, never an "accept new key?"
///     prompt — that prompt is how a real interception gets clicked through,
///     because it looks like the routine first-connection question
///   - first sight must be a QUESTION, not a silent accept
final class TerminalSecurityTests: XCTestCase {

    private func tempStore() -> KnownHosts {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("known_hosts-\(UUID().uuidString).json")
        return KnownHosts(storeURL: url)
    }

    private func keyBlob(_ seed: String) -> Data { Data(seed.utf8) }

    // MARK: - host key policy

    func testFirstSightIsUnknownNotAutomaticallyTrusted() {
        let kh = tempStore()
        let verdict = kh.verdict(host: "example.com", port: 22, keyBlob: keyBlob("hostkey-A"))
        guard case .unknown(let fp) = verdict else {
            return XCTFail("a never-seen host must be .unknown so the user is asked, got \(verdict)")
        }
        XCTAssertTrue(fp.hasPrefix("SHA256:"),
                      "the fingerprint must be shown in the form the user can compare against the host")
    }

    func testRememberedKeyIsKnown() throws {
        let kh = tempStore()
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-A"))
        XCTAssertEqual(kh.verdict(host: "example.com", port: 22, keyBlob: keyBlob("hostkey-A")), .known)
    }

    func testChangedKeyIsMismatchNotUnknown() throws {
        // The critical case. If this returned .unknown, the UI would show the
        // same "trust this host?" prompt as a first connection — and the user
        // would tap yes, because it is the question they answered before.
        let kh = tempStore()
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-A"))

        let verdict = kh.verdict(host: "example.com", port: 22, keyBlob: keyBlob("hostkey-B"))
        guard case .mismatch(let expected, let got) = verdict else {
            return XCTFail("a changed host key must be .mismatch, got \(verdict)")
        }
        XCTAssertNotEqual(expected, got)
    }

    func testRememberRefusesToSilentlyOverwriteADifferentKey() throws {
        // "Remember this instead" must require an explicit forget. Otherwise the
        // same tap that hit a mismatch can resolve it.
        let kh = tempStore()
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-A"))
        XCTAssertThrowsError(
            try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-B")),
            "overwriting a differing key must be refused"
        )
        XCTAssertEqual(kh.verdict(host: "example.com", port: 22, keyBlob: keyBlob("hostkey-A")), .known,
                       "the original entry must survive a refused overwrite")
    }

    func testForgetThenRememberIsAllowed() throws {
        let kh = tempStore()
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-A"))
        try kh.forget(host: "example.com", port: 22)
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-B"))
        XCTAssertEqual(kh.verdict(host: "example.com", port: 22, keyBlob: keyBlob("hostkey-B")), .known)
    }

    func testPortIsPartOfIdentity() throws {
        // A different port is a different service and may legitimately have a
        // different key; treating them as one would cause false mismatches.
        let kh = tempStore()
        try kh.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", keyBlob: keyBlob("hostkey-A"))
        guard case .unknown = kh.verdict(host: "example.com", port: 2222, keyBlob: keyBlob("hostkey-B")) else {
            return XCTFail("port 2222 is a different endpoint and must be unknown, not a mismatch")
        }
    }

    // MARK: - device identity

    func testFingerprintFormatMatchesOpenSSH() {
        let fp = KnownHosts.fingerprint(forKeyBlob: Data("anything".utf8))
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        XCTAssertFalse(fp.contains("="), "OpenSSH prints the digest unpadded")
    }

    func testPublicKeyEncodingIsOpenSSHWireFormat() {
        // string("ssh-ed25519") || string(rawKey), each length-prefixed with a
        // 4-byte big-endian count. Getting this wrong produces a line that
        // looks right and that sshd silently ignores.
        let raw = Data(repeating: 0xAB, count: 32)
        let blob = SSHKeyStore.opensshBlob(raw)

        XCTAssertEqual(Array(blob[0..<4]), [0, 0, 0, 11], "length of 'ssh-ed25519'")
        XCTAssertEqual(String(bytes: blob[4..<15], encoding: .utf8), "ssh-ed25519")
        XCTAssertEqual(Array(blob[15..<19]), [0, 0, 0, 32], "length of an ed25519 public key")
        XCTAssertEqual(Array(blob[19...]), Array(raw))
    }
}
