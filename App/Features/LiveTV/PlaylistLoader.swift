import Foundation

/// Fetches and parses an M3U playlist, keeping failures distinct.
public struct PlaylistLoader: Sendable {

    public enum LoadError: Error, Equatable {
        case unreachable(String)
        case http(status: Int)
        case notAPlaylist
        case tooLarge

        public var summary: String {
            switch self {
            case .unreachable:      return "Could not reach this playlist"
            case .http(let status): return "The provider answered with \(status)"
            case .notAPlaylist:     return "That address is not a playlist"
            case .tooLarge:         return "This playlist is too large to read"
            }
        }

        public var detail: String {
            switch self {
            case .unreachable(let why): return why
            case .http(let status) where status == 401 || status == 403:
                return "The provider refused the request. Check the username, password or expiry in the URL."
            case .http(let status) where status == 404:
                return "The playlist address has moved or expired."
            case .http:
                return "This is the provider's problem, not your setup."
            case .notAPlaylist:
                return "The address loaded, but did not return an M3U playlist. Providers often serve an error page this way."
            case .tooLarge:
                return "The playlist exceeded the size limit this app will read into memory."
            }
        }
    }

    private let gateway: Gateway

    public init(gateway: Gateway = Gateway()) { self.gateway = gateway }

    public func load(_ url: URL) async throws -> M3UPlaylist {
        let response: Gateway.Response
        do {
            response = try await gateway.send(.init(url: url, timeout: 20))
        } catch let f as Gateway.Failure {
            switch f {
            case .unreachable(let why), .refused(let why): throw LoadError.unreachable(why)
            case .http(let status): throw LoadError.http(status: status)
            case .malformed(let why): throw LoadError.unreachable(why)
            }
        }

        guard (200..<300).contains(response.status) else {
            throw LoadError.http(status: response.status)
        }

        do {
            return try M3UPlaylist.parse(response.body)
        } catch M3UPlaylist.ParseError.tooLarge {
            throw LoadError.tooLarge
        } catch {
            throw LoadError.notAPlaylist
        }
    }
}
