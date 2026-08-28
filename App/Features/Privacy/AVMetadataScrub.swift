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

        // ISO user data uses FOUR-CHARACTER codes — ©xyz, ©mak, ©too — and
        // they have no convenient constants. They are matched explicitly
        // because substring matching does not work on them: "©mak" does not
        // contain "make", and "©too" does not contain "tool". An earlier
        // version missed both and classified the device make of any converted
        // file as `other`.
        let code = String(id.suffix(3))
        switch code {
        case "xyz":                      return .location
        case "mak", "mod":               return .device
        case "too", "swr", "enc":        return .software
        case "day":                      return .creationDate
        case "nam", "art", "alb", "cmt", "des", "cpy", "wrt":
                                         return .title
        default:                         break
        }

        // Longer, dotted keys — the QuickTime metadata space.
        if id.contains("location") || id.contains("gps") { return .location }
        if id.contains("make") || id.contains("model") || id.contains("device") {
            return .device
        }
        if id.contains("software") || id.contains("encoder") || id.contains("tool") {
            return .software
        }
        if id.contains("creationdate") || id.contains("creation_date") || id.contains("date") {
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

    /// Write a copy carrying no metadata, then verify it.
    ///
    /// NOT `AVAssetExportSession`. Setting `session.metadata = []` means "add
    /// nothing", not "remove what is there" — with the passthrough preset the
    /// original location, make and model come straight through. That is not
    /// documented anywhere obvious and was found by the verification step
    /// failing, which is the second time in this feature that an Apple API
    /// carried metadata across when asked not to.
    ///
    /// So the file is REMUXED instead: the compressed samples are read and
    /// written into a fresh container. Nothing is copied except the media
    /// itself, so nothing can survive. It is still lossless — the samples are
    /// passed through untouched, never re-encoded.
    public static func scrub(_ input: URL, to output: URL) async throws -> Report {
        let found = try await inspect(input)
        try await remux(input, to: output)

        // The step that justifies telling the user anything.
        let remaining = (try? await inspect(output)) ?? found
        return Report(found: found, remaining: remaining)
    }

    static func remux(_ input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            throw ScrubError.unreadable(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw ScrubError.noExportableTrack }

        try? FileManager.default.removeItem(at: output)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: output, fileType: fileType(for: output))
        } catch {
            throw ScrubError.exportFailed(error.localizedDescription)
        }
        // Nothing is carried over; only what is set here ends up in the file.
        writer.metadata = []

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in tracks {
            // `outputSettings: nil` on both sides means the compressed samples
            // are handed across untouched — a remux, not a re-encode.
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { continue }
            reader.add(readerOutput)

            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let writerInput = AVAssetWriterInput(mediaType: track.mediaType,
                                                 outputSettings: nil,
                                                 sourceFormatHint: formats.first)
            writerInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerInput) else { continue }
            writer.add(writerInput)

            pairs.append((readerOutput, writerInput))
        }
        guard !pairs.isEmpty else { throw ScrubError.noExportableTrack }

        guard writer.startWriting() else {
            throw ScrubError.exportFailed(writer.error?.localizedDescription ?? "writer refused to start")
        }
        guard reader.startReading() else {
            throw ScrubError.exportFailed(reader.error?.localizedDescription ?? "reader refused to start")
        }
        writer.startSession(atSourceTime: .zero)

        for (readerOutput, writerInput) in pairs {
            let queue = DispatchQueue(label: "nl.pietjepuh.toolbelt.remux")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // requestMediaDataWhenReady calls back repeatedly; the flag
                // keeps the continuation to exactly one resume.
                let finished = ManagedAtomicFlag()
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        guard let buffer = readerOutput.copyNextSampleBuffer() else {
                            writerInput.markAsFinished()
                            if finished.setIfUnset() { continuation.resume() }
                            return
                        }
                        if !writerInput.append(buffer) {
                            writerInput.markAsFinished()
                            if finished.setIfUnset() { continuation.resume() }
                            return
                        }
                    }
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ScrubError.exportFailed(writer.error?.localizedDescription
                                          ?? "writing did not complete")
        }
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

/// One-shot flag. `requestMediaDataWhenReady` invokes its block repeatedly and
/// from an arbitrary queue, so resuming a continuation from inside it needs a
/// guard — resuming twice is a crash, not a warning.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// Returns true exactly once, for the first caller.
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}
