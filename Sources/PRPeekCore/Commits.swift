import Foundation

/// One commit in a PR's timeline. `ciState` is the check-runs rollup for this
/// commit's SHA (one extra call per commit — see `commits(...)`).
public struct Commit: Sendable, Equatable, Identifiable {
    public let id: String          // full SHA
    public let shortSHA: String
    public let message: String     // first line only
    public let author: String
    public let date: Date
    public let ciState: CIState
    public let htmlURL: URL?

    public init(id: String, shortSHA: String, message: String, author: String,
                date: Date, ciState: CIState, htmlURL: URL?) {
        self.id = id; self.shortSHA = shortSHA; self.message = message
        self.author = author; self.date = date; self.ciState = ciState; self.htmlURL = htmlURL
    }
}

/// GET /repos/{o}/{r}/pulls/{n}/commits
struct CommitDTO: Decodable, Sendable {
    let sha: String
    let htmlURL: URL?
    let commit: Inner
    let author: GHUser?      // null for commits not linked to a GitHub account
    struct Inner: Decodable, Sendable {
        let message: String
        let author: GitAuthor?
        struct GitAuthor: Decodable, Sendable { let name: String?; let date: Date? }
    }
    struct GHUser: Decodable, Sendable { let login: String }
    enum CodingKeys: String, CodingKey { case sha, commit, author; case htmlURL = "html_url" }

    func toCommit(ci: CIState) -> Commit {
        let firstLine = commit.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? commit.message
        let who = author?.login ?? commit.author?.name ?? "?"
        return Commit(id: sha, shortSHA: String(sha.prefix(7)), message: firstLine,
                      author: who, date: commit.author?.date ?? .distantPast,
                      ciState: ci, htmlURL: htmlURL)
    }
}

public extension GitHubClient {
    /// On-demand commit timeline for a PR, newest `cap` commits, each enriched
    /// with its check-runs CI. The CI fan-out is the expensive part — one call
    /// per commit — so it's capped + concurrency-limited and only runs on submenu
    /// open, never in the refresh loop.
    func commits(owner: String, repo: String, number: Int,
                 cap: Int = 20, ciConcurrency: Int = 5) async throws -> [Commit] {
        let dtos: [CommitDTO] = try await getCollection(path: "/repos/\(owner)/\(repo)/pulls/\(number)/commits")
        let recent = Array(dtos.suffix(cap))   // API returns oldest->newest; keep the last `cap`
        return try await mapConcurrent(recent, limit: ciConcurrency) { dto in
            let ci = (try? await self.ciState(owner: owner, repo: repo, sha: dto.sha)) ?? .none
            return dto.toCommit(ci: ci)
        }
    }
}
