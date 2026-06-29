import XCTest
@testable import PRPeekCore

final class CommitsTests: XCTestCase {

    override func tearDown() { URLProtocolStub.handler = nil; super.tearDown() }

    func test_toCommit_first_line_shortSHA_and_author_fallback() {
        let dto = CommitDTO(
            sha: "abcdef1234567890",
            htmlURL: URL(string: "https://gh/c/abcdef1"),
            commit: .init(message: "Fix retry loop\n\nLong body here", author: .init(name: "Git Name", date: Date(timeIntervalSince1970: 10))),
            author: nil)   // no linked GitHub account -> fall back to git author name
        let c = dto.toCommit(ci: .failing)
        XCTAssertEqual(c.message, "Fix retry loop", "first line only")
        XCTAssertEqual(c.shortSHA, "abcdef1")
        XCTAssertEqual(c.author, "Git Name")
        XCTAssertEqual(c.ciState, .failing)
    }

    func test_commits_keeps_newest_cap_and_attaches_ci() async throws {
        // 3 commits (oldest->newest c1,c2,c3); each SHA's check-runs -> CI.
        URLProtocolStub.handler = { req in
            let url = req.url!.absoluteString
            if url.contains("/pulls/5/commits") {
                let body = """
                [{"sha":"a1aaaaa0","html_url":"https://gh/a1","commit":{"message":"first","author":{"name":"x","date":"2026-01-01T00:00:00Z"}},"author":{"login":"alice"}},
                 {"sha":"b2bbbbb0","html_url":"https://gh/b2","commit":{"message":"second","author":{"name":"x","date":"2026-01-02T00:00:00Z"}},"author":{"login":"bob"}},
                 {"sha":"c3ccccc0","html_url":"https://gh/c3","commit":{"message":"third","author":{"name":"x","date":"2026-01-03T00:00:00Z"}},"author":{"login":"carol"}}]
                """
                return (httpResponse(url: req.url!, status: 200), body.data(using: .utf8)!)
            }
            // check-runs: only b2 is failing, others passing
            let failing = url.contains("b2bbbbb0")
            let concl = failing ? "failure" : "success"
            let body = #"{"check_runs":[{"status":"completed","conclusion":"\#(concl)"}]}"#
            return (httpResponse(url: req.url!, status: 200), body.data(using: .utf8)!)
        }
        let client = GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t")
        let commits = try await client.commits(owner: "acme", repo: "web", number: 5, cap: 2)

        XCTAssertEqual(commits.map(\.shortSHA), ["b2bbbbb", "c3ccccc"], "cap=2 keeps the newest two, in order")
        XCTAssertEqual(commits.map(\.author), ["bob", "carol"])
        XCTAssertEqual(commits[0].ciState, .failing)
        XCTAssertEqual(commits[1].ciState, .passing)
    }
}
