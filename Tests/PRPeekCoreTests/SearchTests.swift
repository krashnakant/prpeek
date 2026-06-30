import XCTest
@testable import PRPeekCore

final class SearchTests: XCTestCase {
    override func tearDown() { URLProtocolStub.handler = nil; super.tearDown() }

    func test_query_contains_involves_me_and_repo_filters() {
        let path = SearchService.searchPath(filters: ["me/a", "org/b"])
        // percent-encoded, so check the decoded query
        let comps = URLComponents(string: "https://x.com" + path.replacingOccurrences(of: "/search/issues", with: ""))!
        let q = comps.queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(q, "is:pr is:open archived:false involves:@me repo:me/a repo:org/b")
        XCTAssertTrue(path.contains("per_page=100"))
    }

    func test_maps_search_items_to_pull_requests() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.contains("/search/issues"))
            let body = #"""
            {"total_count":1,"incomplete_results":false,"items":[
              {"number":7,"title":"Add cache","html_url":"https://github.com/me/repo/pull/7",
               "node_id":"PR_node","draft":false,"user":{"login":"alice"},
               "repository_url":"https://api.github.com/repos/me/repo","updated_at":"2026-06-01T10:00:00Z"}
            ]}
            """#
            return (httpResponse(url: req.url!, status: 200), Data(body.utf8))
        }
        let client = GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t")
        let prs = try await SearchService(client: client).openPRsInvolvingMe()
        XCTAssertEqual(prs.count, 1)
        let pr = prs[0]
        XCTAssertEqual(pr.id, "PR_node")
        XCTAssertEqual(pr.repoFullName, "me/repo")
        XCTAssertEqual(pr.author, "alice")
        XCTAssertEqual(pr.number, 7)
        XCTAssertFalse(pr.isDraft)
    }

    func test_team_review_requested_query_unions_and_dedupes() async throws {
        // involves:@me returns PR 1; the team query returns PR 1 (dupe) + PR 2.
        // Result must contain both, exactly once, newest-first.
        @Sendable func item(_ n: Int, node: String, updated: String) -> String {
            #"{"number":\#(n),"title":"t","html_url":"https://github.com/o/r/pull/\#(n)","node_id":"\#(node)","draft":false,"user":{"login":"u"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"\#(updated)"}"#
        }
        URLProtocolStub.handler = { req in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            if q.contains("team-review-requested:org/eng") {
                XCTAssertFalse(q.contains("involves:@me"))
                return (httpResponse(url: req.url!, status: 200),
                        Data(#"{"items":[\#(item(1, node: "N1", updated: "2026-06-01T10:00:00Z")),\#(item(2, node: "N2", updated: "2026-06-02T10:00:00Z"))]}"#.utf8))
            }
            XCTAssertTrue(q.contains("involves:@me"))
            return (httpResponse(url: req.url!, status: 200),
                    Data(#"{"items":[\#(item(1, node: "N1", updated: "2026-06-01T10:00:00Z"))]}"#.utf8))
        }
        let client = GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t")
        let prs = try await SearchService(client: client).openPRsInvolvingMe(teamKeys: ["org/eng"])
        XCTAssertEqual(prs.map(\.id), ["N2", "N1"], "union, deduped, newest-first")
    }

    func test_paginates_and_caps_at_maxItems() async throws {
        // page 1 -> Link next; each page has 2 items. Cap at 3 => stop early.
        let page2 = "https://api.github.com/search/issues?q=x&page=2"
        @Sendable func item(_ n: Int) -> String {
            #"{"number":\#(n),"title":"t","html_url":"https://github.com/o/r/pull/\#(n)","node_id":"N\#(n)","draft":false,"user":{"login":"u"},"repository_url":"https://api.github.com/repos/o/r","updated_at":"2026-06-01T10:00:00Z"}"#
        }
        URLProtocolStub.handler = { req in
            if req.url!.absoluteString.contains("page=2") {
                return (httpResponse(url: req.url!, status: 200),
                        Data(#"{"items":[\#(item(3)),\#(item(4))]}"#.utf8))
            }
            return (httpResponse(url: req.url!, status: 200, headers: ["Link": "<\(page2)>; rel=\"next\""]),
                    Data(#"{"items":[\#(item(1)),\#(item(2))]}"#.utf8))
        }
        let client = GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t")
        let prs = try await SearchService(client: client).openPRsInvolvingMe(maxItems: 3)
        XCTAssertEqual(prs.count, 3, "must cap at maxItems across pages")
        XCTAssertEqual(prs.map(\.number), [1, 2, 3])
    }
}
