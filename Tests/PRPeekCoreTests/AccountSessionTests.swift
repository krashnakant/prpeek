import XCTest
@testable import PRPeekCore

/// A store whose read always fails, standing in for a locked Keychain.
private struct LockedTokenStore: TokenStore {
    func read() throws -> String? { throw KeychainTokenStore.KeychainError.locked }
    func save(_ token: String) throws {}
    func delete() throws {}
}

@MainActor
final class AccountSessionTests: XCTestCase {
    private func account(host: String = "") -> Account {
        Account(id: "acct", host: host, label: "Work")
    }

    func test_no_token_reads_as_signed_out() {
        let s = AccountSession(account: account(), tokenStore: InMemoryTokenStore())
        XCTAssertTrue(s.tokenKnown)
        XCTAssertFalse(s.hasToken)
        XCTAssertEqual(s.status, .signedOut(reason: nil))
    }

    func test_existing_token_starts_loading_not_signed_out() {
        let s = AccountSession(account: account(), tokenStore: InMemoryTokenStore("ghp_x"))
        XCTAssertTrue(s.hasToken)
        XCTAssertEqual(s.status, .loading)
    }

    /// A locked Keychain must NOT read as signed out — that would look like the
    /// user's session evaporated, and the refresh loop would stop retrying.
    func test_locked_keychain_is_not_signed_out() {
        let s = AccountSession(account: account(), tokenStore: LockedTokenStore())
        XCTAssertFalse(s.tokenKnown, "still unknown, so the loop keeps retrying")
        XCTAssertEqual(s.status, .loading)
    }

    func test_locked_keychain_retry_reports_failure_until_it_unlocks() async {
        let s = AccountSession(account: account(), tokenStore: LockedTokenStore())
        let resolved = await s.resolveTokenIfNeeded()
        XCTAssertFalse(resolved, "caller must not mistake a locked read for signed out")
        XCTAssertFalse(s.tokenKnown)
    }

    func test_resolving_a_readable_token_caches_it() async {
        let s = AccountSession(account: account(), tokenStore: InMemoryTokenStore("ghp_x"))
        let resolved = await s.resolveTokenIfNeeded()
        XCTAssertTrue(resolved)
        XCTAssertTrue(s.hasToken)
    }

    func test_save_token_updates_session_and_client() async throws {
        let s = AccountSession(account: account(), tokenStore: InMemoryTokenStore())
        XCTAssertFalse(s.hasToken)
        try s.save(token: "ghp_new")
        XCTAssertTrue(s.hasToken)
        XCTAssertTrue(s.tokenKnown)
    }

    func test_sign_out_clears_identity_and_resets_first_pass() {
        let store = InMemoryTokenStore("ghp_x")
        let s = AccountSession(account: account(), tokenStore: store)
        s.viewer = ViewerContext(login: "me")
        s.previousPRs = [PullRequest(id: "N1", number: 1, repoFullName: "o/r", title: "t",
                                     htmlURL: URL(string: "https://x/1")!, isDraft: false,
                                     author: "me", updatedAt: .distantPast)]
        s.firstPass = false

        s.signOut()

        XCTAssertNil(s.viewer)
        XCTAssertTrue(s.previousPRs.isEmpty)
        XCTAssertTrue(s.firstPass, "a re-added account must not fire for every waiting PR")
        XCTAssertFalse(s.hasToken)
        XCTAssertEqual(s.status, .signedOut(reason: nil))
        XCTAssertNil(try? store.read(), "the token is gone from storage, not just from memory")
    }

    /// The same login can exist on github.com and on an enterprise host, so the
    /// host has to be part of what the menu shows.
    func test_display_name_disambiguates_enterprise_hosts() {
        let dotCom = AccountSession(account: account(), tokenStore: InMemoryTokenStore())
        dotCom.viewer = ViewerContext(login: "octocat")
        XCTAssertEqual(dotCom.displayName, "octocat")

        let ghes = AccountSession(account: account(host: "github.acme.com"),
                                  tokenStore: InMemoryTokenStore())
        ghes.viewer = ViewerContext(login: "octocat")
        XCTAssertEqual(ghes.displayName, "octocat @ github.acme.com")
    }

    func test_display_name_falls_back_to_the_typed_label_before_the_viewer_resolves() {
        let s = AccountSession(account: account(), tokenStore: InMemoryTokenStore())
        XCTAssertEqual(s.displayName, "Work")
    }

    /// The first account keeps the pre-multi-account Keychain entry name, so an
    /// upgrading user isn't dropped at a sign-in screen.
    func test_primary_account_keeps_the_legacy_keychain_entry() {
        XCTAssertEqual(Account(id: Account.primaryID, label: "GitHub").keychainAccount, "github-token")
        XCTAssertEqual(Account(id: "abc", label: "Other").keychainAccount, "github-token-abc")
    }
}

final class AppStatusTests: XCTestCase {
    func test_aggregate_surfaces_the_account_that_needs_attention() {
        XCTAssertEqual(AppStatus.aggregate([.loaded, .rateLimited(until: nil), .loading]),
                       .rateLimited(until: nil))
        XCTAssertEqual(AppStatus.aggregate([.loaded, .loaded]), .loaded)
    }

    /// One signed-out account among working ones says nothing worth showing —
    /// the others still have PRs.
    func test_one_signed_out_account_does_not_hide_the_others() {
        XCTAssertEqual(AppStatus.aggregate([.signedOut(reason: nil), .loaded]), .loaded)
        XCTAssertEqual(AppStatus.aggregate([.signedOut(reason: nil), .offline]), .offline)
    }

    func test_all_signed_out_reads_as_signed_out_and_keeps_the_reason() {
        XCTAssertEqual(AppStatus.aggregate([.signedOut(reason: "token revoked")]),
                       .signedOut(reason: "token revoked"))
        XCTAssertEqual(AppStatus.aggregate([]), .signedOut(reason: nil))
    }

    func test_text_is_one_mapping_with_only_loaded_varying() {
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AppStatus.loaded.text(loaded: "All clear"), "All clear")
        XCTAssertEqual(AppStatus.loaded.text(loaded: "Updated now"), "Updated now")
        XCTAssertEqual(AppStatus.offline.text(loaded: "x"), "Offline — showing cached")
        XCTAssertEqual(AppStatus.signedOut(reason: "nope").text(loaded: "x"), "nope")
        XCTAssertEqual(AppStatus.rateLimited(until: at).text(loaded: "x", time: { _ in "3 PM" }),
                       "Rate limited until 3 PM")
        XCTAssertEqual(AppStatus.error("boom").text(loaded: "x", errorLimit: 2), "Error: bo")
    }
}
