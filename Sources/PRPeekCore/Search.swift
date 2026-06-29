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
    public func openPRsInvolvingMe(filters: [String] = [], maxItems: Int = 1000) async throws -> [PullRequest] {
        let items: [SearchItem] = try await client.getSearchItems(
            pathAndQuery: Self.searchPath(filters: filters), maxItems: maxItems)
        return items.map { $0.toPullRequest() }
    }

    /// Build "/search/issues?q=...&per_page=100" with the query percent-encoded.
    static func searchPath(filters: [String]) -> String {
        var terms = ["is:pr", "is:open", "archived:false", "involves:@me"]
        terms += filters.map { "repo:\($0)" }
        let q = terms.joined(separator: " ")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: q),
                            URLQueryItem(name: "per_page", value: "100")]
        return "/search/issues?\(comps.percentEncodedQuery ?? "")"
    }
}

// ponytail: the Search API's 30 req/min cap is enforced by the poller's cadence
// (T6) — one coalesced pass paginates ≤10 requests (1000/100), far under 30.
// A per-call limiter here would be belt-and-suspenders; add it only if a future
// fast `/notifications` tier polls search sub-minute.
