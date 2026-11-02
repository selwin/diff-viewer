import Foundation

/// Sends one request. Injected so tests never touch the network.
typealias GitHubTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Why a GitHub request failed. The text never contains a token.
enum GitHubAPIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: Date)
    case forbidden
    case notFound
    case http(status: Int)
    case network
    case timedOut
    case incompleteResults
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token."
        case let .rateLimited(retryAfter):
            "GitHub's rate limit was reached. Try again after \(retryAfter.formatted(date: .omitted, time: .shortened))."
        case .forbidden: "GitHub refused the request."
        case .notFound: "GitHub couldn't find the repository, or it is private."
        case let .http(status): "GitHub answered with status \(status)."
        case .network: "Couldn't reach GitHub."
        case .timedOut: "GitHub didn't answer in time."
        case .incompleteResults: "GitHub's answer has too many pages to read in full."
        case .unreadableResponse: "GitHub's answer couldn't be read."
        }
    }
}

/// Remembers when GitHub said to stop. One gate serves every request, so a cooldown from an
/// account check and one from a lookup, in flight together, can't shorten each other.
actor GitHubRateLimitGate {
    static let shared = GitHubRateLimitGate()

    /// Nonisolated so the transport can compute retry dates from the same clock.
    nonisolated let now: @Sendable () -> Date
    private var retryAfter: Date?

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The date requests must wait for, or nil once it has passed.
    func blockedUntil() -> Date? {
        guard let retryAfter, now() < retryAfter else { return nil }
        return retryAfter
    }

    /// Keeps the later of the stored date and `date`, and returns it.
    @discardableResult
    func record(_ date: Date) -> Date {
        let later = max(retryAfter ?? date, date)
        retryAfter = later
        return later
    }
}

/// GitHub's REST API over HTTPS: authentication headers, pagination, rate limits and
/// errors. It knows no endpoints; callers decode the pages themselves.
struct GitHubAPI: Sendable {
    static let maxPages = 10
    private static let defaultCooldown: TimeInterval = 60
    /// Everything outside the unreserved set is escaped, so a literal `+` or `%` in a value
    /// can't be misread by the server.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let transport: GitHubTransport
    let gate: GitHubRateLimitGate

    init(transport: @escaping GitHubTransport = GitHubAPI.urlSessionTransport, gate: GitHubRateLimitGate = .shared) {
        self.transport = transport
        self.gate = gate
    }

    /// One request, for endpoints that return a single object. `path` has its segments
    /// percent-encoded already.
    func get(path: String, query: [(String, String)] = [], token: String?) async throws -> Data {
        try await send(try Self.url(path: path, query: query), token: token).data
    }

    /// Hands each page to `stopWhen`, which returns true once the caller has its answer; no
    /// further page is requested then. Errors `stopWhen` throws propagate unchanged. A `next`
    /// link after the 10-page cap throws rather than passing off a partial answer as complete.
    func forEachPage(
        path: String, query: [(String, String)] = [], token: String?, stopWhen: (Data) throws -> Bool
    ) async throws {
        var url = try Self.url(path: path, query: query)
        for page in 1...Self.maxPages {
            let (data, response) = try await send(url, token: token)
            if try stopWhen(data) { return }
            guard let header = response.value(forHTTPHeaderField: "Link"), let next = try Self.parseNextLink(header)
            else { return }
            // The next URL comes from the response, so it must not lead the token elsewhere.
            guard Self.isAPIOrigin(next) else { throw GitHubAPIError.unreadableResponse }
            if page == Self.maxPages { throw GitHubAPIError.incompleteResults }
            url = next
        }
    }

