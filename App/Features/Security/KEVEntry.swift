import Foundation

/// One entry from CISA's Known Exploited Vulnerabilities catalogue.
///
/// KEV is the right feed for a phone: it is not "every CVE ever published", it
/// is the far shorter list of vulnerabilities that are *actually being
/// exploited in the wild*. That distinction is the whole value — a CVE list
/// sorted by severity mostly tells you what could theoretically go wrong,
/// while KEV tells you what is going wrong right now.
public struct KEVEntry: Equatable, Sendable, Identifiable {

    public var id: String { cveID }
    public let cveID: String
    public let vendorProject: String
    public let product: String
    public let name: String
    public let shortDescription: String
    public let requiredAction: String
    public let dateAdded: Date?
    public let dueDate: Date?
    /// CISA states this explicitly, and it is the single most useful triage
    /// signal in the record — so it is a tri-state, never a Bool. "Unknown" is
    /// not "no".
    public let ransomware: RansomwareUse
    public let cwes: [String]

    public enum RansomwareUse: String, Sendable, Equatable {
        case known = "Known"
        case unknown = "Unknown"

        public var label: String {
            switch self {
            case .known:   return "Used in ransomware"
            case .unknown: return "No ransomware link reported"
            }
        }
    }

    public var vendorAndProduct: String { "\(vendorProject) \(product)" }

    public init(cveID: String, vendorProject: String, product: String, name: String,
                shortDescription: String, requiredAction: String,
                dateAdded: Date?, dueDate: Date?,
                ransomware: RansomwareUse, cwes: [String]) {
        self.cveID = cveID
        self.vendorProject = vendorProject
        self.product = product
        self.name = name
        self.shortDescription = shortDescription
        self.requiredAction = requiredAction
        self.dateAdded = dateAdded
        self.dueDate = dueDate
        self.ransomware = ransomware
        self.cwes = cwes
    }

    /// Link out to the authoritative record rather than restating it. The app
    /// shows CISA's summary; anything deeper should be read at the source.
    public var nvdURL: URL? {
        guard Self.isWellFormedCVE(cveID) else { return nil }
        return URL(string: "https://nvd.nist.gov/vuln/detail/\(cveID)")
    }

    /// `CVE-YYYY-NNNN+`. The id is interpolated into a URL, and it arrives from
    /// a third party — so it is validated rather than trusted.
    static func isWellFormedCVE(_ id: String) -> Bool {
        let parts = id.split(separator: "-")
        guard parts.count == 3, parts[0] == "CVE",
              parts[1].count == 4, parts[1].allSatisfy(\.isNumber),
              parts[2].count >= 4, parts[2].allSatisfy(\.isNumber) else { return false }
        return true
    }
}

/// The catalogue as published, including how old it is.
public struct KEVCatalogue: Equatable, Sendable {
    public let version: String
    /// When CISA published this catalogue — not when we fetched it.
    public let released: Date?
    public let entries: [KEVEntry]
    /// Records CISA counted but we could not read. Surfaced rather than
    /// dropped: a security list that is quietly short is worse than one that
    /// admits a gap.
    public let skipped: Int

    /// Deliberately takes `now`, so staleness is testable and the view and the
    /// model cannot disagree.
    public func ageInDays(now: Date) -> Int? {
        guard let released else { return nil }
        return Calendar(identifier: .gregorian)
            .dateComponents([.day], from: released, to: now).day
    }
}

public enum KEVParseError: Error, Equatable {
    /// Parsed as JSON but is not the KEV catalogue. Distinct from an empty
    /// catalogue — a captive portal or an error page must never render as
    /// "no known exploited vulnerabilities".
    case notTheCatalogue
    case tooLarge(bytes: Int)
}

extension KEVCatalogue {

    /// The catalogue is a few MB of JSON and grows slowly. Generous but finite.
    public static let maxBytes = 32 * 1024 * 1024

    public static func parse(_ data: Data) throws -> KEVCatalogue {
        guard data.count <= maxBytes else { throw KEVParseError.tooLarge(bytes: data.count) }

        struct Envelope: Decodable {
            let catalogVersion: String?
            let dateReleased: String?
            let vulnerabilities: [Row]?

            struct Row: Decodable {
                let cveID: String?
                let vendorProject: String?
                let product: String?
                let vulnerabilityName: String?
                let shortDescription: String?
                let requiredAction: String?
                let dateAdded: String?
                let dueDate: String?
                let knownRansomwareCampaignUse: String?
                let cwes: [String]?
            }
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let rows = env.vulnerabilities else {
            throw KEVParseError.notTheCatalogue
        }

        var entries: [KEVEntry] = []
        var skipped = 0

        for row in rows {
            guard let cveID = row.cveID, KEVEntry.isWellFormedCVE(cveID) else {
                skipped += 1
                continue
            }
            entries.append(KEVEntry(
                cveID: cveID,
                vendorProject: row.vendorProject ?? "Unknown vendor",
                product: row.product ?? "Unknown product",
                name: row.vulnerabilityName ?? cveID,
                shortDescription: row.shortDescription ?? "",
                requiredAction: row.requiredAction ?? "",
                dateAdded: day(row.dateAdded),
                dueDate: day(row.dueDate),
                // Anything other than an explicit "Known" is treated as
                // unknown, never as a confirmed negative.
                ransomware: row.knownRansomwareCampaignUse == "Known" ? .known : .unknown,
                cwes: row.cwes ?? []
            ))
        }

        return KEVCatalogue(
            version: env.catalogVersion ?? "unknown",
            released: iso(env.dateReleased),
            entries: entries,
            skipped: skipped
        )
    }

    /// `yyyy-MM-dd`, as CISA writes dateAdded and dueDate. An unparsable date
    /// is nil, never today — a wrong due date is worse than an absent one.
    static func day(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        return day(s)
    }
}
