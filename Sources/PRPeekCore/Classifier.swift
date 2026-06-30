import Foundation

// MARK: - Wire DTOs for the per-PR facts the classifier needs

/// GET /repos/{o}/{r}/pulls/{n} — richer than search results.
struct PRDetail: Decodable, Sendable {
    let draft: Bool
    let head: Head
    let requestedReviewers: [User]
    let requestedTeams: [Team]
    struct Head: Decodable, Sendable { let sha: String }
    struct User: Decodable, Sendable { let login: String }
    struct Team: Decodable, Sendable { let slug: String }
    enum CodingKeys: String, CodingKey {
        case draft, head
        case requestedReviewers = "requested_reviewers"
        case requestedTeams = "requested_teams"
    }
}

/// GET /repos/{o}/{r}/commits/{sha}/check-runs
struct CheckRunsResponse: Decodable, Sendable {
    let checkRuns: [CheckRun]
    enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
}
struct CheckRun: Decodable, Sendable {
    let status: String            // queued | in_progress | completed
    let conclusion: String?       // success | failure | neutral | cancelled | skipped | timed_out | action_required | stale
}

// MARK: - Classification

/// Who's asking, and which teams they belong to (from /user/teams, read:org).
/// Team identity is qualified "orgLogin/slug" so two orgs' same-named teams
/// don't collide.
public struct ViewerContext: Sendable, Equatable {
    public let login: String
    public let teamKeys: Set<String>   // "org/slug"
    public init(login: String, teamKeys: Set<String> = []) {
        self.login = login; self.teamKeys = teamKeys
    }
}

/// The live review-request signal for a PR (requested_reviewers/teams). GitHub
/// drops a reviewer from this set once they submit a review, so "stale/dismissed
/// after approval" is handled by GitHub — we just read the current set.
public struct ReviewSignal: Sendable, Equatable {
    public let requestedReviewerLogins: [String]
    public let requestedTeamKeys: [String]   // "org/slug", qualified by the poller
    public init(requestedReviewerLogins: [String], requestedTeamKeys: [String]) {
        self.requestedReviewerLogins = requestedReviewerLogins
        self.requestedTeamKeys = requestedTeamKeys
    }
}

public enum Classifier {
    /// WHY a PR waits on me (nil = not waiting). NOT a draft AND, in priority:
    ///  - you are a currently-requested reviewer            -> .reviewRequested
    ///  - you are a member of a currently-requested team     -> .teamReview
    ///  - you authored it AND CI is failing                  -> .ciFailing
    public static func waitReason(isDraft: Bool, author: String,
                                  ci: CIState, signal: ReviewSignal,
                                  viewer: ViewerContext) -> WaitReason? {
        if isDraft { return nil }
        if signal.requestedReviewerLogins.contains(viewer.login) { return .reviewRequested }
        if !viewer.teamKeys.isDisjoint(with: Set(signal.requestedTeamKeys)) { return .teamReview }
        if author == viewer.login && ci == .failing { return .ciFailing }
        return nil
    }

    /// Binary "waiting on me" — derived from `waitReason`.
    public static func waitingOnMe(isDraft: Bool, author: String,
                                   ci: CIState, signal: ReviewSignal,
                                   viewer: ViewerContext) -> Bool {
        waitReason(isDraft: isDraft, author: author, ci: ci, signal: signal, viewer: viewer) != nil
    }

    /// Roll up check-runs. Precise rule (plan): any failed run -> failing;
    /// else any not-completed -> pending; else passing; no runs -> none.
    /// neutral/skipped/success/stale are treated as NOT failed.
    static func ciState(from runs: [CheckRun]) -> CIState {
        if runs.isEmpty { return .none }
        let failing: Set<String> = ["failure", "timed_out", "action_required", "cancelled"]
        if runs.contains(where: { ($0.conclusion).map(failing.contains) ?? false }) { return .failing }
        if runs.contains(where: { $0.status != "completed" }) { return .pending }
        return .passing
    }
}

// MARK: - Client fetches the classifier facts

public extension GitHubClient {
    func pullDetail(owner: String, repo: String, number: Int) async throws
        -> (isDraft: Bool, headSHA: String, requestedReviewers: [String], requestedTeamSlugs: [String]) {
        let d: PRDetail = try await getValue(path: "/repos/\(owner)/\(repo)/pulls/\(number)")
        return (d.draft, d.head.sha, d.requestedReviewers.map(\.login), d.requestedTeams.map(\.slug))
    }

    func ciState(owner: String, repo: String, sha: String) async throws -> CIState {
        let r: CheckRunsResponse = try await getValue(path: "/repos/\(owner)/\(repo)/commits/\(sha)/check-runs")
        return Classifier.ciState(from: r.checkRuns)
    }

    /// GET /user/teams -> {"org/slug"} for team-membership classification.
    func viewerTeamKeys() async throws -> Set<String> {
        let teams: [ViewerTeam] = try await getCollection(path: "/user/teams")
        return Set(teams.map { "\($0.organization.login)/\($0.slug)" })
    }
}

struct ViewerTeam: Decodable, Sendable {
    let slug: String
    let organization: Org
    struct Org: Decodable, Sendable { let login: String }
}
