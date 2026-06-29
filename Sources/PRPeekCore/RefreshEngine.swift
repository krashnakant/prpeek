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
    public func refresh(filters: [String] = []) async throws -> (viewer: ViewerContext, prs: [PullRequest]) {
        let user = try await client.currentUser()
        let teams = try await client.viewerTeamKeys()
        let viewer = ViewerContext(login: user.login, teamKeys: teams)
        let prs = try await refresh(filters: filters, viewer: viewer)
        return (viewer, prs)
    }

    /// Refresh with a known viewer (lets the app cache identity across passes).
    public func refresh(filters: [String], viewer: ViewerContext) async throws -> [PullRequest] {
        let base = try await search.openPRsInvolvingMe(filters: filters)
        return try await mapConcurrent(base, limit: concurrencyLimit) { pr in
            do {
                return try await enrich(pr, viewer: viewer)
            } catch GitHubError.rateLimited(let until) {
                throw GitHubError.rateLimited(retryAfter: until)   // pause the scheduler
            } catch GitHubError.unauthorized {
                throw GitHubError.unauthorized                     // trigger re-auth
            } catch {
                // One forbidden/deleted/flaky PR must not freeze the whole menu.
                // Keep its search-level data un-enriched (CI unknown, not waiting).
                return pr
            }
        }
    }

    private func enrich(_ pr: PullRequest, viewer: ViewerContext) async throws -> PullRequest {
        let (owner, repo) = Self.split(pr.repoFullName)
        let detail = try await client.pullDetail(owner: owner, repo: repo, number: pr.number)
        let ci = try await client.ciState(owner: owner, repo: repo, sha: detail.headSHA)
        // qualify team slugs with the repo owner (the org) to match viewer team keys
        let teamKeys = detail.requestedTeamSlugs.map { "\(owner)/\($0)" }
        let signal = ReviewSignal(requestedReviewerLogins: detail.requestedReviewers,
                                  requestedTeamKeys: teamKeys)
        let waiting = Classifier.waitingOnMe(isDraft: detail.isDraft, author: pr.author,
                                             ci: ci, signal: signal, viewer: viewer)
        var out = pr
        out.headSHA = detail.headSHA
        out.ciState = ci
        out.waitingOnMe = waiting
        return out
    }

    static func split(_ fullName: String) -> (owner: String, repo: String) {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}
