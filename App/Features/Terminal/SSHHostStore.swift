import Foundation

/// A saved host, and the snippets that belong to it.
///
/// Snippets are the feature every mature iOS terminal has, and for the same
/// reason: typing `docker compose logs -f --tail=100 web` on a phone keyboard
/// is miserable, and getting it slightly wrong is worse. They are saved
/// commands you tap.
public struct SavedHost: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var user: String
    public var host: String
    public var port: Int
    public let addedAt: Date

    public init(id: UUID = UUID(), label: String, user: String, host: String,
                port: Int = SSHTarget.defaultPort, addedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.user = user
        self.host = host
        self.port = port
        self.addedAt = addedAt
    }

    public var target: SSHTarget {
        SSHTarget(user: user, host: host, port: port,
                  isIPv6Literal: host.contains(":"))
    }

    public var reachability: TailnetHost.Kind { TailnetHost.classify(host) }
}

public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var command: String
    /// Whether tapping it runs immediately or just inserts the text.
    ///
    /// Default is INSERT, not run. A snippet is a saved command, and some of
    /// them are destructive — `docker system prune -af` should land on the
    /// prompt for a look before it executes, not fire on a mis-tap.
    public var runImmediately: Bool

    public init(id: UUID = UUID(), title: String, command: String,
                runImmediately: Bool = false) {
        self.id = id
        self.title = title
        self.command = command
        self.runImmediately = runImmediately
    }

    /// What actually goes on the wire.
    public var payload: String {
        runImmediately ? command + "\n" : command
    }
}

/// Persistence for both, behind the same injectable store the rest of the app
/// uses. Same rule as `SubscriptionStore`: unreadable data is never silently
/// replaced by an empty list that the next write makes permanent.
public final class SSHHostStore {

    public enum StoreError: Error, Equatable {
        case duplicate(existing: SavedHost)
        case unreadable
    }

    private let store: KeyValueStore
    private let hostsKey: String
    private let snippetsKey: String

    private var hosts: [SavedHost] = []
    private var snippets: [Snippet] = []

    public private(set) var isUnreadable = false

    public init(store: KeyValueStore = UserDefaults.standard,
                hostsKey: String = "toolbelt.ssh.hosts.v1",
                snippetsKey: String = "toolbelt.ssh.snippets.v1") {
        self.store = store
        self.hostsKey = hostsKey
        self.snippetsKey = snippetsKey
        load()
    }

    private func load() {
        var bad = false

        if let data = store.data(forKey: hostsKey) {
            if let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
                hosts = decoded
            } else { bad = true }
        }
        if let data = store.data(forKey: snippetsKey) {
            if let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
                snippets = decoded
            } else { bad = true }
        }
        isUnreadable = bad
    }

    // MARK: - hosts

    public func allHosts() -> [SavedHost] { hosts }

    @discardableResult
    public func add(_ target: SSHTarget, label: String = "") throws -> SavedHost {
        guard !isUnreadable else { throw StoreError.unreadable }

        // Same user AND host AND port. The same machine under two usernames is
        // two entries, because they are two different logins.
        if let existing = hosts.first(where: {
            $0.host.caseInsensitiveCompare(target.host) == .orderedSame
                && $0.user == target.user && $0.port == target.port
        }) {
            throw StoreError.duplicate(existing: existing)
        }

        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedHost(label: name.isEmpty ? target.displayString : name,
                              user: target.user, host: target.host, port: target.port)
        hosts.append(saved)
        try persistHosts()
        return saved
    }

    public func removeHost(id: UUID) throws {
        guard !isUnreadable else { throw StoreError.unreadable }
        hosts.removeAll { $0.id == id }
        try persistHosts()
    }

    // MARK: - snippets

    public func allSnippets() -> [Snippet] { snippets }

    @discardableResult
    public func add(snippet: Snippet) throws -> Snippet {
        guard !isUnreadable else { throw StoreError.unreadable }
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = snippet.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return snippet }

        var stored = snippet
        stored.title = title.isEmpty ? String(command.prefix(24)) : title
        stored.command = command
        snippets.append(stored)
        try persistSnippets()
        return stored
    }

    public func removeSnippet(id: UUID) throws {
        guard !isUnreadable else { throw StoreError.unreadable }
        snippets.removeAll { $0.id == id }
        try persistSnippets()
    }

    public func resetAfterCorruption() throws {
        hosts = []
        snippets = []
        isUnreadable = false
        try persistHosts()
        try persistSnippets()
    }

    private func persistHosts() throws {
        store.set(try JSONEncoder().encode(hosts), forKey: hostsKey)
    }

    private func persistSnippets() throws {
        store.set(try JSONEncoder().encode(snippets), forKey: snippetsKey)
    }
}
