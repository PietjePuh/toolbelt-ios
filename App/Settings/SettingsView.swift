import SwiftUI

/// Settings: the user's own keys and the device's own identity.
///
/// Deliberately blunt about what is stored where. This app asks people to
/// bring their own credentials, which only works if it is obvious what it does
/// with them.
public struct SettingsView: View {
    private let secrets = SecretStore()

    @State private var tmdbEntry = ""
    @State private var tmdbIsSet = false
    @State private var sshFingerprint: String?
    @State private var message: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                tmdbSection
                sshSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: refresh)
        }
    }

    // MARK: - TMDB

    private var tmdbSection: some View {
        Section {
            if tmdbIsSet {
                // The value is never shown back — not even a masked prefix,
                // which is enough to confirm a guess.
                Label("Key stored on this device", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                Button("Replace key") { tmdbIsSet = false; tmdbEntry = "" }
                Button("Remove key", role: .destructive) {
                    secrets.remove(.tmdbKey)
                    refresh()
                    message = "TMDB key removed."
                }
            } else {
                SecureField("Paste your TMDB read access token", text: $tmdbEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") { saveTMDB() }
                    .disabled(tmdbEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Films & series")
        } footer: {
            Text("""
            Discovery uses TMDB. The key is yours — get a free one at \
            themoviedb.org under Settings → API. No key is shipped with this \
            app: a key inside a public sideloaded app is a published key.

            It is stored in the device Keychain, is not readable before the \
            first unlock after a restart, and never syncs to iCloud.
            """)
        }
    }

    private func saveTMDB() {
        do {
            try secrets.set(tmdbEntry, for: .tmdbKey)
            tmdbEntry = ""
            refresh()
            message = "Key saved."
        } catch {
            message = "That key could not be saved."
        }
    }

    // MARK: - SSH

    private var sshSection: some View {
        Section {
            if let fingerprint = sshFingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This device's key").font(.footnote).foregroundStyle(.secondary)
                    Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Copy authorized_keys line") { copyAuthorizedKey() }
            } else {
                Text("No key yet — one is created the first time you connect.")
                    .foregroundStyle(.secondary)
                Button("Create device key now") {
                    sshFingerprint = try? SSHKeyStore().fingerprint()
                    message = sshFingerprint == nil ? "Could not create a key." : "Device key created."
                }
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("""
            The private key is generated on this device and cannot be exported. \
            To grant access, add the public line above to authorized_keys on \
            your host. If you lose the phone, delete that one line.
            """)
        }
    }

    private func copyAuthorizedKey() {
        do {
            UIPasteboard.general.string = try SSHKeyStore().authorizedKeyLine()
            message = "Public key copied."
        } catch {
            message = "Could not read the device key."
        }
    }

    // MARK: - about

    private var aboutSection: some View {
        Section {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Label("No analytics, no accounts, no servers of ours",
                  systemImage: "hand.raised")
                .font(.footnote)
        } header: {
            Text("About")
        } footer: {
            Text("""
            Everything this app fetches goes directly from your device to the \
            service concerned, over your own connection.
            """)
        }
    }

    private func refresh() {
        tmdbIsSet = secrets.isSet(.tmdbKey)
        // Only read it if it already exists — `fingerprint()` creates one on
        // first use, so an unconditional read would mint a key just because
        // somebody opened Settings.
        let ssh = SSHKeyStore()
        sshFingerprint = ssh.hasIdentity ? try? ssh.fingerprint() : nil
    }
}