    /// Only `https://api.github.com`: no other host, port or credentials.
    static func isAPIOrigin(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.github.com" else {
            return false
        }
        return (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    /// The `rel="next"` target of a `Link` header, or nil when it has none. Throws
    /// `.unreadableResponse` when the header is malformed.
    static func parseNextLink(_ header: String) throws -> URL? {
        var next: URL?
        var rest = Substring(header)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.isEmpty { return next }
            guard rest.first == "<", let close = rest.firstIndex(of: ">") else {
                throw GitHubAPIError.unreadableResponse
            }
            let target = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            // Parameters run to the next comma that isn't inside quotes.
            var quoted = false
            var end = rest.endIndex
            for index in rest.indices {
                if rest[index] == "\"" {
                    quoted.toggle()
                } else if rest[index] == "," && !quoted {
                    end = index
                    break
                }
            }
            if quoted { throw GitHubAPIError.unreadableResponse }
            let segment = rest[..<end]
            let trimmed = segment.drop { $0.isWhitespace }
            if !trimmed.isEmpty, !trimmed.hasPrefix(";") { throw GitHubAPIError.unreadableResponse }
            if next == nil, segment.split(separator: ";").contains(where: Self.isNextRelation) {
                guard let url = URL(string: target) else { throw GitHubAPIError.unreadableResponse }
                next = url
            }
            rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
        }
    }

    private static func isNextRelation(_ parameter: Substring) -> Bool {
        let parts = parameter.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else {
            return false
        }
        let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(
            in: CharacterSet(charactersIn: "\""))
        return value.lowercased().split(separator: " ").contains("next")
    }

    private static func url(path: String, query: [(String, String)]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = components.url else { throw GitHubAPIError.unreadableResponse }
        return url
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
    }

    private func send(_ url: URL, token: String?) async throws -> (data: Data, response: HTTPURLResponse) {
        try Task.checkCancellation()
        if let until = await gate.blockedUntil() { throw GitHubAPIError.rateLimited(retryAfter: until) }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DiffViewer", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await transport(request)
        } catch {
            let code = (error as? URLError)?.code
            if Task.isCancelled || code == .cancelled || error is CancellationError { throw CancellationError() }
            throw code == .timedOut ? GitHubAPIError.timedOut : GitHubAPIError.network
        }
        guard let response = urlResponse as? HTTPURLResponse else { throw GitHubAPIError.unreadableResponse }

        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            if let date = Self.retryDate(response, body: data, now: gate.now()) {
                throw GitHubAPIError.rateLimited(retryAfter: await gate.record(date))
            }
            throw GitHubAPIError.forbidden
        case 404:
            throw GitHubAPIError.notFound
        default:
            throw GitHubAPIError.http(status: response.statusCode)
        }
    }

    /// When a rate-limited response says to retry, or nil if it isn't one. GitHub's order:
    /// a positive `retry-after`, else the reset time of an exhausted quota, else a minute
    /// (the secondary limit sends neither). A malformed or expired header counts as absent.
    private static func retryDate(_ response: HTTPURLResponse, body: Data, now: Date) -> Date? {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")?
            .trimmingCharacters(in: .whitespaces)
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
        let exhausted = remaining == "0"
        let limited =
            response.statusCode == 429 || retryAfter != nil || exhausted || bodyMentionsRateLimit(body)
        guard limited else { return nil }

        if let seconds = retryAfter.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
            seconds > 0, seconds.isFinite
        {
            return now.addingTimeInterval(seconds)
        }
        if exhausted, let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap({ Double($0) }),
            reset.isFinite
        {
            let date = Date(timeIntervalSince1970: reset)
            if date > now { return date }
        }
        return now.addingTimeInterval(defaultCooldown)
    }

    private static func bodyMentionsRateLimit(_ body: Data) -> Bool {
        struct Body: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(Body.self, from: body))?.message
        return message?.range(of: "rate limit", options: .caseInsensitive) != nil
    }
}

extension GitHubAPI {
    /// One ephemeral session: no cookies, no cache, nothing shared with other URL loading.
    /// The request timeout is an inactivity limit; the resource timeout caps each HTTP request.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: GitHubRedirectDelegate(), delegateQueue: nil)
    }()

    static let urlSessionTransport: GitHubTransport = { request in
        try await session.data(for: request)
    }
}

/// Follows only redirects that stay on the API origin, so the token never goes elsewhere. GitHub
/// answers a renamed repository with a same-origin 301; any other redirect surfaces as a
/// 3xx status.
final class GitHubRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        GitHubAPI.isAPIOrigin(request.url) ? request : nil
    }
}
