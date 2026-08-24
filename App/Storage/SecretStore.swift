import Foundation
import Security

/// Where user-supplied secrets live: the Keychain, on this device only.
///
/// Same posture as `SSHKeyStore` and for the same reason — this is a sideloaded
/// app on a phone that can be lost. Secrets are stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which means they are
/// unreadable before the first unlock after boot and **never sync to iCloud**.
/// A synced API key is a key on every device the user owns plus Apple's
/// servers, which is not what "bring your own key" is supposed to mean.
///
/// Nothing here returns a secret for display. The UI asks `isSet` and shows
/// "configured"; the value goes to the service that needs it and nowhere else.
public struct SecretStore: Sendable {

    /// Named slots rather than free-form keys, so a typo cannot silently create
    /// a second secret that nothing reads.
    public enum Secret: String, CaseIterable, Sendable {
        case tmdbKey = "tmdb-api-key"

        public var label: String {
            switch self {
            case .tmdbKey: return "TMDB API key"
            }
        }
    }

    public enum StoreError: Error, Equatable {
        case keychain(OSStatus)
        /// Refused before it was written. An empty or whitespace-only secret
        /// would present as "configured" and then fail every request.
        case empty
    }

    private let service: String

    public init(service: String = "nl.pietjepuh.toolbelt.secrets") {
        self.service = service
    }

    public func set(_ value: String, for secret: Secret) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.empty }
        guard let data = trimmed.data(using: .utf8) else { throw StoreError.empty }

        // Delete-then-add rather than update: fewer states, and it cannot leave
        // a stale attribute set behind from an earlier accessibility choice.
        SecItemDelete(query(for: secret) as CFDictionary)

        var attrs = query(for: secret)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Read a secret. Callers should pass it straight to the service that needs
    /// it — this is the only way a value leaves the Keychain, and there is no
    /// logging or description path that touches it.
    public func value(for secret: Secret) -> String? {
        var q = query(for: secret)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// What the settings screen asks. Never reveals the value — not even a
    /// masked prefix, which is enough to confirm a guess.
    public func isSet(_ secret: Secret) -> Bool {
        var q = query(for: secret)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(_ secret: Secret) -> Bool {
        let status = SecItemDelete(query(for: secret) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Wipe every secret. Offered in settings for handing the device on.
    public func removeAll() {
        for secret in Secret.allCases { remove(secret) }
    }

    private func query(for secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
            // Explicit: this item is not part of the iCloud Keychain.
            kSecAttrSynchronizable as String: false
        ]
    }
}
