import XCTest
@testable import PRPeekCore

/// URLSession hands `URLProtocol` the body as a stream, not `httpBody`, so a
/// test that wants to see what was posted has to drain it.
private func jsonBody(_ req: URLRequest) -> [String: Any] {
    var data = req.httpBody ?? Data()
    if data.isEmpty, let stream = req.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func comment(id: String) -> ReviewComment {
    ReviewComment(id: id, author: "octocat", verdict: .commented, body: "b",
                  location: nil, createdAt: Date(), htmlURL: nil)
}

final class WritesTests: XCTestCase {

    private func makeClient() -> GitHubClient {
        GitHubClient(transport: URLSessionTransport(session: URLProtocolStub.session()), token: "t0ken")
    }

    override func tearDown() { URLProtocolStub.handler = nil; super.tearDown() }

    func test_merge_puts_sha_and_method() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/repos/o/r/pulls/7/merge")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
            let body = jsonBody(req)
            XCTAssertEqual(body["sha"] as? String, "deadbeef", "merge must be pinned to the head we showed")
            XCTAssertEqual(body["merge_method"] as? String, "squash")
            return (httpResponse(url: req.url!, status: 200), #"{"merged":true}"#.data(using: .utf8)!)
        }
        try await makeClient().merge(owner: "o", repo: "r", number: 7, headSHA: "deadbeef", method: .squash)
    }

    func test_merge_conflict_surfaces_githubs_message() async throws {
        URLProtocolStub.handler = { req in
            (httpResponse(url: req.url!, status: 409),
             #"{"message":"Head branch was modified. Review and try the merge again."}"#.data(using: .utf8)!)
        }
        do {
            try await makeClient().merge(owner: "o", repo: "r", number: 7, headSHA: "stale")
            XCTFail("a moved head must not merge")
        } catch GitHubError.rejected(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "Head branch was modified. Review and try the merge again.")
        }
    }

    /// GitHub hides writes you lack permission for behind a 404 — a read-only
    /// token must land on `.forbidden` (the "your token can't write" message),
    /// not on a confusing not-found.
    func test_write_404_maps_to_forbidden() async throws {
        URLProtocolStub.handler = { req in
            (httpResponse(url: req.url!, status: 404), #"{"message":"Not Found"}"#.data(using: .utf8)!)
        }
        do {
            try await makeClient().requestReview(owner: "o", repo: "r", number: 1, reviewers: ["alice"])
            XCTFail("must not report success")
        } catch {
            XCTAssertEqual(error as? GitHubError, .forbidden)
        }
    }

    func test_requestReview_posts_reviewers() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/repos/o/r/pulls/3/requested_reviewers")
            XCTAssertEqual(jsonBody(req)["reviewers"] as? [String], ["alice"])
            return (httpResponse(url: req.url!, status: 201), Data("{}".utf8))
        }
        try await makeClient().requestReview(owner: "o", repo: "r", number: 3, reviewers: ["alice"])
    }

    func test_requestReview_with_nobody_sends_nothing() async throws {
        URLProtocolStub.handler = { _ in
            XCTFail("empty reviewer list must not hit the network")
            throw GitHubError.invalidResponse
        }
        try await makeClient().requestReview(owner: "o", repo: "r", number: 3, reviewers: [])
    }

    func test_reply_to_inline_comment_threads() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/repos/o/r/pulls/9/comments/4242/replies")
            XCTAssertEqual(jsonBody(req)["body"] as? String, "fixed")
            return (httpResponse(url: req.url!, status: 201), Data("{}".utf8))
        }
        try await makeClient().reply(owner: "o", repo: "r", number: 9, to: comment(id: "c4242"), body: "fixed")
    }

    /// A review has no reply endpoint, so its reply has to land as a top-level
    /// PR comment — the issues path, because a PR is an issue.
    func test_reply_to_review_falls_back_to_issue_comment() async throws {
        URLProtocolStub.handler = { req in
            XCTAssertEqual(req.url?.path, "/repos/o/r/issues/9/comments")
            return (httpResponse(url: req.url!, status: 201), Data("{}".utf8))
        }
        try await makeClient().reply(owner: "o", repo: "r", number: 9, to: comment(id: "r77"), body: "thanks")
    }

    func test_inlineCommentID_only_for_inline_comments() {
        XCTAssertEqual(comment(id: "c4242").inlineCommentID, 4242)
        XCTAssertNil(comment(id: "r77").inlineCommentID, "a review can't be replied to in-thread")
    }
}
