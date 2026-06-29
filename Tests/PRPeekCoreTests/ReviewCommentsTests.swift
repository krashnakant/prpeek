import XCTest
@testable import PRPeekCore

final class ReviewCommentsTests: XCTestCase {

    override func tearDown() { URLProtocolStub.handler = nil; super.tearDown() }

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func test_merge_filters_sorts_and_maps_verdicts() {
        let reviews = [
            ReviewDTO(id: 1, user: .init(login: "octocat"), body: "cap the loop",
                      state: "CHANGES_REQUESTED", submittedAt: date(100), htmlURL: nil),
            ReviewDTO(id: 2, user: .init(login: "bot"), body: "",
                      state: "COMMENTED", submittedAt: date(150), htmlURL: nil),   // empty wrapper -> dropped
            ReviewDTO(id: 3, user: .init(login: "alice"), body: "",
                      state: "APPROVED", submittedAt: date(300), htmlURL: nil),    // empty body OK, verdict matters
            ReviewDTO(id: 4, user: .init(login: "me"), body: "wip",
                      state: "PENDING", submittedAt: date(400), htmlURL: nil),     // own unsubmitted -> dropped
        ]
        let comments = [
            ReviewCommentDTO(id: 11, user: .init(login: "maintainer"), body: "rename n",
                             path: "checkout.ts", line: 51, originalLine: nil, createdAt: date(200), htmlURL: nil),
            ReviewCommentDTO(id: 12, user: .init(login: "carol"), body: "typo",
                             path: "a.swift", line: nil, originalLine: 9, createdAt: date(120), htmlURL: nil),
        ]

        let merged = ReviewThread.merge(reviews: reviews, comments: comments)

        XCTAssertEqual(merged.map(\.id), ["r1", "c12", "c11", "r3"], "chronological; wrappers + pending dropped")
        XCTAssertEqual(merged.map(\.verdict),
                       [.changesRequested, .commented, .commented, .approved])
        XCTAssertNil(merged[0].location, "review-level comment has no file:line")
        XCTAssertEqual(merged[1].location, "a.swift:9", "falls back to original_line")
        XCTAssertEqual(merged[2].location, "checkout.ts:51")
    }

    func test_merge_caps_to_newest() {
        let many = (0..<50).map {
            ReviewCommentDTO(id: $0, user: .init(login: "u"), body: "c\($0)", path: "f", line: 1,
                             originalLine: nil, createdAt: date(TimeInterval($0)), htmlURL: nil)
        }
        let merged = ReviewThread.merge(reviews: [], comments: many, cap: 10)
        XCTAssertEqual(merged.count, 10)
        XCTAssertEqual(merged.first?.id, "c40", "suffix keeps the newest 10")
        XCTAssertEqual(merged.last?.id, "c49")
    }

    func test_reviewThread_decodes_both_endpoints() async throws {
        URLProtocolStub.handler = { req in
            let url = req.url!.absoluteString
            if url.hasSuffix("/reviews") {
                let body = #"[{"id":1,"user":{"login":"octocat"},"body":"cap it","state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T10:00:00Z","html_url":"https://gh/r/1"}]"#
                return (httpResponse(url: req.url!, status: 200), body.data(using: .utf8)!)
            }
            // /comments
            let body = #"[{"id":9,"user":{"login":"maintainer"},"body":"nit","path":"src/x.ts","line":42,"created_at":"2026-01-01T11:00:00Z","html_url":"https://gh/c/9"}]"#
            return (httpResponse(url: req.url!, status: 200), body.data(using: .utf8)!)
        }
        let client = GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t")
        let thread = try await client.reviewThread(owner: "acme", repo: "web", number: 1284)

        XCTAssertEqual(thread.map(\.id), ["r1", "c9"])
        XCTAssertEqual(thread[0].verdict, .changesRequested)
        XCTAssertEqual(thread[1].location, "src/x.ts:42")
        XCTAssertEqual(thread[1].htmlURL?.absoluteString, "https://gh/c/9")
    }
}
