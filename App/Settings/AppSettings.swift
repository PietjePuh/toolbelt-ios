import Foundation

/// Everything the user can configure.
///
/// Two properties this type is built around, both of which are about not
/// losing settings:
///
///  - **Missing keys decode to defaults.** Adding a field in a later version
///    must not make an existing stored blob undecodable, which would silently
///    reset every other preference the user had set.
///  - **Out-of-range values are clamped, not rejected.** A value that is wrong
///    should be corrected to something usable rather than throwing away the
///    whole settings object.
public struct AppSettings: Codable, Equatable, Sendable {

    public enum LinkTarget: String, Codable, CaseIterable, Sendable {
        case inApp, safari

        public var label: String {
            switch self {
            case .inApp:  return "In this app"
            case .safari: return "Safari"
            }
        }
        public var detail: String {
            switch self {
            case .inApp:  return "Keeps browsing inside Toolbelt, with no cookies kept between sessions."
            case .safari: return "Opens your normal browser, with your logins and extensions."
            }
        }
    }

    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark
        public var label: String { rawValue.capitalized }
    }

    // Reading
    public var openLinksIn: LinkTarget = .inApp
    public var appearance: Appearance = .system
    /// How many items to keep from one feed. Long feeds are common and the
    /// tail is rarely read.
    public var feedItemLimit: Int = 100
    public var refreshOnOpen: Bool = true

    // Listening
    public var skipForwardSeconds: Int = 30
    public var skipBackwardSeconds: Int = 15
    /// Keep playing when the app goes to the background. Off means audio stops
    /// with the screen, which some people prefer for battery.
    public var continueInBackground: Bool = true

    // Network
    /// Streaming video over cellular is the setting people most regret not
    /// having, so it is explicit and defaults to WiFi-only.
    public var allowCellularStreaming: Bool = false

    public init() {}

    // MARK: - tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case openLinksIn, appearance, feedItemLimit, refreshOnOpen
        case skipForwardSeconds, skipBackwardSeconds, continueInBackground
        case allowCellularStreaming
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()

        // `decodeIfPresent` throughout: a blob written by an older build is
        // missing the newer keys, and must still decode.
        openLinksIn = (try? c.decodeIfPresent(LinkTarget.self, forKey: .openLinksIn))
            .flatMap { $0 } ?? defaults.openLinksIn
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance))
            .flatMap { $0 } ?? defaults.appearance
        refreshOnOpen = try c.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? defaults.refreshOnOpen
        continueInBackground = try c.decodeIfPresent(Bool.self, forKey: .continueInBackground)
            ?? defaults.continueInBackground
        allowCellularStreaming = try c.decodeIfPresent(Bool.self, forKey: .allowCellularStreaming)
            ?? defaults.allowCellularStreaming

        feedItemLimit = Self.clamp(
            try c.decodeIfPresent(Int.self, forKey: .feedItemLimit) ?? defaults.feedItemLimit,
            to: Self.feedItemLimitRange)
        skipForwardSeconds = Self.clamp(
            try c.decodeIfPresent(Int.self, forKey: .skipForwardSeconds) ?? defaults.skipForwardSeconds,
            to: Self.skipRange)
        skipBackwardSeconds = Self.clamp(
            try c.decodeIfPresent(Int.self, forKey: .skipBackwardSeconds) ?? defaults.skipBackwardSeconds,
            to: Self.skipRange)
    }

    public static let feedItemLimitRange = 10...500
    public static let skipRange = 5...120
    public static let skipChoices = [10, 15, 30, 45, 60]

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Observable holder. One instance, injected through the environment, so a
/// change anywhere updates every screen that reads it.
@MainActor
public final class Settings: ObservableObject {

    @Published public var value: AppSettings {
        didSet { persist() }
    }

    /// True when the stored settings could not be read and defaults were used.
    /// Settings are cheap to recreate — unlike the subscription list, which
    /// refuses to overwrite itself — but the user should still be told rather
    /// than left wondering why their preferences changed.
    public private(set) var didResetFromCorruption = false

    private let store: KeyValueStore
    private let key: String

    public init(store: KeyValueStore = UserDefaults.standard,
                key: String = "toolbelt.settings.v1") {
        self.store = store
        self.key = key

        guard let data = store.data(forKey: key) else {
            value = AppSettings()
            return
        }
        if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
        } else {
            value = AppSettings()
            didResetFromCorruption = true
        }
    }

    public func reset() { value = AppSettings() }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
        didResetFromCorruption = false
    }
}
