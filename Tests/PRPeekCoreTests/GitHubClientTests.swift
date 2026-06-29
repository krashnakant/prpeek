import XCTest
@testable import PRPeekCore

private struct Probe: Codable, Sendable, Equatable { let login: String }

final class GitHubClientTests: XCTestCase {

    private func makeClient() -> GitHubClient {
        GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t0ken")
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func test_200_decodes_and_sends_auth_and_version_headers() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            let body = #"{"login":"octocat"}"#.data(using: .utf8)!
            return (httpResponse(url: req.url!, status: 200, headers: ["ETag": "abc"]), body)
        }
        let client = makeClient()
        let user: Probe = try await client.getValue(path: "/user")
        XCTAssertEqual(user, Probe(login: "octocat"))
    }

    func test_304_returns_cached_body_and_sends_if_none_match() async throws {
        let client = makeClient()
        // First call: 200 + ETag, populates cache.
        URLProtocolStub.handler = { req in
            (httpResponse(url: req.url!, status: 200, headers: ["ETag": "v1"]),
             #"{"login":"first"}"#.data(using: .utf8)!)
        }
        _ = try await client.getValue(Probe.self, path: "/user")

        // Second call: server sees If-None-Match and answers 304 (no body).
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "v1")
            return (httpResponse(url: req.url!, status: 304), nil)
        }
        let cached: Probe = try await client.getValue(path: "/user")
        XCTAssertEqual(cached, Probe(login: "first"), "304 must return the cached body")
    }

    func test_401_maps_to_unauthorized() async throws {
        URLProtocolStub.handler = { req in (httpResponse(url: req.url!, status: 401), Data()) }
        let client = makeClient()
        await assertThrows(GitHubError.unauthorized) { _ = try await client.getValue(Probe.self, path: "/user") }
    }

    func test_403_with_zero_remaining_maps_to_rateLimited() async throws {
        URLProtocolStub.handler = { req in
            (httpResponse(url: req.url!, status: 403,
                          headers: ["X-RateLimit-Remaining": "0", "Retry-After": "60"]), Data())
        }
        let client = makeClient()
        do {
            _ = try await client.getValue(Probe.self, path: "/search/issues")
            XCTFail("expected rateLimited")
        } catch let GitHubError.rateLimited(retryAfter) {
            XCTAssertNotNil(retryAfter, "Retry-After should produce a date")
        }
    }

    func test_403_without_rate_headers_maps_to_forbidden() async throws {
        URLProtocolStub.handler = { req in (httpResponse(url: req.url!, status: 403), Data()) }
        let client = makeClient()
        await assertThrows(GitHubError.forbidden) { _ = try await client.getValue(Probe.self, path: "/user") }
    }

    func test_5xx_maps_to_server() async throws {
        URLProtocolStub.handler = { req in (httpResponse(url: req.url!, status: 503), Data()) }
        let client = makeClient()
        await assertThrows(GitHubError.server(status: 503)) { _ = try await client.getValue(Probe.self, path: "/user") }
    }

    func test_setToken_clears_etag_cache_on_account_switch() async throws {
        let client = makeClient()
        URLProtocolStub.handler = { req in
            (httpResponse(url: req.url!, status: 200, headers: ["ETag": "v1"]),
             #"{"login":"accountA"}"#.data(using: .utf8)!)
        }
        let a: Probe = try await client.getValue(path: "/user")
        XCTAssertEqual(a.login, "accountA")

        await client.setToken("different-account-token")  // switch account
        URLProtocolStub.handler = { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "If-None-Match"),
                         "token change must flush the cache — no stale conditional request")
            return (httpResponse(url: req.url!, status: 200), #"{"login":"accountB"}"#.data(using: .utf8)!)
        }
        let b: Probe = try await client.getValue(path: "/user")
        XCTAssertEqual(b.login, "accountB", "must fetch fresh for the new account, not reuse cached body")
    }

    func test_pagination_follows_link_next_to_end() async throws {
        let page2 = "https://api.github.com/things?page=2"
        URLProtocolStub.handler = { req in
            if req.url!.absoluteString.contains("page=2") {
                return (httpResponse(url: req.url!, status: 200), #"[{"login":"c"}]"#.data(using: .utf8)!)
            } else {
                return (httpResponse(url: req.url!, status: 200,
                                     headers: ["Link": "<\(page2)>; rel=\"next\""]),
                        #"[{"login":"a"},{"login":"b"}]"#.data(using: .utf8)!)
            }
        }
        let client = makeClient()
        let all: [Probe] = try await client.getCollection(path: "/things")
        XCTAssertEqual(all.map(\.login), ["a", "b", "c"], "must concat all pages")
    }

    /// A conditional refresh of a paginated collection: every page 304s. GitHub
    /// re-sends the `Link` header on a 304, so the loop must read it from the
    /// LIVE 304 response (not the cached page) and still reach page 2 from cache.
    func test_304_refresh_follows_link_from_live_response() async throws {
        let page2 = "https://api.github.com/things?page=2"
        let client = makeClient()
        // Seed cache: page1 (Link -> page2) + page2.
        URLProtocolStub.handler = { req in
            if req.url!.absoluteString.contains("page=2") {
                return (httpResponse(url: req.url!, status: 200, headers: ["ETag": "e2"]),
                        #"[{"login":"c"}]"#.data(using: .utf8)!)
            }
            return (httpResponse(url: req.url!, status: 200,
                                 headers: ["ETag": "e1", "Link": "<\(page2)>; rel=\"next\""]),
                    #"[{"login":"a"},{"login":"b"}]"#.data(using: .utf8)!)
        }
        _ = try await client.getCollection(Probe.self, path: "/things")

        // Refresh: both pages 304; page1's 304 still carries the Link header.
        URLProtocolStub.handler = { req in
            let isPage2 = req.url!.absoluteString.contains("page=2")
            let headers = isPage2 ? [:] : ["Link": "<\(page2)>; rel=\"next\""]
            return (httpResponse(url: req.url!, status: 304, headers: headers), nil)
        }
        let all: [Probe] = try await client.getCollection(path: "/things")
        XCTAssertEqual(all.map(\.login), ["a", "b", "c"], "304 refresh must follow Link from the live response")
    }

    /// Degraded case: a 304 with no `Link` header stops pagination after the
    /// first page (returns its cached body). Guarantee: terminates cleanly —
    /// no crash, no infinite loop, no stale later pages.
    func test_304_without_link_terminates_with_cached_first_page() async throws {
        let page2 = "https://api.github.com/things?page=2"
        let client = makeClient()
        URLProtocolStub.handler = { req in
            if req.url!.absoluteString.contains("page=2") {
                return (httpResponse(url: req.url!, status: 200, headers: ["ETag": "e2"]),
                        #"[{"login":"c"}]"#.data(using: .utf8)!)
            }
            return (httpResponse(url: req.url!, status: 200,
                                 headers: ["ETag": "e1", "Link": "<\(page2)>; rel=\"next\""]),
                    #"[{"login":"a"},{"login":"b"}]"#.data(using: .utf8)!)
        }
        _ = try await client.getCollection(Probe.self, path: "/things")

        URLProtocolStub.handler = { req in (httpResponse(url: req.url!, status: 304), nil) }
        let all: [Probe] = try await client.getCollection(path: "/things")
        XCTAssertEqual(all.map(\.login), ["a", "b"], "no Link on 304 -> stop after page 1")
    }
}

/// Tiny async throws helper (no framework).
func assertThrows<E: Error & Equatable>(_ expected: E, _ body: () async throws -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
    catch let e as E { XCTAssertEqual(e, expected, file: file, line: line) }
    catch { XCTFail("wrong error: \(error)", file: file, line: line) }
}
