import Foundation
import Network

/// What kind of connection the device is on.
///
/// Exists so the "stream video on cellular" setting actually ENFORCES
/// something. A toggle that changes no behaviour is the cosmetic UI this
/// project has already spent a change removing.
@MainActor
public final class NetworkStatus: ObservableObject {

    public enum Connection: Equatable, Sendable {
        case wifi, cellular, wired, none

        public var isMetered: Bool { self == .cellular }
    }

    public static let shared = NetworkStatus()

    @Published public private(set) var connection: Connection = .wifi

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = Self.classify(path)
            Task { @MainActor in self?.connection = connection }
        }
        monitor.start(queue: DispatchQueue(label: "nl.pietjepuh.toolbelt.network"))
    }

    /// `nonisolated` deliberately: this is a pure function, and it is called
    /// from NWPathMonitor's background queue. Inheriting the class's
    /// main-actor isolation would make that call illegal under strict
    /// concurrency — correctly, since nothing here touches actor state.
    nonisolated static func classify(_ path: NWPath) -> Connection {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.cellular) { return .cellular }
        // An unknown-but-satisfied path is treated as unmetered rather than
        // blocking playback on a connection we simply could not classify.
        return .wifi
    }

    /// The rule, in one place so the player and the UI cannot disagree.
    /// Pure, so it is callable from anywhere — including tests.
    public nonisolated static func shouldBlockVideo(connection: Connection, allowCellular: Bool) -> Bool {
        connection.isMetered && !allowCellular
    }
}
