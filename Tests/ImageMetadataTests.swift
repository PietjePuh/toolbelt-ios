import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Toolbelt

final class ImageMetadataTests: XCTestCase {

    /// Builds a real JPEG in memory carrying the metadata a phone would attach:
    /// GPS, EXIF, TIFF make/model, and an embedded thumbnail. Synthesising it
    /// beats shipping a fixture photo, because the test then states exactly
    /// what it is testing against.
    private func makePhoto(withGPS: Bool = true, thumbnail: Bool = true) throws -> Data {
        let width = 32, height = 32
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x80, count: bytesPerRow * height)

        let context = pixels.withUnsafeMutableBytes { buffer -> CGContext? in
            CGContext(data: buffer.baseAddress,
                      width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let image = try XCTUnwrap(context?.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))

        var props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:25 14:30:00",
                kCGImagePropertyExifLensModel: "Test Lens"
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 17 Pro"
            ] as [CFString: Any]
        ]
        if withGPS {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.3676,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 4.9041,
                kCGImagePropertyGPSLongitudeRef: "E"
            ] as [CFString: Any]
        }
        if thumbnail {
            props[kCGImageDestinationEmbedThumbnail] = true
        }

        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: - the fixture has to be real, or the test proves nothing

    func testTheTestPhotoActuallyCarriesLocation() throws {
        // If this fails, every scrubbing test below would pass trivially by
        // removing something that was never there.
        let found = try ImageMetadata.inspect(try makePhoto())
        XCTAssertTrue(found.contains(.gps), "fixture has no GPS — the other tests would be meaningless")
        XCTAssertTrue(found.contains(.tiff))
        XCTAssertTrue(found.contains(.exif))
    }

    // MARK: - stripping

    func testLocationIsRemoved() throws {
        let (scrubbed, report) = try ImageMetadata.scrub(try makePhoto())
        XCTAssertFalse(try ImageMetadata.inspect(scrubbed).contains(.gps))
        XCTAssertFalse(report.remaining.contains(.gps))
    }

    func testDeviceMakeAndModelAreRemoved() throws {
        // "Apple / iPhone 17 Pro" is not location, but it narrows who took it.
        let (scrubbed, _) = try ImageMetadata.scrub(try makePhoto())
        XCTAssertFalse(try ImageMetadata.inspect(scrubbed).contains(.tiff))
    }

    func testTheEmbeddedThumbnailIsNotCarriedOver() throws {
        // The subtle one, and the reason the fallback exists: the preview is a
        // second image with its own metadata, and
        // CGImageDestinationAddImageFromSource carries it across regardless of
        // kCGImageDestinationEmbedThumbnail. The lossless pass cannot remove
        // it; verification catches that and the re-encode does.
        let original = try makePhoto(thumbnail: true)
        let (scrubbed, report) = try ImageMetadata.scrub(original)
        XCTAssertFalse(try ImageMetadata.inspect(scrubbed).contains(.thumbnail))
        XCTAssertTrue(report.remainingIdentifying.isEmpty,
                      "left over: \(report.remainingIdentifying.map(\.rawValue))")
    }

    func testTheFallbackOnlyRunsWhenItIsNeeded() throws {
        // Re-encoding costs quality, so it must not be the default. A file that
        // the lossless pass fully cleans should never be recompressed.
        let (_, report) = try ImageMetadata.scrub(try makePhoto(withGPS: true, thumbnail: false))
        XCTAssertTrue(report.remainingIdentifying.isEmpty)
        XCTAssertEqual(report.method, .lossless,
                       "recompressed a file that did not need it")
    }

    func testTheReportSaysWhichPathRan() throws {
        let (_, report) = try ImageMetadata.scrub(try makePhoto(thumbnail: true))
        XCTAssertEqual(report.method, .reencoded)
    }

    func testTheReportIsBuiltFromRereadingTheOutput() throws {
        // The property that makes this trustworthy: `isClean` must mean "we
        // looked and found nothing", not "the scrubber did not throw".
        let (scrubbed, report) = try ImageMetadata.scrub(try makePhoto())
        let actuallyRemaining = try ImageMetadata.inspect(scrubbed)
        XCTAssertEqual(Set(report.remaining), Set(actuallyRemaining),
                       "the report must match what is really in the file")
        XCTAssertEqual(report.isClean, actuallyRemaining.isEmpty)
    }

    func testReportNamesWhatWasFoundInTheOriginal() throws {
        let (_, report) = try ImageMetadata.scrub(try makePhoto())
        XCTAssertTrue(report.found.contains(.gps))
        XCTAssertTrue(report.found.contains(.tiff))
        XCTAssertGreaterThan(report.bytesBefore, 0)
        XCTAssertGreaterThan(report.bytesAfter, 0)
    }

    func testTheImageItselfSurvives() throws {
        // A scrubber that corrupts the picture has solved the wrong problem.
        let (scrubbed, _) = try ImageMetadata.scrub(try makePhoto())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(scrubbed as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
    }

    func testScrubbingAPhotoWithoutLocationStillWorks() throws {
        let (scrubbed, report) = try ImageMetadata.scrub(try makePhoto(withGPS: false))
        XCTAssertFalse(report.found.contains(.gps))
        XCTAssertFalse(try ImageMetadata.inspect(scrubbed).contains(.gps))
    }

    // MARK: - refusals

    func testNonImageDataIsRefused() {
        XCTAssertThrowsError(try ImageMetadata.scrub(Data("not an image".utf8))) { err in
            XCTAssertEqual(err as? ImageMetadata.ScrubError, .notAnImage)
        }
        XCTAssertThrowsError(try ImageMetadata.inspect(Data()))
    }

    // MARK: - severity

    func testIdentifyingCategoriesAreSeparatedFromHarmlessOnes() {
        // What is left over matters differently: a leftover caption is not a
        // leftover coordinate, and lumping them together would either cry wolf
        // or hide the one that counts.
        XCTAssertTrue(ImageMetadata.Category.gps.isIdentifying)
        XCTAssertTrue(ImageMetadata.Category.tiff.isIdentifying)
        XCTAssertTrue(ImageMetadata.Category.xmp.isIdentifying)
        XCTAssertTrue(ImageMetadata.Category.thumbnail.isIdentifying)
        XCTAssertFalse(ImageMetadata.Category.exif.isIdentifying)
    }

    func testEveryCategoryHasAPlainLanguageLabel() {
        for category in ImageMetadata.Category.allCases {
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertNotEqual(category.label, category.rawValue,
                              "\(category.rawValue) needs a human label, not its enum name")
        }
    }

    // MARK: - adding information back

    func testAnnotationWritesOnlyWhatWasAskedFor() throws {
        let (scrubbed, _) = try ImageMetadata.scrub(try makePhoto())
        let annotated = try ImageMetadata.annotate(scrubbed,
                                                   caption: "Rotterdam, no location attached",
                                                   author: "PietjePuh")
        let found = try ImageMetadata.inspect(annotated)
        XCTAssertTrue(found.contains(.iptc))
        // Annotating must not resurrect what was just removed.
        XCTAssertFalse(found.contains(.gps))
        XCTAssertFalse(found.contains(.tiff))
    }

    func testAnnotationIsReadableBack() throws {
        let annotated = try ImageMetadata.annotate(try makePhoto(withGPS: false),
                                                   caption: "hello", author: "me")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(annotated as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let iptc = props?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String, "hello")
    }

    func testXMPIsDetectedInRawBytesNotJustDictionaries() {
        // XMP survives a dictionary-only strip, so detection has to look at the
        // bytes — otherwise a second copy of the location goes unreported.
        let withXMP = Data("junk<x:xmpmeta xmlns:x='adobe:ns:meta/'>…</x:xmpmeta>".utf8)
        XCTAssertTrue(ImageMetadata.containsXMP(withXMP))
        XCTAssertFalse(ImageMetadata.containsXMP(Data("ordinary bytes".utf8)))
    }
}
