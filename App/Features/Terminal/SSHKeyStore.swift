import Foundation
import CryptoKit

/// The device's SSH identity.
///
/// The key is **generated on this device and never leaves it**. There is no
/// import path, deliberately: copying an existing private key onto a phone is
/// how one lost handset compromises every host that key reaches. Instead you
/// add this device's *public* key to `authorized_keys`, and if the phone is
/// lost you remove that one line.
///
/// Ed25519 because OpenSSH has supported it for a decade, the keys are small,
/// and CryptoKit can hold the private key in the Secure Enclave-backed Keychain
/// rather than in application memory we manage ourselves.
public struct SSHKeyStore: Sendable {

    public enum StoreError: Error, Equatable {
        case keychain(OSStatus)
        case notFound
        case malformed(String)
    }

    private let account: String
    private let service: String

    public init(service: String = "nl.pietjepuh.toolbelt.ssh", account: String = "device-identity") {
        self.service = service
        self.account = account
    }

    // MARK: - identity

    /// The device key, creating it on first use.
    public func identity() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try? load() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return key
    }

    /// Whether an identity already exists, WITHOUT creating one. Settings needs
    /// this: reading the fingerprint goes through `identity()`, so merely
    /// opening the screen would generate a key the user never asked for.
    public var hasIdentity: Bool {
        (try? load()) != nil
    }

    /// `ssh-ed25519 AAAA... toolbelt-ios` — paste into `authorized_keys`.
    public func authorizedKeyLine(comment: String = "toolbelt-ios") throws -> String {
        let pub = try identity().publicKey.rawRepresentation
        return "ssh-ed25519 \(Self.encodeOpenSSHPublicKey(pub)) \(comment)"
    }

    /// SHA256 fingerprint in the form `ssh-keygen -lf` prints.
    public func fingerprint() throws -> String {
        let pub = try identity().publicKey.rawRepresentation
        let blob = Data(Self.opensshBlob(pub))
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    /// Destroy the device identity. Used when handing the device on, or after a
    /// suspected compromise — the matching `authorized_keys` line must be
    /// removed on each host separately, which the UI says explicitly.
    public func destroy() throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    // MARK: - keychain

    private func save(_ key: Curve25519.Signing.PrivateKey) throws {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
        ]
        // Never syncs to iCloud, and unavailable until the device has been
        // unlocked once since boot. A key that syncs is a key on other devices.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private func load() throws -> Curve25519.Signing.PrivateKey {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? StoreError.notFound : StoreError.keychain(status)
        }
        guard let data = out as? Data else { throw StoreError.malformed("no data") }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    // MARK: - OpenSSH wire format

    /// SSH strings are length-prefixed with a 4-byte big-endian count.
    static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + bytes
    }

    /// The blob OpenSSH base64-encodes: string("ssh-ed25519") || string(key).
    static func opensshBlob(_ rawPublicKey: Data) -> [UInt8] {
        sshString(Array("ssh-ed25519".utf8)) + sshString(Array(rawPublicKey))
    }

    static func encodeOpenSSHPublicKey(_ rawPublicKey: Data) -> String {
        Data(opensshBlob(rawPublicKey)).base64EncodedString()
    }
}
