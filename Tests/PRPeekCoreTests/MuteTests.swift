import XCTest
@testable import PRPeekCore

final class MuteTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func pr(updatedAt: Date, account: String = "") -> PullRequest {
        PullRequest(id: "N1", number: 1, repoFullName: "o/r", title: "t",
                    htmlURL: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: false, author: "me", updatedAt: updatedAt, accountID: account)
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

    func test_state_isMuted_keys_on_account_scoped_key() {
        var s = PRPeekState()
        let p = pr(updatedAt: t0)
        XCTAssertFalse(s.isMuted(p, now: t0))
        // The bare node_id is NOT the key any more — two hosts can mint the same
        // one, and a mute on one account would silence the other's PR.
        s.mutes["N1"] = Mute(updatedAtSnapshot: t0, until: nil)
        XCTAssertFalse(s.isMuted(p, now: t0))
        s.mutes[p.key] = Mute(updatedAtSnapshot: t0, until: nil)
        XCTAssertTrue(s.isMuted(p, now: t0))
    }

    /// Upgrading from the single-account build must keep the user's mutes: the
    /// cache has bare-id keys and no accountID, and migration rewrites both.
    func test_migrate_rekeys_mutes_and_stamps_prs() {
        var s = PRPeekState(schemaVersion: 1, pullRequests: [pr(updatedAt: t0)],
                            mutes: ["N1": Mute(updatedAtSnapshot: t0, until: nil)])
        let primary = Account(id: Account.primaryID, label: "GitHub")
        s.migrate(adopting: primary)
        XCTAssertEqual(s.accounts.map(\.id), [Account.primaryID])
        XCTAssertEqual(s.pullRequests.first?.accountID, Account.primaryID)
        XCTAssertTrue(s.isMuted(s.pullRequests[0], now: t0), "the mute survived the re-key")
        XCTAssertEqual(s.schemaVersion, PRPeekState.currentSchema)
        // Idempotent: running it again must not double-prefix the key.
        s.migrate(adopting: primary)
        XCTAssertTrue(s.isMuted(s.pullRequests[0], now: t0))
    }

    /// A fresh install is already at the current schema, so migration must not
    /// run — seeding a token-less account there would leave a permanent dead
    /// session and put an account tag on every row for a single-account user.
    func test_migrate_skips_a_fresh_install() {
        var s = PRPeekState.empty
        s.migrate(adopting: Account(id: Account.primaryID, label: "GitHub"))
        XCTAssertTrue(s.accounts.isEmpty)
    }

    /// Same trap after signing out of everything: accounts are legitimately
    /// empty, and a content sniff would re-adopt a phantom on every launch.
    func test_migrate_skips_an_emptied_state() {
        var s = PRPeekState(pullRequests: [], accounts: [])
        s.migrate(adopting: Account(id: Account.primaryID, label: "GitHub"))
        XCTAssertTrue(s.accounts.isEmpty)
    }

    func test_forget_account_drops_its_rows_and_every_keyed_map() {
        let mine = pr(updatedAt: t0, account: "acct")
        var s = PRPeekState(pullRequests: [mine],
                            mutes: [mine.key: Mute(updatedAtSnapshot: t0, until: nil)],
                            accounts: [Account(id: "acct", label: "A"), Account(id: "other", label: "B")],
                            seen: [mine.key: t0, "other:N9": t0],
                            waitingSince: [mine.key: t0])
        s.forget(account: "acct")
        XCTAssertTrue(s.pullRequests.isEmpty)
        XCTAssertTrue(s.mutes.isEmpty)
        XCTAssertTrue(s.waitingSince.isEmpty)
        XCTAssertEqual(s.accounts.map(\.id), ["other"])
        XCTAssertEqual(Array(s.seen.keys), ["other:N9"], "another account's rows are untouched")
    }

    // Old caches (no `mutes` key) still decode — additive, no schema bump.
    func test_decodes_state_without_mutes_key() throws {
        let json = #"{"schemaVersion":1,"filters":[],"pullRequests":[]}"#
        let s = try JSONDecoder.github.decode(PRPeekState.self, from: Data(json.utf8))
        XCTAssertEqual(s.mutes, [:])
    }
}
