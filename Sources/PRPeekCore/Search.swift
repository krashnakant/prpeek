import Foundation

/// Wire wrapper for /search/issues.
struct SearchPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}

/// One /search/issues item (we query `is:pr` so every item is a PR).
struct SearchItem: Decodable, Sendable {
    let number: Int
    let title: String
    let htmlURL: URL
    let nodeID: String
    let draft: Bool?
    let user: UserRef
    let repositoryURL: String       // "https://api.github.com/repos/owner/name"
    let updatedAt: Date

    struct UserRef: Decodable, Sendable { let login: String }

    enum CodingKeys: String, CodingKey {
        case number, title, user, draft
        case htmlURL = "html_url"
        case nodeID = "node_id"
        case repositoryURL = "repository_url"
        case updatedAt = "updated_at"
    }

    /// "https://api.github.com/repos/owner/name" -> "owner/name"
    var repoFullName: String {
        let marker = "/repos/"
        guard let r = repositoryURL.range(of: marker) else { return repositoryURL }
        return String(repositoryURL[r.upperBound...])
    }

    func toPullRequest() -> PullRequest {
        PullRequest(id: nodeID, number: number, repoFullName: repoFullName, title: title,
                    htmlURL: htmlURL, isDraft: draft ?? false, author: user.login,
                    headSHA: nil, ciState: .none, waitingOnMe: false, updatedAt: updatedAt)
    }
}

/// The v1 backbone: one search query covers your PRs across all personal + org
/// repos the token can see — zero enumeration (eng-review reversal). Curated
/// repos are an optional narrowing filter, not the source of truth.
public struct SearchService: Sendable {
    let client: GitHubClient
    public init(client: GitHubClient) { self.client = client }

    /// `filters` = curated "owner/name" repos. Empty = everything involving you.
    /// Multiple `repo:` qualifiers OR together (narrow to those repos).
    ///
    /// `involves:@me` covers author / assignee / mention / commenter / individual
    /// review-request — but NOT a PR where only your *team* is requested (the
    /// common CODEOWNERS flow). Search has no OR across qualifiers, so each team
    /// gets its own `team-review-requested:org/slug` query and we union by id.
    public func openPRsInvolvingMe(filters: [String] = [], teamKeys: Set<String> = [],
                                   maxItems: Int = 1000) async throws -> [PullRequest] {
        var queries = [Self.searchPath(filters: filters)]
        queries += teamKeys.sorted().map {
            Self.searchPath(filters: filters, involvement: "team-review-requested:\($0)")
        }
        var byID: [String: PullRequest] = [:]
        for path in queries {
            let items: [SearchItem] = try await client.getSearchItems(pathAndQuery: path, maxItems: maxItems)
            for item in items { byID[item.nodeID] = item.toPullRequest() }
        }
        // Deterministic, newest-first (dict order isn't stable -> menu would jitter).
        return Array(byID.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.number < $1.number
        }.prefix(maxItems))
    }

    /// Build "/search/issues?q=...&per_page=100" with the query percent-encoded.
    static func searchPath(filters: [String], involvement: String = "involves:@me") -> String {
        var terms = ["is:pr", "is:open", "archived:false", involvement]
        terms += filters.map { "repo:\($0)" }
        let q = terms.joined(separator: " ")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: q),
                            URLQueryItem(name: "per_page", value: "100")]
        return "/search/issues?\(comps.percentEncodedQuery ?? "")"
    }
}

// ponytail: the Search API's 30 req/min cap is enforced by the poller's cadence
// (T6) — a pass paginates ≤10 requests (1000/100) per query × (1 + team count),
// still far under 30 for any realistic membership on the 3-min cadence. Add a
// per-call limiter only if a future fast `/notifications` tier polls sub-minute,
// or someone is on dozens of teams.
