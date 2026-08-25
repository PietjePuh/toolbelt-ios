import Foundation

/// The gateway, running **on this device**.
///
/// In the desktop Toolbelt this is a server on the LAN. Here it is a type — the
/// same idea (one place that owns outbound requests, timeouts, and how failures
/// are described) with no server, no account, and nothing leaving the device
/// except the request itself, to the provider it belongs to.
///
/// Why this can exist at all: a browser cannot make arbitrary cross-origin
/// requests — CORS forbids it, which is why the domain scanner works in the
/// desktop *extension* (host permissions) but could never work in a web app.
/// `URLSession` is not subject to CORS. That single fact is why this app is
/// native.
public actor Gateway {

    public enum Failure: Error, Equatable {
        /// The request never completed. Distinguished from every other case
        /// because "we could not ask" must never be rendered as an answer.
        case unreachable(String)
        /// Reached the host; it said no.
        case http(status: Int)
        /// Reached the host; the body was not what the caller expected.
        case malformed(String)
        /// Refused before leaving the device.
        case refused(String)

        public var isAnswer: Bool {
            // Only `http` represents the remote actually responding. The others
            // mean the question went unanswered, which callers must be able to
            // tell apart when deciding what to show.
            if case .http = self { return true }
            return false
        }
    }

    /// Everything the caller can vary. Deliberately small.
    public struct Request: Sendable {
        public var url: URL
        public var method: String
        public var headers: [String: String]
        public var body: Data?
        /// A phone off-network does not get a refusal — packets go nowhere and
        /// the request hangs. Every request is bounded so the UI can say "not
        /// connected" instead of spinning forever.
        public var timeout: TimeInterval

        public init(
            url: URL,
            method: String = "GET",
            headers: [String: String] = [:],
            body: Data? = nil,
            timeout: TimeInterval = 12
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.timeout = timeout
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession? = nil, userAgent: String = "Toolbelt-iOS") {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            // Ephemeral: no shared cookie jar, no on-disk cache. A scan of one
            // host must not carry credentials picked up from another, and
            // nothing about where the user looked should persist by default.
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
        self.userAgent = userAgent
    }

    /// Perform a request. Throws `Failure`, never a bare `URLError`, so callers
    /// cannot accidentally treat "offline" and "404" the same way.
    public func send(_ request: Request) async throws -> Response {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" else {
            // Enforced here rather than at each call site. iOS ATS would block
            // it anyway; failing early gives a message that says why.
            throw Failure.refused("only https is allowed — got \(request.url.scheme ?? "no scheme")")
        }

        var req = URLRequest(url: request.url, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.malformed("non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let key = k as? String, let value = v as? String {
                    headers[key.lowercased()] = value
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await DiagnosticLog.shared.log(
                (200..<400).contains(http.statusCode) ? .info : .warning,
                "http",
                "\(request.method) \(request.url.absoluteString) → \(http.statusCode), \(data.count)B in \(ms)ms"
            )
            return Response(status: http.statusCode, headers: headers, body: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            // URLError.cancelled also lands here on timeout. All of these mean
            // the same thing to a caller: no answer was obtained.
            //
            // Logged with the tailnet hint attached, because "no answer" from a
            // 100.x address usually means the VPN is down rather than the host.
            let hint = request.url.host.flatMap { TailnetHost.timeoutHint(for: $0) }
            await DiagnosticLog.shared.error(
                "http",
                "\(request.method) \(request.url.absoluteString) → no answer: \(error.localizedDescription)"
                    + (hint.map { " — \($0)" } ?? "")
            )
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    /// Convenience for JSON APIs.
    public func json<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        let res = try await send(request)
        guard (200..<300).contains(res.status) else {
            throw Failure.http(status: res.status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: res.body)
        } catch {
            throw Failure.malformed("could not decode \(T.self): \(error.localizedDescription)")
        }
    }
}
