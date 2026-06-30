import XCTest
@testable import PRPeekCore

final class ClassifierTests: XCTestCase {
    let me = ViewerContext(login: "me", teamKeys: ["org/reviewers"])

    private func signal(reviewers: [String] = [], teams: [String] = []) -> ReviewSignal {
        ReviewSignal(requestedReviewerLogins: reviewers, requestedTeamKeys: teams)
    }

    func test_draft_is_never_waiting() {
        XCTAssertNil(Classifier.waitReason(isDraft: true, author: "x", ci: .failing,
                                           signal: signal(reviewers: ["me"]), viewer: me))
    }

    func test_requested_reviewer_is_waiting() {
        XCTAssertNotNil(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
                                              signal: signal(reviewers: ["me"]), viewer: me))
    }

    func test_member_of_requested_team_is_waiting() {
        XCTAssertNotNil(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
                                              signal: signal(teams: ["org/reviewers"]), viewer: me))
    }

    func test_not_member_of_requested_team_is_not_waiting() {
        XCTAssertNil(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
                                           signal: signal(teams: ["org/other"]), viewer: me))
    }

    func test_author_with_failing_ci_is_waiting() {
        XCTAssertNotNil(Classifier.waitReason(isDraft: false, author: "me", ci: .failing,
                                              signal: signal(), viewer: me))
    }

    func test_author_with_passing_ci_is_not_waiting() {
        XCTAssertNil(Classifier.waitReason(isDraft: false, author: "me", ci: .passing,
                                           signal: signal(), viewer: me))
    }

    func test_unrelated_pr_is_not_waiting() {
        XCTAssertNil(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
                                           signal: signal(reviewers: ["someoneelse"]), viewer: me))
    }

    // waitReason maps each waiting branch to its reason, priority-ordered.
    func test_waitReason_reviewer_beats_team() {
        XCTAssertEqual(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
            signal: signal(reviewers: ["me"], teams: ["org/reviewers"]), viewer: me), .reviewRequested)
    }
    func test_waitReason_team() {
        XCTAssertEqual(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
            signal: signal(teams: ["org/reviewers"]), viewer: me), .teamReview)
    }
    func test_waitReason_ci_failing() {
        XCTAssertEqual(Classifier.waitReason(isDraft: false, author: "me", ci: .failing,
            signal: signal(), viewer: me), .ciFailing)
    }
    func test_waitReason_nil_when_not_waiting() {
        XCTAssertNil(Classifier.waitReason(isDraft: false, author: "x", ci: .passing,
            signal: signal(), viewer: me))
    }

    // CI rollup
    func test_ci_empty_is_none() {
        XCTAssertEqual(Classifier.ciState(from: []), .none)
    }
    func test_ci_any_failure_is_failing() {
        let runs = [CheckRun(status: "completed", conclusion: "success"),
                    CheckRun(status: "completed", conclusion: "failure")]
        XCTAssertEqual(Classifier.ciState(from: runs), .failing)
    }
    func test_ci_incomplete_is_pending() {
        let runs = [CheckRun(status: "completed", conclusion: "success"),
                    CheckRun(status: "in_progress", conclusion: nil)]
        XCTAssertEqual(Classifier.ciState(from: runs), .pending)
    }
    func test_ci_neutral_and_skipped_count_as_passing() {
        let runs = [CheckRun(status: "completed", conclusion: "neutral"),
                    CheckRun(status: "completed", conclusion: "skipped"),
                    CheckRun(status: "completed", conclusion: "success")]
        XCTAssertEqual(Classifier.ciState(from: runs), .passing)
    }

    // client fetch + map
    func test_ciState_fetch_maps_failing() async throws {
        let body = #"{"check_runs":[{"status":"completed","conclusion":"timed_out"}]}"#
        let client = GitHubClient(transport: FakeTransport([(200, Data(body.utf8))]), token: "t")
        let state = try await client.ciState(owner: "o", repo: "r", sha: "abc")
        XCTAssertEqual(state, .failing)
    }

    func test_pullDetail_parses_reviewers_and_teams() async throws {
        let body = #"{"draft":false,"head":{"sha":"deadbeef"},"requested_reviewers":[{"login":"me"}],"requested_teams":[{"slug":"reviewers"}]}"#
        let client = GitHubClient(transport: FakeTransport([(200, Data(body.utf8))]), token: "t")
        let d = try await client.pullDetail(owner: "o", repo: "r", number: 1)
        XCTAssertEqual(d.headSHA, "deadbeef")
        XCTAssertEqual(d.requestedReviewers, ["me"])
        XCTAssertEqual(d.requestedTeamSlugs, ["reviewers"])
    }
}
