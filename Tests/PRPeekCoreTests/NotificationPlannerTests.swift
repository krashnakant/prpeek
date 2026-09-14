import XCTest
@testable import PRPeekCore

final class NotificationPlannerTests: XCTestCase {
    private func pr(_ id: String, author: String, waiting: Bool, ci: CIState = .none,
                    number: Int = 1, account: String = "acct") -> PullRequest {
        PullRequest(id: id, number: number, repoFullName: "o/r", title: "t",
                    htmlURL: URL(string: "https://github.com/o/r/pull/\(number)")!,
                    isDraft: false, author: author, ciState: ci, waitingOnMe: waiting,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    accountID: account, isMine: author == "me")
    }

    func test_new_review_request_fires_once() {
        let curr = [pr("A", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: [], current: curr)
        XCTAssertEqual(events.map(\.kind), [.reviewRequested])
    }

    func test_persistent_waiting_does_not_refire() {
        let prev = [pr("A", author: "other", waiting: true)]
        let curr = [pr("A", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: prev, current: curr)
        XCTAssertTrue(events.isEmpty, "no edge -> no re-notify (dedup)")
    }

    func test_ci_failure_edge_fires_then_silent() {
        let prevPass = [pr("B", author: "me", waiting: true, ci: .passing)]
        let nowFail = [pr("B", author: "me", waiting: true, ci: .failing)]
        let first = NotificationPlanner.events(previous: prevPass, current: nowFail)
        XCTAssertEqual(first.map(\.kind), [.ciFailed])
        // stays failing -> no repeat
        let second = NotificationPlanner.events(previous: nowFail, current: nowFail)
        XCTAssertTrue(second.isEmpty)
    }

    func test_my_own_pr_does_not_trigger_review_request() {
        // author == viewer, waiting due to CI — must NOT be a reviewRequested event
        let curr = [pr("C", author: "me", waiting: true, ci: .failing)]
        let events = NotificationPlanner.events(previous: [], current: curr)
        XCTAssertEqual(events.map(\.kind), [.ciFailed])
    }

    func test_draft_pr_ci_failure_does_not_notify() {
        let draft = PullRequest(id: "draft1", number: 1, repoFullName: "o/r", title: "t",
                                htmlURL: URL(string: "https://github.com/o/r/pull/1")!,
                                isDraft: true, author: "me", ciState: .failing, waitingOnMe: false,
                                updatedAt: Date(timeIntervalSince1970: 0),
                                accountID: "acct", isMine: true)
        let events = NotificationPlanner.events(previous: [], current: [draft])
        XCTAssertTrue(events.isEmpty, "draft PRs should not alert for CI failure")
    }

    func test_dedup_within_single_pass() {
        // same PR id twice (shouldn't happen, but planner must not double-fire)
        let curr = [pr("D", author: "other", waiting: true), pr("D", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: [], current: curr)
        XCTAssertEqual(events.count, 1)
    }

    func test_same_node_id_on_two_accounts_notifies_separately() {
        // github.com and a GHES host can mint identical node_ids. Keying on the
        // bare id would let one account's notification swallow the other's.
        let curr = [pr("X", author: "other", waiting: true, account: "work"),
                    pr("X", author: "other", waiting: true, account: "personal")]
        let events = NotificationPlanner.events(previous: [], current: curr)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.prKey)), ["work:X", "personal:X"])
    }

    func test_re_review_gets_its_own_title() {
        var again = pr("R", author: "other", waiting: true)
        again.reviewRound = .again
        let events = NotificationPlanner.events(previous: [], current: [again])
        XCTAssertEqual(events.map(\.title), ["Re-review requested"])
    }

    // A "hide until updated" mute that cleared (PR changed) re-notifies once.
    private func waitingPR(updatedAt: Date) -> PullRequest {
        var p = pr("E", author: "other", waiting: true)
        p.waitReason = .reviewRequested
        return PullRequest(id: p.id, number: p.number, repoFullName: p.repoFullName, title: p.title,
                           htmlURL: p.htmlURL, isDraft: false, author: p.author,
                           ciState: .none, waitingOnMe: true, waitReason: .reviewRequested,
                           updatedAt: updatedAt, accountID: p.accountID)
    }
    func test_resurfaced_mute_fires_when_pr_updates() {
        let snap = Date(timeIntervalSince1970: 100)
        let mutes = ["acct:E": Mute(updatedAtSnapshot: snap, until: nil)]
        // PR unchanged -> still muted -> nothing.
        XCTAssertTrue(NotificationPlanner.resurfacedMutes(
            current: [waitingPR(updatedAt: snap)], mutes: mutes, now: snap).isEmpty)
        // PR updated past the snapshot -> mute cleared -> one event.
        let out = NotificationPlanner.resurfacedMutes(
            current: [waitingPR(updatedAt: snap.addingTimeInterval(1))], mutes: mutes, now: snap)
        XCTAssertEqual(out.map(\.kind), [.reviewRequested])
    }
}
