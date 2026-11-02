import Foundation
import Synchronization
import Testing

@testable import DiffViewer

/// A clock tests move by hand, so cooldowns never need a real wait.
private final class FakeNow: Sendable {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let offset = Mutex<TimeInterval>(0)

    var date: Date { start.addingTimeInterval(offset.withLock { $0 }) }
    func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
}

/// Answers requests from a script, in order, and records them.
private final class FakeTransport: Sendable {
    enum Reply {
        case http(Int, headers: [String: String] = [:], body: String = "[]")
        case fail(any Error)
        case other(URLResponse)
    }

    private let state: Mutex<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) { state = Mutex((replies, [])) }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    var transport: GitHubTransport { { [self] request in try respond(to: request) } }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        switch reply {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        case let .fail(error): throw error
        case let .other(response): return (Data(), response)
        case nil: throw URLError(.badServerResponse)
        }
    }
}

private struct Probe: Error, Equatable {}

struct GitHubStatusCase: CustomTestStringConvertible {
    var name: String
    var status: Int
    var headers: [String: String] = [:]
    var body = ""
    var expected: @Sendable (Date) -> GitHubAPIError
    var testDescription: String { name }
}

struct GitHubRetryCase: CustomTestStringConvertible {
    var name: String
    var headers: [String: String]
    var body = ""
    var seconds: TimeInterval
    var testDescription: String { name }
}

struct GitHubAPITests {
    private let now = FakeNow()

    private func api(_ fake: FakeTransport) -> GitHubAPI {
        let clock = now
        return GitHubAPI(transport: fake.transport, gate: GitHubRateLimitGate(now: { clock.date }))
    }

    /// Reads one page and stops.
    private func fetchOnce(_ api: GitHubAPI, token: String? = nil) async throws {
        try await api.forEachPage(path: "/repos/o/r/pulls", token: token, stopWhen: { _ in true })
    }

    private func link(_ target: String, rel: String = "next") -> [String: String] {
        ["Link": "<\(target)>; rel=\"\(rel)\""]
    }

    private func nextPage(_ number: Int) -> [String: String] {
        link("https://api.github.com/repos/o/r/pulls?page=\(number)")
    }

    // MARK: Requests

    @Test func sendsHeadersAndOnlyAuthorizesWithAToken() async throws {
        let fake = FakeTransport([.http(200), .http(200)])
        try await fetchOnce(api(fake), token: "secret")
        try await fetchOnce(api(fake))

        let (withToken, anonymous) = (fake.requests[0], fake.requests[1])
        #expect(withToken.httpMethod == "GET")
        #expect(withToken.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(withToken.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(withToken.value(forHTTPHeaderField: "User-Agent") == "DiffViewer")
        #expect(withToken.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func encodesQueryValuesStrictly() async throws {
        let fake = FakeTransport([.http(200)])
        try await api(fake).forEachPage(
            path: "/repos/o/r/pulls", query: [("head", "me:feat/a+b%c d"), ("state", "open")], token: nil,
            stopWhen: { _ in true })

        let url = try #require(fake.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let raw = try #require(components.percentEncodedQuery)
        #expect(components.path == "/repos/o/r/pulls")
        #expect(components.queryItems?.first { $0.name == "head" }?.value == "me:feat/a+b%c d")
        #expect(raw.contains("me%3Afeat%2Fa%2Bb%25c%20d"))
        #expect(!raw.contains("%252B"))
    }

    // MARK: Pagination

    @Test func followsNextLinksUntilThereAreNone() async throws {
        let fake = FakeTransport([
            .http(200, headers: nextPage(2), body: "one"), .http(200, headers: nextPage(3), body: "two"),
            .http(200, body: "three"),
        ])
        var pages: [String] = []
        try await api(fake).forEachPage(path: "/repos/o/r/pulls", token: nil) {
            pages.append(String(decoding: $0, as: UTF8.self))
            return false
        }

        #expect(pages == ["one", "two", "three"])
        #expect(fake.requests.map { $0.url?.query } == [nil, "page=2", "page=3"])
    }

    @Test func stopWhenEndsThePaging() async throws {
        let fake = FakeTransport([.http(200, headers: nextPage(2)), .http(200)])
        try await fetchOnce(api(fake))
        #expect(fake.requests.count == 1)
    }

