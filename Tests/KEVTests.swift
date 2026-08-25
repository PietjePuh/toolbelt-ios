import XCTest
@testable import Toolbelt

final class KEVTests: XCTestCase {

    private let sample = Data("""
    {
      "title": "CISA Catalog of Known Exploited Vulnerabilities",
      "catalogVersion": "2026.08.25",
      "dateReleased": "2026-08-25T14:00:00.0000Z",
      "count": 2,
      "vulnerabilities": [
        {
          "cveID": "CVE-2021-44228",
          "vendorProject": "Apache",
          "product": "Log4j2",
          "vulnerabilityName": "Apache Log4j2 Remote Code Execution Vulnerability",
          "dateAdded": "2021-12-10",
          "shortDescription": "Log4j2 contains a JNDI injection vulnerability.",
          "requiredAction": "Apply updates per vendor instructions.",
          "dueDate": "2021-12-24",
          "knownRansomwareCampaignUse": "Known",
          "cwes": ["CWE-917"]
        },
        {
          "cveID": "CVE-2026-0001",
          "vendorProject": "Example",
          "product": "Widget",
          "vulnerabilityName": "Example flaw",
          "dateAdded": "2026-08-01",
          "shortDescription": "Something bad.",
          "requiredAction": "Patch it.",
          "dueDate": "2026-08-22",
          "knownRansomwareCampaignUse": "Unknown"
        }
      ]
    }
    """.utf8)

    func testParsesTheCatalogue() throws {
        let catalogue = try KEVCatalogue.parse(sample)
        XCTAssertEqual(catalogue.version, "2026.08.25")
        XCTAssertEqual(catalogue.entries.count, 2)
        XCTAssertEqual(catalogue.skipped, 0)
        XCTAssertNotNil(catalogue.released)

        let log4j = catalogue.entries[0]
        XCTAssertEqual(log4j.cveID, "CVE-2021-44228")
        XCTAssertEqual(log4j.vendorAndProduct, "Apache Log4j2")
        XCTAssertEqual(log4j.ransomware, .known)
        XCTAssertEqual(log4j.cwes, ["CWE-917"])
        XCTAssertNotNil(log4j.dueDate)
    }

    func testRansomwareIsTriStateNotBoolean() throws {
        // "Unknown" must never render as a confirmed negative — it is the most
        // consequential field in the record for triage.
        let catalogue = try KEVCatalogue.parse(sample)
        XCTAssertEqual(catalogue.entries[1].ransomware, .unknown)

        // Anything CISA has not explicitly marked "Known" is unknown, including
        // a value we have never seen before.
        let odd = try KEVCatalogue.parse(Data("""
        {"vulnerabilities":[{"cveID":"CVE-2026-1111","knownRansomwareCampaignUse":"Probably"}]}
        """.utf8))
        XCTAssertEqual(odd.entries.first?.ransomware, .unknown)
    }

    // MARK: - refusals

    func testAnErrorPageIsNotAnEmptyCatalogue() {
        // A captive portal returning 200 must not read as "no known exploited
        // vulnerabilities", which is the most dangerous possible false-clean in
        // this whole app.
        XCTAssertThrowsError(try KEVCatalogue.parse(Data("<html>Sign in to Wi-Fi</html>".utf8))) { err in
            XCTAssertEqual(err as? KEVParseError, .notTheCatalogue)
        }
        XCTAssertThrowsError(try KEVCatalogue.parse(Data("{\"title\":\"something else\"}".utf8))) { err in
            XCTAssertEqual(err as? KEVParseError, .notTheCatalogue)
        }
    }

    func testAGenuinelyEmptyCatalogueIsNotAnError() throws {
        // Distinct from the above: this IS the catalogue, it just has no rows.
        let catalogue = try KEVCatalogue.parse(Data("""
        {"catalogVersion":"2026.01.01","vulnerabilities":[]}
        """.utf8))
        XCTAssertTrue(catalogue.entries.isEmpty)
        XCTAssertEqual(catalogue.skipped, 0)
    }

    func testUnreadableRowsAreCountedNotDropped() throws {
        let catalogue = try KEVCatalogue.parse(Data("""
        {"vulnerabilities":[
          {"cveID":"CVE-2026-0002","product":"P"},
          {"product":"no id"},
          {"cveID":"not-a-cve"},
          {"cveID":"CVE-20x6-0003"}
        ]}
        """.utf8))
        XCTAssertEqual(catalogue.entries.count, 1)
        XCTAssertEqual(catalogue.skipped, 3, "a short security list must admit the gap")
    }

    func testOversizedCatalogueIsRefused() {
        let big = Data(repeating: 0x20, count: KEVCatalogue.maxBytes + 1)
        XCTAssertThrowsError(try KEVCatalogue.parse(big)) { err in
            guard case .tooLarge? = err as? KEVParseError else {
                return XCTFail("expected .tooLarge")
            }
        }
    }

    // MARK: - dates and staleness

    func testUnparsableDatesAreNilNotToday() throws {
        // A wrong due date is worse than an absent one: it silently invents a
        // deadline that has passed or not.
        let catalogue = try KEVCatalogue.parse(Data("""
        {"vulnerabilities":[{"cveID":"CVE-2026-0004","dateAdded":"soon","dueDate":""}]}
        """.utf8))
        XCTAssertNil(catalogue.entries.first?.dateAdded)
        XCTAssertNil(catalogue.entries.first?.dueDate)
    }

    func testCatalogueAgeIsMeasuredFromPublicationNotFetch() throws {
        let catalogue = try KEVCatalogue.parse(sample)
        let released = try XCTUnwrap(catalogue.released)
        let tenDaysLater = released.addingTimeInterval(10 * 24 * 3600)
        XCTAssertEqual(catalogue.ageInDays(now: tenDaysLater), 10)
    }

    func testMissingReleaseDateYieldsUnknownAgeNotZero() throws {
        // Zero days old would claim the data is fresh, which is precisely the
        // claim we cannot make.
        let catalogue = try KEVCatalogue.parse(Data("""
        {"catalogVersion":"x","vulnerabilities":[]}
        """.utf8))
        XCTAssertNil(catalogue.ageInDays(now: Date()))
    }

    // MARK: - linking out

    func testCVEIdIsValidatedBeforeItReachesAURL() {
        for bad in ["not-a-cve", "CVE-21-44228", "CVE-2021-44", "CVE-2021-abcd",
                    "CVE-2021-44228/../evil", ""] {
            XCTAssertFalse(KEVEntry.isWellFormedCVE(bad), bad)
        }
        for good in ["CVE-2021-44228", "CVE-2026-0001", "CVE-2024-123456"] {
            XCTAssertTrue(KEVEntry.isWellFormedCVE(good), good)
        }
    }

    func testMalformedIdProducesNoLinkRatherThanABadOne() throws {
        let catalogue = try KEVCatalogue.parse(sample)
        XCTAssertEqual(catalogue.entries[0].nvdURL?.absoluteString,
                       "https://nvd.nist.gov/vuln/detail/CVE-2021-44228")
    }

    func testCatalogueURLIsHTTPSAndCISA() {
        XCTAssertEqual(KEVService.catalogueURL.scheme, "https")
        XCTAssertEqual(KEVService.catalogueURL.host, "www.cisa.gov")
    }
}
