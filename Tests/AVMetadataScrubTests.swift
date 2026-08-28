import AVFoundation
import XCTest
@testable import Toolbelt

final class AVMetadataClassificationTests: XCTestCase {

    private func classify(_ s: String) -> AVMetadataScrub.Category {
        AVMetadataScrub.classify(s)
    }

    func testTheQuickTimeLocationKey() {
        // What an iPhone actually writes.
        XCTAssertEqual(classify("mdta/com.apple.quicktime.location.ISO6709"), .location)
    }

    func testTheOlderISOUserDataLocationKey() {
        // The one that gets missed: a file that has been through a converter
        // often carries its location ONLY here, so checking the QuickTime key
        // alone leaves the coordinates in place.
        XCTAssertEqual(classify("udta/©xyz"), .location)
        XCTAssertEqual(classify("udta/xyz"), .location)
    }

    func testDeviceKeys() {
        for id in ["mdta/com.apple.quicktime.make",
                   "mdta/com.apple.quicktime.model",
                   "udta/©mak"] {
            XCTAssertEqual(classify(id), .device, id)
        }
    }

    func testSoftwareKeys() {
        XCTAssertEqual(classify("mdta/com.apple.quicktime.software"), .software)
        XCTAssertEqual(classify("udta/©too"), .software)
    }

    func testCreationDateIsTreatedAsIdentifying() {
        // Not over-caution: a QuickTime creation date carries a UTC OFFSET,
        // which narrows down where the recording happened even once the
        // coordinates are gone.
        XCTAssertEqual(classify("mdta/com.apple.quicktime.creationdate"), .creationDate)
        XCTAssertTrue(AVMetadataScrub.Category.creationDate.isIdentifying)
    }

    func testTitlesAreNotIdentifying() {
        // A song title is not a coordinate. Treating them alike would make the
        // report cry wolf on every music file.
        for id in ["udta/©nam", "udta/©ART", "udta/©alb", "id3/TIT2"] {
            XCTAssertFalse(classify(id).isIdentifying, id)
        }
    }

    func testUnknownKeysAreOtherAndNotIdentifying() {
        // Guessing that an unrecognised key is dangerous would flag every file
        // forever; guessing it is safe is the opposite error. `other` is
        // reported but not treated as identifying, and the report lists it so
        // the user can look.
        XCTAssertEqual(classify("mdta/com.example.something"), .other)
        XCTAssertFalse(AVMetadataScrub.Category.other.isIdentifying)
    }

    func testEveryCategoryHasAPlainLabel() {
        for c in AVMetadataScrub.Category.allCases {
            XCTAssertFalse(c.label.isEmpty)
            XCTAssertNotEqual(c.label, c.rawValue)
        }
    }

    func testFileTypeFollowsTheExtension() {
        XCTAssertEqual(AVMetadataScrub.fileType(for: URL(fileURLWithPath: "/a/b.mov")), .mov)
        XCTAssertEqual(AVMetadataScrub.fileType(for: URL(fileURLWithPath: "/a/b.m4a")), .m4a)
        XCTAssertEqual(AVMetadataScrub.fileType(for: URL(fileURLWithPath: "/a/b.MP4")), .mp4)
        XCTAssertEqual(AVMetadataScrub.fileType(for: URL(fileURLWithPath: "/a/b")), .mp4)
    }
}

/// End-to-end against a real movie written by the test, because a scrubber that
/// has only been reasoned about is not a scrubber that works — this session has
/// shipped four things that looked right and did nothing.
final class AVMetadataScrubIntegrationTests: XCTestCase {

    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// A tiny real .mov carrying the metadata an iPhone attaches.
    private func makeMovie() async throws -> URL {
        let url = temporary.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        location.value = "+52.3676+004.9041/" as NSString

        let make = AVMutableMetadataItem()
        make.identifier = .quickTimeMetadataMake
        make.value = "Apple" as NSString

        let model = AVMutableMetadataItem()
        model.identifier = .quickTimeMetadataModel
        model.value = "iPhone 17 Pro" as NSString

        writer.metadata = [location, make, model]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ])
        writer.add(input)

        XCTAssertTrue(writer.startWriting(), "writer failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0x40,
                   CVPixelBufferGetBytesPerRow(pixels) * 64)
            CVPixelBufferUnlockBaseAddress(pixels, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "writer: \(String(describing: writer.error))")
        return url
    }

    func testTheFixtureReallyCarriesLocation() async throws {
        // If this fails, every scrubbing assertion below would pass trivially
        // by removing something that was never there.
        let found = try await AVMetadataScrub.inspect(try await makeMovie())
        XCTAssertTrue(found.contains { $0.category == .location },
                      "fixture carries no location; found: \(found.map(\.identifier))")
    }

    func testLocationAndDeviceAreRemoved() async throws {
        let source = try await makeMovie()
        let output = temporary.appendingPathComponent("clean.mov")

        let report = try await AVMetadataScrub.scrub(source, to: output)

        XCTAssertTrue(report.found.contains { $0.category == .location })
        XCTAssertTrue(report.remainingIdentifying.isEmpty,
                      "left behind: \(report.remainingIdentifying.map(\.identifier))")
        XCTAssertTrue(report.isClean)
    }

    func testTheReportIsBuiltFromRereadingTheOutput() async throws {
        let source = try await makeMovie()
        let output = temporary.appendingPathComponent("clean2.mov")
        let report = try await AVMetadataScrub.scrub(source, to: output)

        let actual = try await AVMetadataScrub.inspect(output)
        XCTAssertEqual(Set(report.remaining.map(\.identifier)),
                       Set(actual.map(\.identifier)),
                       "the report must describe the file, not the intention")
    }

    func testTheVideoItselfSurvives() async throws {
        // A scrubber that produces an unplayable file has solved the wrong
        // problem. Passthrough means the track is copied, not re-encoded.
        let source = try await makeMovie()
        let output = temporary.appendingPathComponent("clean3.mov")
        _ = try await AVMetadataScrub.scrub(source, to: output)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        XCTAssertFalse(tracks.isEmpty, "output has no tracks")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    func testAMissingFileIsReportedNotSwallowed() async {
        let missing = temporary.appendingPathComponent("nope.mov")
        do {
            _ = try await AVMetadataScrub.scrub(missing, to: temporary.appendingPathComponent("o.mov"))
            XCTFail("expected a failure for a file that does not exist")
        } catch {
            // Any typed failure is fine; silence is not.
        }
    }
}