    @Test func stopWhenErrorsPropagateUnchanged() async {
        let fake = FakeTransport([.http(200, headers: nextPage(2)), .http(200)])
        await #expect(throws: Probe.self) {
            try await api(fake).forEachPage(path: "/repos/o/r/pulls", token: nil) { _ in throw Probe() }
        }
    }

    @Test(arguments: [true, false])
    func theTenthPageEndsTheSearchOnlyWithoutANextLink(hasNext: Bool) async throws {
        let pages = (1...10).map { FakeTransport.Reply.http(200, headers: $0 < 10 || hasNext ? nextPage($0 + 1) : [:]) }
        let fake = FakeTransport(pages)
        let run = { try await api(fake).forEachPage(path: "/repos/o/r/pulls", token: nil) { _ in false } }

        if hasNext {
            await #expect(throws: GitHubAPIError.incompleteResults) { try await run() }
        } else {
            try await run()
        }
        #expect(fake.requests.count == 10)
    }

    @Test(arguments: [
        "http://api.github.com/repos/o/r/pulls?page=2", "https://evil.example/repos/o/r/pulls?page=2",
        "https://api.github.com.evil.example/x", "https://api.github.com:8443/x",
        "https://user:pass@api.github.com/x", "/repos/o/r/pulls?page=2",
    ])
    func anOffOriginNextLinkMakesNoRequest(target: String) async {
        let fake = FakeTransport([.http(200, headers: link(target)), .http(200)])
        await #expect(throws: GitHubAPIError.unreadableResponse) {
            try await api(fake).forEachPage(path: "/repos/o/r/pulls", token: "secret") { _ in false }
        }
        #expect(fake.requests.count == 1)
    }

    @Test func malformedLinkHeadersAreUnreadable() async {
        for header in [
            "garbage", "<https://api.github.com/x", "<https://api.github.com/x> rel=next", "<a>; rel=\"next",
        ] {
            let fake = FakeTransport([.http(200, headers: ["Link": header])])
            await #expect(throws: GitHubAPIError.unreadableResponse, "\(header)") {
                try await api(fake).forEachPage(path: "/repos/o/r/pulls", token: nil) { _ in false }
            }
        }
    }

    @Test func parsesTheNextRelationAmongOthers() throws {
        let page = "https://api.github.com/repositories/1/pulls?page=2&q=a,b"
        let last = "<https://api.github.com/repositories/1/pulls?page=9>; rel=\"last\""
        #expect(try GitHubAPI.parseNextLink("<\(page)>; rel=\"next\", \(last)")?.absoluteString == page)
        #expect(
            try GitHubAPI.parseNextLink("\(last), <\(page)>; REL=\"prev next\"; title=\"x, y\"")?.absoluteString == page
        )
        #expect(try GitHubAPI.parseNextLink(last) == nil)
        #expect(try GitHubAPI.parseNextLink("") == nil)
    }

    @Test(arguments: [
        ("https://api.github.com/repos/o/r/pulls?page=2", true), ("HTTPS://API.GITHUB.COM/user", true),
        ("https://api.github.com:443/user", true), ("http://api.github.com/user", false),
        ("https://github.com/user", false), ("https://api.github.com:444/user", false),
        ("https://u@api.github.com/user", false), ("https://u:p@api.github.com/user", false),
        ("https://api.github.com.evil.example/user", false), ("file:///etc/hosts", false),
    ])
    func recognizesOnlyTheAPIOrigin(address: String, expected: Bool) throws {
        #expect(GitHubAPI.isAPIOrigin(URL(string: address)) == expected)
    }

    @Test func noURLIsNotTheAPIOrigin() {
        #expect(!GitHubAPI.isAPIOrigin(nil))
    }

    @Test func redirectsStayOnTheAPIOrigin() async throws {
        let delegate = GitHubRedirectDelegate()
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/o/r/pulls")!)
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!, statusCode: 301, httpVersion: nil, headerFields: nil)!

        func follows(_ address: String) async -> Bool {
            await delegate.urlSession(
                .shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: address)!)) != nil
        }
        #expect(await follows("https://api.github.com/repositories/1/pulls"))
        #expect(!(await follows("https://evil.example/pulls")))
        #expect(!(await follows("http://api.github.com/pulls")))
    }

    // MARK: Errors

    @Test(arguments: [
        GitHubStatusCase(name: "401", status: 401, expected: { _ in .unauthorized }),
        GitHubStatusCase(
            name: "403 quota exhausted", status: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000120"],
            expected: { .rateLimited(retryAfter: $0.addingTimeInterval(120)) }),
        GitHubStatusCase(
            name: "403 retry-after", status: 403, headers: ["retry-after": "30"],
            expected: { .rateLimited(retryAfter: $0.addingTimeInterval(30)) }),
        GitHubStatusCase(
            name: "403 secondary limit", status: 403, body: #"{"message":"You have exceeded a Secondary Rate Limit."}"#,
            expected: { .rateLimited(retryAfter: $0.addingTimeInterval(60)) }),
        GitHubStatusCase(
            name: "403 plain", status: 403, body: #"{"message":"Resource not accessible"}"#,
            expected: { _ in .forbidden }),
        GitHubStatusCase(name: "404", status: 404, expected: { _ in .notFound }),
        GitHubStatusCase(name: "429", status: 429, expected: { .rateLimited(retryAfter: $0.addingTimeInterval(60)) }),
        GitHubStatusCase(name: "500", status: 500, expected: { _ in .http(status: 500) }),
        GitHubStatusCase(name: "302", status: 302, expected: { _ in .http(status: 302) }),
    ])
    func mapsStatusesToErrors(_ testCase: GitHubStatusCase) async {
        let fake = FakeTransport([
            .http(testCase.status, headers: testCase.headers, body: testCase.body)
        ])
        await #expect(throws: testCase.expected(now.date)) { try await fetchOnce(api(fake)) }
    }

    @Test func transportFailuresAreMapped() async {
        let cases: [(FakeTransport.Reply, GitHubAPIError)] = [
            (.fail(URLError(.timedOut)), .timedOut), (.fail(URLError(.notConnectedToInternet)), .network),
            (.fail(Probe()), .network), (.other(URLResponse()), .unreadableResponse),
        ]
        for (reply, expected) in cases {
            await #expect(throws: expected) { try await fetchOnce(api(FakeTransport([reply]))) }
        }
    }

    // MARK: Retry dates

    @Test(arguments: [
        GitHubRetryCase(
            name: "retry-after wins",
            headers: ["retry-after": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000500"], seconds: 30
        ),
        GitHubRetryCase(
            name: "reset with no quota", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000500"],
            seconds: 500),
        GitHubRetryCase(
            name: "reset ignored with quota left",
            headers: ["x-ratelimit-remaining": "7", "x-ratelimit-reset": "1800000500"],
            body: #"{"message":"secondary rate limit"}"#, seconds: 60),
        GitHubRetryCase(name: "malformed retry-after", headers: ["retry-after": "soon"], seconds: 60),
        GitHubRetryCase(name: "non-positive retry-after", headers: ["retry-after": "0"], seconds: 60),
        GitHubRetryCase(
            name: "expired reset", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1799999000"],
            seconds: 60),
        GitHubRetryCase(
            name: "malformed reset", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "tomorrow"],
            seconds: 60),
        GitHubRetryCase(
            name: "infinite reset", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "inf"], seconds: 60),
    ])
    func computesTheRetryDate(_ testCase: GitHubRetryCase) async {
        let fake = FakeTransport([.http(403, headers: testCase.headers, body: testCase.body)])
        let expected = GitHubAPIError.rateLimited(retryAfter: now.date.addingTimeInterval(testCase.seconds))
        await #expect(throws: expected) { try await fetchOnce(api(fake)) }
    }

    // MARK: Gate

    @Test func aCooldownBlocksRequestsUntilTheDatePasses() async throws {
        let fake = FakeTransport([.http(429, headers: ["retry-after": "30"]), .http(200)])
        let api = api(fake)
        let until = now.date.addingTimeInterval(30)

        await #expect(throws: GitHubAPIError.rateLimited(retryAfter: until)) { try await fetchOnce(api) }
        now.advance(10)
        await #expect(throws: GitHubAPIError.rateLimited(retryAfter: until)) { try await fetchOnce(api) }
        #expect(fake.requests.count == 1)

        now.advance(21)
        try await fetchOnce(api)
        #expect(fake.requests.count == 2)
    }

    @Test func theGateKeepsTheLaterDate() async {
        let clock = now
        let gate = GitHubRateLimitGate(now: { clock.date })
        let (soon, later, latest) = (
            now.date.addingTimeInterval(50), now.date.addingTimeInterval(100), now.date.addingTimeInterval(200)
        )

        #expect(await gate.blockedUntil() == nil)
        await gate.record(later)
        #expect(await gate.record(soon) == later)
        #expect(await gate.blockedUntil() == later)
        #expect(await gate.record(latest) == latest)
        now.advance(201)
        #expect(await gate.blockedUntil() == nil)
    }

    // MARK: Cancellation

    @Test func cancellingBetweenPagesStopsBeforeTheNextRequest() async {
        let fake = FakeTransport([.http(200, headers: nextPage(2)), .http(200)])
        let api = api(fake)
        // A child task, so cancelling it doesn't cancel the test itself.
        let task = Task {
            try await api.forEachPage(path: "/repos/o/r/pulls", token: nil) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fake.requests.count == 1)
    }

    @Test func cancellingDuringARequestThrowsCancellationError() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let clock = now
        let api = GitHubAPI(
            transport: { _ in
                signal.yield()
                try await Task.sleep(for: .seconds(10))
                throw Probe()
            },
            gate: GitHubRateLimitGate(now: { clock.date }))

        let task = Task { try await fetchOnce(api) }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCancelledURLErrorIsACancellationNotANetworkError() async {
        let fake = FakeTransport([.fail(URLError(.cancelled))])
        await #expect(throws: CancellationError.self) { try await fetchOnce(api(fake)) }
    }
}
