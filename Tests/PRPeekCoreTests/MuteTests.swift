import XCTest
@testable import PRPeekCore

final class MuteTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func pr(updatedAt: Date) -> PullRequest {
        PullRequest(id: "N1", number: 1, repoFullName: "o/r", title: "t",
                    htmlURL: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: false, author: "me", updatedAt: updatedAt)
    }

    // Timed snooze: muted before the deadline, free after.
    func test_timed_snooze_active_then_expires() {
        let m = Mute(updatedAtSnapshot: t0, until: t0.addingTimeInterval(3600))
        XCTAssertTrue(m.active(for: pr(updatedAt: t0), now: t0.addingTimeInterval(1800)))
        XCTAssertFalse(m.active(for: pr(updatedAt: t0), now: t0.addingTimeInterval(3601)))
    }

    // Until-updated: muted while unchanged, auto-unmutes once updatedAt moves.
    func test_until_updated_clears_when_pr_changes() {
        let m = Mute(updatedAtSnapshot: t0, until: nil)
        XCTAssertTrue(m.active(for: pr(updatedAt: t0), now: t0.addingTimeInterval(99_999)))
        XCTAssertFalse(m.active(for: pr(updatedAt: t0.addingTimeInterval(1)), now: t0))
    }

    func test_state_isMuted_keys_on_pr_id() {
        var s = PRPeekState()
        XCTAssertFalse(s.isMuted(pr(updatedAt: t0), now: t0))
        s.mutes["N1"] = Mute(updatedAtSnapshot: t0, until: nil)
        XCTAssertTrue(s.isMuted(pr(updatedAt: t0), now: t0))
    }

    // Old caches (no `mutes` key) still decode — additive, no schema bump.
    func test_decodes_state_without_mutes_key() throws {
        let json = #"{"schemaVersion":1,"filters":[],"pullRequests":[]}"#
        let s = try JSONDecoder.github.decode(PRPeekState.self, from: Data(json.utf8))
        XCTAssertEqual(s.mutes, [:])
    }
}
