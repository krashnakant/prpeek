import XCTest
@testable import PRPeekCore

final class NotificationPlannerTests: XCTestCase {
    private func pr(_ id: String, author: String, waiting: Bool, ci: CIState = .none, number: Int = 1) -> PullRequest {
        PullRequest(id: id, number: number, repoFullName: "o/r", title: "t",
                    htmlURL: URL(string: "https://github.com/o/r/pull/\(number)")!,
                    isDraft: false, author: author, ciState: ci, waitingOnMe: waiting,
                    updatedAt: Date(timeIntervalSince1970: 0))
    }

    func test_new_review_request_fires_once() {
        let curr = [pr("A", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: [], current: curr, viewerLogin: "me")
        XCTAssertEqual(events.map(\.kind), [.reviewRequested])
    }

    func test_persistent_waiting_does_not_refire() {
        let prev = [pr("A", author: "other", waiting: true)]
        let curr = [pr("A", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: prev, current: curr, viewerLogin: "me")
        XCTAssertTrue(events.isEmpty, "no edge -> no re-notify (dedup)")
    }

    func test_ci_failure_edge_fires_then_silent() {
        let prevPass = [pr("B", author: "me", waiting: true, ci: .passing)]
        let nowFail = [pr("B", author: "me", waiting: true, ci: .failing)]
        let first = NotificationPlanner.events(previous: prevPass, current: nowFail, viewerLogin: "me")
        XCTAssertEqual(first.map(\.kind), [.ciFailed])
        // stays failing -> no repeat
        let second = NotificationPlanner.events(previous: nowFail, current: nowFail, viewerLogin: "me")
        XCTAssertTrue(second.isEmpty)
    }

    func test_my_own_pr_does_not_trigger_review_request() {
        // author == viewer, waiting due to CI — must NOT be a reviewRequested event
        let curr = [pr("C", author: "me", waiting: true, ci: .failing)]
        let events = NotificationPlanner.events(previous: [], current: curr, viewerLogin: "me")
        XCTAssertEqual(events.map(\.kind), [.ciFailed])
    }

    func test_dedup_within_single_pass() {
        // same PR id twice (shouldn't happen, but planner must not double-fire)
        let curr = [pr("D", author: "other", waiting: true), pr("D", author: "other", waiting: true)]
        let events = NotificationPlanner.events(previous: [], current: curr, viewerLogin: "me")
        XCTAssertEqual(events.count, 1)
    }

    // A "hide until updated" mute that cleared (PR changed) re-notifies once.
    private func waitingPR(updatedAt: Date) -> PullRequest {
        var p = pr("E", author: "other", waiting: true)
        p.waitReason = .reviewRequested
        return PullRequest(id: p.id, number: p.number, repoFullName: p.repoFullName, title: p.title,
                           htmlURL: p.htmlURL, isDraft: false, author: p.author,
                           ciState: .none, waitingOnMe: true, waitReason: .reviewRequested, updatedAt: updatedAt)
    }
    func test_resurfaced_mute_fires_when_pr_updates() {
        let snap = Date(timeIntervalSince1970: 100)
        let mutes = ["E": Mute(updatedAtSnapshot: snap, until: nil)]
        // PR unchanged -> still muted -> nothing.
        XCTAssertTrue(NotificationPlanner.resurfacedMutes(
            current: [waitingPR(updatedAt: snap)], mutes: mutes, now: snap).isEmpty)
        // PR updated past the snapshot -> mute cleared -> one event.
        let out = NotificationPlanner.resurfacedMutes(
            current: [waitingPR(updatedAt: snap.addingTimeInterval(1))], mutes: mutes, now: snap)
        XCTAssertEqual(out.map(\.kind), [.reviewRequested])
    }
}
