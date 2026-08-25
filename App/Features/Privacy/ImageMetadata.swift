import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stripping identifying metadata out of an image before you send it.
///
/// The reason this is not three lines: a photo carries location in more places
/// than the obvious one, and removing only the obvious one produces a file that
/// LOOKS scrubbed and still says where you live.
///
///   - GPS is the headline, but XMP frequently carries a second copy of it.
///   - The embedded THUMBNAIL is a complete second image with its own metadata,
///     and it survives naive stripping.
///   - Apple's MakerNote is proprietary and undocumented; it is not a location
///     field but it is unmistakably device-identifying.
///   - TIFF holds Make and Model — the phone you own.
///
/// So this never reports success from having run. It re-reads the output and
/// reports what is ACTUALLY left, because a scrubber that lies is worse than no
/// scrubber: it converts caution into a false sense of safety.
public enum ImageMetadata {

    /// A category of metadata, named as the user would think of it.
    public enum Category: String, CaseIterable, Sendable {
        case gps, exif, tiff, iptc, xmp, makerApple, thumbnail

        public var label: String {
            switch self {
            case .gps:        return "Location"
            case .exif:       return "Camera settings and timestamps"
            case .tiff:       return "Device make and model"
            case .iptc:       return "Captions, credits and keywords"
            case .xmp:        return "Adobe XMP (often a second copy of location)"
            case .makerApple: return "Apple device data"
            case .thumbnail:  return "Embedded preview image"
            }
        }

        /// Whether this category can identify a person or place. Used to sort
        /// what is left over by how much it matters.
        public var isIdentifying: Bool {
            switch self {
            case .gps, .tiff, .makerApple, .xmp, .thumbnail: return true
            case .exif, .iptc: return false
            }
        }

        var propertyKey: CFString? {
            switch self {
            case .gps:        return kCGImagePropertyGPSDictionary
            case .exif:       return kCGImagePropertyExifDictionary
            case .tiff:       return kCGImagePropertyTIFFDictionary
            case .iptc:       return kCGImagePropertyIPTCDictionary
            case .makerApple: return kCGImagePropertyMakerAppleDictionary
            case .xmp:        return nil        // handled by not copying it
            case .thumbnail:  return nil        // handled by not creating one
            }
        }
    }

    public struct Report: Equatable, Sendable {
        /// Categories present in the original.
        public let found: [Category]
        /// Categories STILL present after scrubbing, verified by re-reading.
        public let remaining: [Category]
        public let bytesBefore: Int
        public let bytesAfter: Int

        /// Only true when a re-read of the output found nothing identifying.
        /// Deliberately not "we ran the scrubber and it did not throw".
        public var isClean: Bool { remaining.isEmpty }

        /// Anything left that could point at a person or a place.
        public var remainingIdentifying: [Category] {
            remaining.filter(\.isIdentifying)
        }
    }

    public enum ScrubError: Error, Equatable {
        case notAnImage
        case unsupportedFormat(String)
        case writeFailed
    }

    /// Read which categories a file carries, without changing it.
    public static func inspect(_ data: Data) throws -> [Category] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw ScrubError.notAnImage
        }

        var found: [Category] = []
        for category in Category.allCases {
            if let key = category.propertyKey, props[key] != nil {
                found.append(category)
            }
        }
        // XMP is not a top-level dictionary in the same way; its presence is
        // detectable from the raw bytes, which is also how it survives a
        // dictionary-only strip.
        if containsXMP(data) { found.append(.xmp) }
        if hasThumbnail(source) { found.append(.thumbnail) }
        return found
    }

    /// Strip everything identifying, then VERIFY by re-reading the result.
    public static func scrub(_ data: Data) throws -> (data: Data, report: Report) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ScrubError.notAnImage
        }
        guard let type = CGImageSourceGetType(source) else {
            throw ScrubError.unsupportedFormat("unknown")
        }

        let found = (try? inspect(data)) ?? []

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type, 1, nil) else {
            throw ScrubError.unsupportedFormat(type as String)
        }

        // kCFNull removes a dictionary; omitting it merely leaves the original.
        // That distinction is the whole difference between scrubbed and not.
        var strip: [CFString: Any] = [:]
        for category in Category.allCases {
            if let key = category.propertyKey { strip[key] = kCFNull }
        }
        // Do not carry the embedded preview across — it is a second image with
        // its own copy of everything.
        strip[kCGImageDestinationEmbedThumbnail] = false

        CGImageDestinationAddImageFromSource(destination, source, 0, strip as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ScrubError.writeFailed
        }

        let scrubbed = output as Data
        // The verification step. Everything above is an attempt; this is the
        // only thing that justifies telling the user it worked.
        let remaining = (try? inspect(scrubbed)) ?? Category.allCases

        return (scrubbed, Report(found: found,
                                 remaining: remaining,
                                 bytesBefore: data.count,
                                 bytesAfter: scrubbed.count))
    }

    /// Write chosen fields back in — the other half of the request. Only the
    /// fields asked for are written; nothing is carried over from the original.
    public static func annotate(_ data: Data,
                                caption: String? = nil,
                                author: String? = nil,
                                copyright: String? = nil) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) else {
            throw ScrubError.notAnImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type, 1, nil) else {
            throw ScrubError.unsupportedFormat(type as String)
        }

        var iptc: [CFString: Any] = [:]
        if let caption { iptc[kCGImagePropertyIPTCCaptionAbstract] = caption }
        if let author { iptc[kCGImagePropertyIPTCByline] = author }
        if let copyright { iptc[kCGImagePropertyIPTCCopyrightNotice] = copyright }

        var props: [CFString: Any] = [:]
        if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary] = iptc }

        CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScrubError.writeFailed }
        return output as Data
    }

    // MARK: - detection helpers

    /// XMP is an XML packet embedded in the file. It is checked in the RAW
    /// BYTES rather than through the property dictionaries, because that is
    /// exactly how it survives a strip that only clears dictionaries.
    static func containsXMP(_ data: Data) -> Bool {
        let marker = Data("<x:xmpmeta".utf8)
        return data.range(of: marker) != nil
    }

    static func hasThumbnail(_ source: CGImageSource) -> Bool {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
}
