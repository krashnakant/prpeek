import Foundation

/// ONE coalesced refresh pass (plan: single coalesced poll, not per-repo timers):
///   search involves:@me  ->  per-PR enrich (detail + check-runs)  ->  classify.
/// The per-PR step fans out under a concurrency cap. A `.rateLimited` thrown from
/// any call propagates so the scheduler (app layer) can pause until retryAfter.
public struct RefreshEngine: Sendable {
    let client: GitHubClient
    let search: SearchService
    public let concurrencyLimit: Int

    public init(client: GitHubClient, concurrencyLimit: Int = 5) {
        self.client = client
        self.search = SearchService(client: client)
        self.concurrencyLimit = concurrencyLimit
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
        let prevByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let base = try await search.openPRsInvolvingMe(filters: filters, teamKeys: viewer.teamKeys)
        return try await mapConcurrent(base, limit: concurrencyLimit) { pr in
            do {
                return try await enrich(pr, viewer: viewer)
            } catch GitHubError.rateLimited(let until) {
                throw GitHubError.rateLimited(retryAfter: until)   // pause the scheduler
            } catch GitHubError.unauthorized {
                throw GitHubError.unauthorized                     // trigger re-auth
            } catch {
                // One forbidden/deleted/flaky PR must not freeze the whole menu.
                // Fall back to the last pass's enriched fields (fresh search fields
                // still win); a PR never enriched stays un-enriched.
                guard let old = prevByID[pr.id] else { return pr }
                var out = pr
                out.headSHA = old.headSHA
                out.ciState = old.ciState
                out.waitingOnMe = old.waitingOnMe
                out.waitReason = old.waitReason
                return out
            }
        }
    }

    private func enrich(_ pr: PullRequest, viewer: ViewerContext) async throws -> PullRequest {
        let (owner, repo) = pr.ownerRepo
        let detail = try await client.pullDetail(owner: owner, repo: repo, number: pr.number)
        let ci = try await client.ciState(owner: owner, repo: repo, sha: detail.headSHA)
        // qualify team slugs with the repo owner (the org) to match viewer team keys
        let teamKeys = detail.requestedTeamSlugs.map { "\(owner)/\($0)" }
        let signal = ReviewSignal(requestedReviewerLogins: detail.requestedReviewers,
                                  requestedTeamKeys: teamKeys)
        let reason = Classifier.waitReason(isDraft: detail.isDraft, author: pr.author,
                                           ci: ci, signal: signal, viewer: viewer)
        var out = pr
        out.headSHA = detail.headSHA
        out.ciState = ci
        out.waitReason = reason
        out.waitingOnMe = reason != nil
        return out
    }
}
