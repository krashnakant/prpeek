import Foundation

/// ONE coalesced refresh pass (plan: single coalesced poll, not per-repo timers):
///   search involves:@me  ->  per-PR enrich (detail + check-runs)  ->  classify.
/// The per-PR step fans out under a concurrency cap. A `.rateLimited` thrown from
/// any call propagates so the scheduler (app layer) can pause until retryAfter.
public struct RefreshEngine: Sendable {
    let client: GitHubClient
    let search: SearchService
    public let concurrencyLimit: Int
    /// Stamped onto every PR this engine returns, so a merged multi-account list
    /// can still say which identity each row came from.
    public let accountID: String

    public init(client: GitHubClient, concurrencyLimit: Int = 5,
                accountID: String = Account.primaryID) {
        self.client = client
        self.search = SearchService(client: client)
        self.concurrencyLimit = concurrencyLimit
        self.accountID = accountID
    }

    /// Resolve the viewer once (login + teams), then refresh.
    public func refresh(filters: [String] = [],
                        previous: [PullRequest] = []) async throws -> (viewer: ViewerContext, prs: [PullRequest]) {
        let user = try await client.currentUser()
        let teams = try await client.viewerTeamKeys()
        let viewer = ViewerContext(login: user.login, teamKeys: teams)
        let prs = try await refresh(filters: filters, viewer: viewer, previous: previous)
        return (viewer, prs)
    }

    /// Refresh with a known viewer (lets the app cache identity across passes).
    /// `previous` is the last pass's result: a PR whose enrichment fails this pass
    /// keeps its previous enriched fields instead of resetting to "not waiting" —
    /// otherwise one flaky 5xx flickers the badge and re-fires notification edges.
    public func refresh(filters: [String], viewer: ViewerContext,
                        previous: [PullRequest] = []) async throws -> [PullRequest] {
        // Bare `id`, not `key`: one engine only ever sees one account's PRs, and
        // `previous` reaches us before this pass stamps `accountID` — keying on
        // `key` here would miss every carry-forward.
        let prevByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let base = try await search.openPRsInvolvingMe(filters: filters, teamKeys: viewer.teamKeys)
        let enriched = try await mapConcurrent(base, limit: concurrencyLimit) { pr in
            let old = prevByID[pr.id]
            do {
                return try await enrich(pr, viewer: viewer, previous: old)
            } catch GitHubError.rateLimited(let until) {
                throw GitHubError.rateLimited(retryAfter: until)   // pause the scheduler
            } catch GitHubError.unauthorized {
                throw GitHubError.unauthorized                     // trigger re-auth
            } catch {
                // One forbidden/deleted/flaky PR must not freeze the whole menu.
                // Fall back to the last pass's enriched fields (fresh search fields
                // still win); a PR never enriched stays un-enriched.
                guard let old else { return pr }
                var out = pr
                out.headSHA = old.headSHA
                out.ciState = old.ciState
                out.waitingOnMe = old.waitingOnMe
                out.waitReason = old.waitReason
                out.reviewRound = old.reviewRound
                return out
            }
        }
        // Stamped once, after every return path above, so a future third path
        // can't forget one of them.
        return enriched.map {
            var out = $0
            out.accountID = accountID
            out.isMine = $0.author == viewer.login
            return out
        }
    }

    private func enrich(_ pr: PullRequest, viewer: ViewerContext,
                        previous: PullRequest?) async throws -> PullRequest {
        let (owner, repo) = pr.ownerRepo
        let detail = try await client.pullDetail(owner: owner, repo: repo, number: pr.number)
        let ci = try await client.ciState(owner: owner, repo: repo, sha: detail.headSHA)
        // qualify team slugs with the repo owner (the org) to match viewer team keys (case-insensitive)
        let teamKeys = detail.requestedTeamSlugs.map { "\(owner.lowercased())/\($0.lowercased())" }
        let signal = ReviewSignal(requestedReviewerLogins: detail.requestedReviewers,
                                  requestedTeamKeys: teamKeys)
        let reason = Classifier.waitReason(isDraft: detail.isDraft, author: pr.author,
                                           ci: ci, signal: signal, viewer: viewer)
        var out = pr
        out.headSHA = detail.headSHA
        out.ciState = ci
        out.waitReason = reason
        out.waitingOnMe = reason != nil
        out.reviewRound = try await reviewRound(for: pr, reason: reason,
                                                viewer: viewer, previous: previous)
        return out
    }

    /// First review vs re-review — only for PRs actually asking you, since the
    /// answer is meaningless otherwise and costs a call.
    ///
    /// The answer can only change when you submit a review or the author
    /// re-requests you, and both move the PR's `updatedAt` — which the search
    /// pass already handed us. So an unchanged PR reuses the last answer and the
    /// steady-state cost of this feature is zero extra requests.
    private func reviewRound(for pr: PullRequest, reason: WaitReason?, viewer: ViewerContext,
                             previous: PullRequest?) async throws -> ReviewRound? {
        guard reason == .reviewRequested || reason == .teamReview else { return nil }
        if let previous, previous.updatedAt == pr.updatedAt, let known = previous.reviewRound {
            return known
        }
        let (owner, repo) = pr.ownerRepo
        do {
            let reviewed = try await client.hasReviewed(owner: owner, repo: repo,
                                                        number: pr.number, login: viewer.login)
            return reviewed ? .again : .first
        } catch GitHubError.rateLimited(let until) {
            throw GitHubError.rateLimited(retryAfter: until)   // pause the scheduler
        } catch {
            // This is the least important field on the PR. A flaky /reviews must
            // not discard the CI state and wait reason we just fetched.
            return previous?.reviewRound
        }
    }
}
