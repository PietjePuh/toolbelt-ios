import XCTest
@testable import Toolbelt

private final class MemoryDefaults: KeyValueStore {
    var contents: [String: Data] = [:]
    func data(forKey key: String) -> Data? { contents[key] }
    func set(_ value: Data?, forKey key: String) { contents[key] = value }
}

final class AppSettingsTests: XCTestCase {

    // MARK: - the property that keeps preferences alive across versions

    func testBlobFromAnOlderBuildStillDecodes() throws {
        // The failure this prevents: adding one field makes every stored blob
        // undecodable, so the user silently loses every OTHER preference too.
        let old = Data("""
        {"openLinksIn":"safari","feedItemLimit":42}
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(decoded.openLinksIn, .safari, "the value that WAS stored survives")
        XCTAssertEqual(decoded.feedItemLimit, 42)
        // Fields the old build never wrote fall back to defaults.
        XCTAssertEqual(decoded.skipForwardSeconds, AppSettings().skipForwardSeconds)
        XCTAssertEqual(decoded.allowCellularStreaming, AppSettings().allowCellularStreaming)
    }

    func testEmptyObjectDecodesToAllDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppSettings())
    }

    func testUnknownEnumValueFallsBackInsteadOfThrowing() throws {
        // A value written by a NEWER build, or edited by hand. Losing one
        // preference beats losing the whole settings object.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {"appearance":"solarized","openLinksIn":"telepathy","feedItemLimit":50}
        """.utf8))
        XCTAssertEqual(decoded.appearance, .system)
        XCTAssertEqual(decoded.openLinksIn, .inApp)
        XCTAssertEqual(decoded.feedItemLimit, 50, "the readable fields still apply")
    }

    func testOutOfRangeValuesAreClampedNotRejected() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {"feedItemLimit":100000,"skipForwardSeconds":-5,"skipBackwardSeconds":99999}
        """.utf8))
        XCTAssertEqual(decoded.feedItemLimit, AppSettings.feedItemLimitRange.upperBound)
        XCTAssertEqual(decoded.skipForwardSeconds, AppSettings.skipRange.lowerBound)
        XCTAssertEqual(decoded.skipBackwardSeconds, AppSettings.skipRange.upperBound)
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.openLinksIn = .safari
        settings.appearance = .dark
        settings.skipForwardSeconds = 45
        settings.allowCellularStreaming = true

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testCellularStreamingIsOffByDefault() {
        // Live TV can use gigabytes an hour. Opt in, not out.
        XCTAssertFalse(AppSettings().allowCellularStreaming)
    }

    // MARK: - store

    @MainActor
    func testChangesPersistImmediately() {
        let defaults = MemoryDefaults()
        let settings = Settings(store: defaults, key: "k")
        settings.value.appearance = .dark

        let reloaded = Settings(store: defaults, key: "k")
        XCTAssertEqual(reloaded.value.appearance, .dark)
        XCTAssertFalse(reloaded.didResetFromCorruption)
    }

    @MainActor
    func testCorruptSettingsFallBackToDefaultsAndSaySo() {
        // Unlike the subscription list, settings are cheap to recreate — so
        // defaults are correct here. But the user is told, rather than left
        // wondering why their preferences changed.
        let defaults = MemoryDefaults()
        defaults.contents["k"] = Data("not json".utf8)

        let settings = Settings(store: defaults, key: "k")
        XCTAssertEqual(settings.value, AppSettings())
        XCTAssertTrue(settings.didResetFromCorruption)
    }

    @MainActor
    func testNeverSavedIsNotReportedAsCorrupt() {
        let settings = Settings(store: MemoryDefaults(), key: "k")
        XCTAssertFalse(settings.didResetFromCorruption)
    }
}

final class StreamSupportTests: XCTestCase {

    func testHLSAndProgressiveAreSupported() {
        for raw in ["https://p.example/live/1.m3u8", "https://p.example/vod/film.mp4",
                    "https://p.example/a.mov"] {
            XCTAssertEqual(StreamSupport.assess(URL(string: raw)!), .supported, raw)
        }
    }

    func testMulticastIsNamedNotJustRefused() {
        // udp:// in a playlist is normal — it works on the provider's LAN and
        // never over the internet. The user needs telling which it is.
        guard case .unsupported(let reason) = StreamSupport.assess(URL(string: "udp://@239.0.0.1:1234")!) else {
            return XCTFail("expected unsupported")
        }
        XCTAssertTrue(reason.lowercased().contains("network"))
    }

    func testRawTransportStreamIsUnsupported() {
        guard case .unsupported(let reason) = StreamSupport.assess(URL(string: "https://p.example/live/1.ts")!) else {
            return XCTFail("expected unsupported")
        }
        XCTAssertTrue(reason.contains("TS"))
    }

    func testExtensionlessURLIsWorthTryingNotRejected() {
        // Most HLS endpoints look like /live/12345 with no extension. Refusing
        // those would break the common case.
        XCTAssertEqual(StreamSupport.assess(URL(string: "https://p.example/live/12345")!), .worthTrying)
        XCTAssertTrue(StreamSupport.assess(URL(string: "https://p.example/live/12345")!).canAttempt)
    }

    func testQueryStringDoesNotConfuseTheExtensionCheck() {
        // Provider URLs carry tokens: ...playlist.m3u8?token=abc.ts
        XCTAssertEqual(
            StreamSupport.assess(URL(string: "https://p.example/live.m3u8?token=abc.ts")!),
            .supported)
    }

    func testRTSPIsUnsupported() {
        XCTAssertFalse(StreamSupport.assess(URL(string: "rtsp://p.example/s")!).canAttempt)
    }
}
