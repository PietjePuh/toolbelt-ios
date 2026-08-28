import AVFoundation
import Foundation

/// Stripping identifying metadata out of video and audio.
///
/// A video from a phone carries at least as much as a photo, in more places:
///
///   - `com.apple.quicktime.location.ISO6709` — the coordinates, as text.
///   - `©xyz` under ISO user data — the OLDER location tag. Files that have
///     been through a converter often carry this one and not the modern one,
///     so checking only the QuickTime key misses them entirely.
///   - `com.apple.quicktime.make` / `.model` / `.software` — the device.
///   - `com.apple.quicktime.creationdate` — with timezone offset, which is
///     itself a coarse location.
///
/// Same rule as the image scrubber: the output is RE-READ afterwards and the
/// report says what is actually left. Nothing here claims success from having
/// run without error.
public enum AVMetadataScrub {

    public enum Category: String, CaseIterable, Sendable, Equatable {
        case location, device, software, creationDate, title, other

        public var label: String {
            switch self {
            case .location:     return "Location"
            case .device:       return "Device make and model"
            case .software:     return "Software that produced the file"
            case .creationDate: return "Creation date and timezone"
            case .title:        return "Title, artist and description"
            case .other:        return "Other metadata"
            }
        }

        /// Whether it can point at a person or a place.
        ///
        /// `creationDate` counts, and that is not over-caution: QuickTime
        /// creation dates carry a UTC OFFSET, which narrows down where the
        /// recording happened even with the coordinates gone.
        public var isIdentifying: Bool {
            switch self {
            case .location, .device, .software, .creationDate: return true
            case .title, .other: return false
            }
        }
    }

    /// Classify by identifier string.
    ///
    /// Kept as string matching rather than `AVMetadataIdentifier` constants so
    /// it is testable without constructing AVFoundation objects — and because
    /// the identifiers that matter most, the ISO user data ones, have no
    /// convenient constants.
    public static func classify(_ identifier: String) -> Category {
        let id = identifier.lowercased()

        // Location. The ISO user data key is `©xyz`; the copyright sign is
        // often mangled by tooling, so the four-character suffix is matched
        // rather than the exact byte sequence.
        if id.contains("location") || id.hasSuffix("xyz") || id.contains("gps") {
            return .location
        }
        if id.contains("make") || id.contains("model") || id.contains("device") {
            return .device
        }
        if id.contains("software") || id.contains("encoder") || id.contains("tool") {
            return .software
        }
        if id.contains("creationdate") || id.contains("creation_date")
            || id.hasSuffix("day") || id.contains("date") {
            return .creationDate
        }
        if id.contains("title") || id.contains("artist") || id.contains("album")
            || id.contains("description") || id.contains("comment")
            || id.contains("author") || id.contains("copyright") {
            return .title
        }
        return .other
    }

    public struct Found: Equatable, Sendable {
        public let identifier: String
        public let category: Category
    }

    public struct Report: Equatable, Sendable {
        public let found: [Found]
        /// Verified by re-reading the exported file.
        public let remaining: [Found]

        public var isClean: Bool { remainingIdentifying.isEmpty }
        public var remainingIdentifying: [Found] {
            remaining.filter { $0.category.isIdentifying }
        }
    }

    public enum ScrubError: Error, Equatable {
        case unreadable(String)
        case noExportableTrack
        case exportFailed(String)
        /// The export finished but the file still carries identifying
        /// metadata. Reported rather than swallowed — a scrubber that cannot
        /// guarantee the result must say so instead of implying success.
        case stillIdentifying([String])
    }

    /// Read what a file carries, without changing it.
    public static func inspect(_ url: URL) async throws -> [Found] {
        let asset = AVURLAsset(url: url)
        var found: [Found] = []

        do {
            // Every space, not just the QuickTime one — a converted file often
            // carries its location only in ISO user data.
            for format in try await asset.load(.availableMetadataFormats) {
                for item in try await asset.loadMetadata(for: format) {
                    let raw = item.identifier?.rawValue ?? item.key?.description ?? "unknown"
                    found.append(Found(identifier: raw, category: classify(raw)))
                }
            }
        } catch {
            throw ScrubError.unreadable(error.localizedDescription)
        }
        return found
    }

    /// Export a copy with no metadata, then verify it.
    ///
    /// Passthrough preset: the audio and video are copied, not re-encoded, so
    /// there is no quality loss. Metadata is dropped by handing the export an
    /// empty list rather than by editing the original.
    public static func scrub(_ input: URL, to output: URL) async throws -> Report {
        let asset = AVURLAsset(url: input)
        let found = try await inspect(input)

        guard try await !asset.load(.tracks).isEmpty else {
            throw ScrubError.noExportableTrack
        }

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ScrubError.exportFailed("no passthrough preset for this file")
        }

        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = fileType(for: input)
        // The strip itself: an empty list, not a filtered one. Filtering keeps
        // whatever the filter did not think of.
        session.metadata = []

        await session.export()

        guard session.status == .completed else {
            throw ScrubError.exportFailed(session.error?.localizedDescription
                                          ?? "export did not complete")
        }

        // The step that justifies telling the user anything.
        let remaining = (try? await inspect(output)) ?? found
        return Report(found: found, remaining: remaining)
    }

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov":         return .mov
        case "m4a":         return .m4a
        case "m4v":         return .m4v
        case "mp3":         return .mp3
        case "wav":         return .wav
        case "aiff", "aif": return .aiff
        default:            return .mp4
        }
    }
}
