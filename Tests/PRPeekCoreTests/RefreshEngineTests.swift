import XCTest
@testable import PRPeekCore

/// Routes each request to a response by inspecting the URL (handles concurrent
/// calls — unlike the ordered FakeTransport).
final class RouteTransport: Transport, @unchecked Sendable {
    let handler: @Sendable (URLRequest) -> (Int, Data, [String: String])
    init(_ h: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])) { handler = h }
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (s, d, h) = handler(r)
        return (d, HTTPURLResponse(url: r.url!, statusCode: s, httpVersion: "HTTP/1.1", headerFields: h)!)
    }
}

/// Counts max concurrent in-flight calls to assert the cap holds.
final class ConcurrencyProbeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var maxActive = 0
    private var active = 0
    let body: @Sendable (URLRequest) -> (Int, Data)
    init(_ b: @escaping @Sendable (URLRequest) -> (Int, Data)) { body = b }
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { active += 1; maxActive = max(maxActive, active) }
        defer { lock.withLock { active -= 1 } }
        try? await Task.sleep(nanoseconds: 15_000_000)
        let (s, d) = body(r)
        return (d, HTTPURLResponse(url: r.url!, statusCode: s, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func d(_ s: String) -> Data { Data(s.utf8) }

final class RefreshEngineTests: XCTestCase {

    func test_refresh_enriches_and_classifies_via_two_branches() async throws {
        let searchBody = #"""
        {"items":[
          {"number":1,"title":"by other","html_url":"https://github.com/o/r/pull/1","node_id":"N1","draft":false,"user":{"login":"other"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"2026-06-01T10:00:00Z"},
          {"number":2,"title":"mine","html_url":"https://github.com/o/r/pull/2","node_id":"N2","draft":false,"user":{"login":"me"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"2026-06-01T10:00:00Z"}
        ]}
        """#
        let transport = RouteTransport { req in
            let u = req.url!.absoluteString
            func ok(_ s: String) -> (Int, Data, [String: String]) { (200, d(s), [:]) }
            if u.contains("/user/teams") { return ok("[]") }
            if u.contains("/user") { return ok(#"{"login":"me","node_id":"U1"}"#) }
            if u.contains("/search/issues") { return ok(searchBody) }
            if u.contains("/pulls/1") { return ok(#"{"draft":false,"head":{"sha":"s1"},"requested_reviewers":[{"login":"me"}],"requested_teams":[]}"#) }
            if u.contains("/pulls/2") { return ok(#"{"draft":false,"head":{"sha":"s2"},"requested_reviewers":[],"requested_teams":[]}"#) }
            if u.contains("/commits/s1/check-runs") { return ok(#"{"check_runs":[{"status":"completed","conclusion":"success"}]}"#) }
            if u.contains("/commits/s2/check-runs") { return ok(#"{"check_runs":[{"status":"completed","conclusion":"failure"}]}"#) }
            return (404, Data(), [:])
        }
        let client = GitHubClient(transport: transport, token: "t")
        let engine = RefreshEngine(client: client)
        let (viewer, prs) = try await engine.refresh()
        XCTAssertEqual(viewer.login, "me")
        XCTAssertEqual(prs.count, 2)
        let p1 = prs.first { $0.id == "N1" }!
        let p2 = prs.first { $0.id == "N2" }!
        XCTAssertTrue(p1.waitingOnMe, "requested reviewer branch")
        XCTAssertEqual(p1.ciState, .passing)
        XCTAssertTrue(p2.waitingOnMe, "author + failing CI branch")
        XCTAssertEqual(p2.ciState, .failing)
        XCTAssertEqual(p2.headSHA, "s2")
    }

    func test_concurrency_cap_is_respected() async throws {
        // 12 PRs, cap 3. Each PR = detail + check-runs. Max in-flight must stay <= 3.
        let items = (1...12).map { n in
            #"{"number":\#(n),"title":"t","html_url":"https://github.com/o/r/pull/\#(n)","node_id":"N\#(n)","draft":false,"user":{"login":"u"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"2026-06-01T10:00:00Z"}"#
        }.joined(separator: ",")
        let probe = ConcurrencyProbeTransport { req in
            let u = req.url!.absoluteString
            if u.contains("/search/issues") { return (200, d("{\"items\":[\(items)]}")) }
            if u.contains("/pulls/") { return (200, d(#"{"draft":false,"head":{"sha":"sha"},"requested_reviewers":[],"requested_teams":[]}"#)) }
            return (200, d(#"{"check_runs":[]}"#))
        }
        let client = GitHubClient(transport: probe, token: "t")
        let engine = RefreshEngine(client: client, concurrencyLimit: 3)
        let viewer = ViewerContext(login: "u")
        _ = try await engine.refresh(filters: [], viewer: viewer)
        XCTAssertLessThanOrEqual(probe.maxActive, 3, "in-flight requests must respect the cap")
        XCTAssertGreaterThan(probe.maxActive, 1, "should actually run in parallel")
    }

    func test_rateLimited_propagates_from_pass() async throws {
        let searchBody = #"{"items":[{"number":1,"title":"t","html_url":"https://github.com/o/r/pull/1","node_id":"N1","draft":false,"user":{"login":"me"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"2026-06-01T10:00:00Z"}]}"#
        let transport = RouteTransport { req in
            let u = req.url!.absoluteString
            if u.contains("/search/issues") { return (200, d(searchBody), [:]) }
            // secondary limit on the per-PR call
            return (403, Data(), ["X-RateLimit-Remaining": "0", "Retry-After": "30"])
        }
        let client = GitHubClient(transport: transport, token: "t")
        let engine = RefreshEngine(client: client)
        do {
            _ = try await engine.refresh(filters: [], viewer: ViewerContext(login: "me"))
            XCTFail("expected rateLimited to propagate")
        } catch let GitHubError.rateLimited(retryAfter) {
            XCTAssertNotNil(retryAfter)
        }
    }
}
