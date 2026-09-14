import XCTest
@testable import PRPeekCore

final class FreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func pr(waiting: Bool = true, round: ReviewRound? = .first,
                    updatedAt: Date? = nil) -> PullRequest {
        PullRequest(id: "N1", number: 1, repoFullName: "o/r", title: "t",
                    htmlURL: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: false, author: "other", waitingOnMe: waiting,
                    updatedAt: updatedAt ?? now, accountID: "acct", reviewRound: round)
    }

    func test_not_waiting_has_no_freshness() {
        XCTAssertNil(Freshness.state(for: pr(waiting: false), seen: nil, waitingSince: nil, now: now))
    }

    func test_never_opened_is_new() {
        XCTAssertEqual(Freshness.state(for: pr(), seen: nil, waitingSince: now, now: now), .new)
    }

    func test_opened_and_recent_is_seen() {
        XCTAssertEqual(Freshness.state(for: pr(), seen: now, waitingSince: now, now: now), .seen)
    }

    func test_waiting_past_the_window_is_stale() {
        let old = now.addingTimeInterval(-Freshness.staleAfter - 1)
        XCTAssertEqual(Freshness.state(for: pr(), seen: now, waitingSince: old, now: now), .stale)
    }

    func test_re_review_outranks_new_and_stale() {
        let old = now.addingTimeInterval(-Freshness.staleAfter - 1)
        XCTAssertEqual(Freshness.state(for: pr(round: .again), seen: nil, waitingSince: old, now: now),
                       .reReview, "being asked again is the most urgent thing we can say")
    }

    func test_waiting_clock_starts_once_and_does_not_restart() {
        let started = now.addingTimeInterval(-500)
        let first = Freshness.trackWaiting([:], current: [pr()], now: started)
        XCTAssertEqual(first["acct:N1"], started)
        let second = Freshness.trackWaiting(first, current: [pr()], now: now)
        XCTAssertEqual(second["acct:N1"], started, "a PR still waiting keeps its original clock")
    }

    func test_waiting_clock_drops_prs_that_stopped_waiting() {
        let tracked = ["acct:N1": now]
        XCTAssertTrue(Freshness.trackWaiting(tracked, current: [pr(waiting: false)], now: now).isEmpty)
        XCTAssertTrue(Freshness.trackWaiting(tracked, current: [], now: now).isEmpty,
                      "a PR that vanished must not leak into the map forever")
    }

    func test_seen_is_forgotten_when_the_pr_moves_on() {
        let lookedAt = now
        let pushed = pr(updatedAt: now.addingTimeInterval(60))
        XCTAssertTrue(Freshness.pruneSeen(["acct:N1": lookedAt], current: [pushed]).isEmpty,
                      "a new commit means what you saw is out of date")
        let untouched = pr(updatedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(Freshness.pruneSeen(["acct:N1": lookedAt], current: [untouched])["acct:N1"], lookedAt)
    }
}
