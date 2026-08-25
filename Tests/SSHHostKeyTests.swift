import XCTest
import NIOSSH
@testable import Toolbelt

final class SSHHostKeyTests: XCTestCase {

    /// A throwaway ed25519 key, generated with ssh-keygen purely as a fixture.
    /// Its fingerprint below is what `ssh-keygen -lf` printed for it, so these
    /// tests check against the real tool rather than against ourselves.
    private let publicKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtvpfY9NgvyAxozE3Fbd39tASWk1CDwuNGY+w8kess3 test-fixture"
    private let expectedFingerprint = "SHA256:eHUbjqcDZmJvGy1mYpE/IBlDsBuzSVcISBbzYsX6MDE"

    func testFingerprintMatchesSSHKeygen() throws {
        // The whole point of showing a fingerprint is that the user can compare
        // it with `ssh-keygen -lf` on the server. If our format differs by so
        // much as the padding, they cannot check and must simply trust us.
        XCTAssertEqual(try SSHHostKey.fingerprint(openSSH: publicKeyLine), expectedFingerprint)
    }

    func testCanonicalExtractsTypeAndBlob() throws {
        let canonical = try SSHHostKey.canonical(openSSH: publicKeyLine)
        XCTAssertEqual(canonical.type, "ssh-ed25519")
        XCTAssertFalse(canonical.blob.isEmpty)
    }

    func testCommentIsExcludedFromTheStoredKey() throws {
        // A key is the same key whether or not somebody wrote their laptop's
        // name after it. Storing the comment would make a cosmetic edit on the
        // server look like a host-key change — which is a hard failure.
        let withComment = try SSHHostKey.canonical(openSSH: publicKeyLine)
        let without = try SSHHostKey.canonical(
            openSSH: publicKeyLine.replacingOccurrences(of: " test-fixture", with: ""))
        let otherComment = try SSHHostKey.canonical(
            openSSH: publicKeyLine.replacingOccurrences(of: "test-fixture", with: "someone-else"))

        XCTAssertEqual(withComment, without)
        XCTAssertEqual(withComment, otherComment)
        XCTAssertEqual(SSHHostKey.fingerprint(withComment), SSHHostKey.fingerprint(otherComment))
    }

    func testRoundTripsThroughNIOSSH() throws {
        // Proves the stored text really is the canonical form: NIOSSH parses it
        // back and re-serialises to the same thing.
        let parsed = try NIOSSHPublicKey(openSSHPublicKey: publicKeyLine)
        let canonical = try SSHHostKey.canonical(parsed)

        XCTAssertEqual(canonical.type, "ssh-ed25519")
        XCTAssertEqual(SSHHostKey.fingerprint(canonical), expectedFingerprint)

        let reparsed = try NIOSSHPublicKey(openSSHPublicKey: canonical.openSSH)
        XCTAssertEqual(try SSHHostKey.canonical(reparsed), canonical)
    }

    func testStoredFormIsStableAcrossCalls() throws {
        // The property that hashValue would NOT have given us: Swift's hasher
        // is seeded per process, so pinning by hash would make every restart
        // look like the host key had changed — and under TOFU a changed key is
        // a hard failure, so the app would refuse a host it already trusted.
        let a = try SSHHostKey.canonical(openSSH: publicKeyLine)
        let b = try SSHHostKey.canonical(openSSH: publicKeyLine)
        XCTAssertEqual(a.openSSH, b.openSSH)
        XCTAssertEqual(SSHHostKey.fingerprint(a), SSHHostKey.fingerprint(b))
    }

    func testDifferentKeysHaveDifferentFingerprints() throws {
        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertNotEqual(try SSHHostKey.fingerprint(openSSH: other), expectedFingerprint)
    }

    // MARK: - refusals

    func testMalformedKeysAreRefused() {
        for bad in ["", "ssh-ed25519", "ssh-ed25519 not-base64!!!", "just-one-field",
                    "unknown-type AAAAC3NzaC1lZDI1NTE5"] {
            XCTAssertThrowsError(try SSHHostKey.canonical(openSSH: bad), bad)
        }
    }

    func testExtraWhitespaceDoesNotChangeTheKey() throws {
        let spaced = "  ssh-ed25519   AAAAC3NzaC1lZDI1NTE5AAAAIFtvpfY9NgvyAxozE3Fbd39tASWk1CDwuNGY+w8kess3   "
        XCTAssertEqual(try SSHHostKey.fingerprint(openSSH: spaced), expectedFingerprint)
    }
}
