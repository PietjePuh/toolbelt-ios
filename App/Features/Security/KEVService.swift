import Foundation

/// Fetches CISA's Known Exploited Vulnerabilities catalogue.
///
/// Keyless and authoritative: CISA publishes it as plain JSON over https with
/// no account, which is exactly the right shape for an app that refuses to ship
/// credentials.
public struct KEVService: Sendable {

    public static let catalogueURL = URL(
        string: "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
    )!

    public enum ServiceError: Error, Equatable {
        case unreachable(String)
        case http(status: Int)
        case notTheCatalogue
        case tooLarge

        public var summary: String {
            switch self {
            case .unreachable:      return "Could not reach CISA"
            case .http(let status): return "CISA answered with \(status)"
            case .notTheCatalogue:  return "That response was not the KEV catalogue"
            case .tooLarge:         return "The catalogue is too large to read"
            }
        }

        public var detail: String {
            switch self {
            case .unreachable(let why): return why
            case .http:
                return "This is CISA's end, not your setup. The list below, if any, is the last one that loaded."
            case .notTheCatalogue:
                return "The address responded, but with something other than the catalogue — often a captive portal on public Wi-Fi."
            case .tooLarge:
                return "The published catalogue exceeded the size limit this app will read into memory."
            }
        }
    }

    private let gateway: Gateway

    public init(gateway: Gateway = Gateway()) { self.gateway = gateway }

    public func fetch() async throws -> KEVCatalogue {
        let response: Gateway.Response
        do {
            response = try await gateway.send(.init(
                url: Self.catalogueURL,
                headers: ["Accept": "application/json"],
                timeout: 30
            ))
        } catch let f as Gateway.Failure {
            switch f {
            case .unreachable(let why), .refused(let why), .malformed(let why):
                throw ServiceError.unreachable(why)
            case .http(let status):
                throw ServiceError.http(status: status)
            }
        }

        guard (200..<300).contains(response.status) else {
            throw ServiceError.http(status: response.status)
        }

        do {
            return try KEVCatalogue.parse(response.body)
        } catch KEVParseError.tooLarge {
            throw ServiceError.tooLarge
        } catch {
            throw ServiceError.notTheCatalogue
        }
    }
}
