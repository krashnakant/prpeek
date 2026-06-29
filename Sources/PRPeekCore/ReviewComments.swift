import Foundation

/// A reviewer's verdict, from a PR review's `state`. Inline comments carry no
/// verdict, so they map to `.commented`.
public enum ReviewVerdict: String, Sendable, Equatable {
    case approved, changesRequested, commented
}

/// One entry in a PR's review thread — either a review (verdict + optional body)
/// or an inline code comment (body + file:line). Merged into one timeline.
public struct ReviewComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let author: String
    public let verdict: ReviewVerdict
    public let body: String
    public let location: String?     // "path:line" for inline comments; nil for reviews
    public let createdAt: Date
    public let htmlURL: URL?

    public init(id: String, author: String, verdict: ReviewVerdict, body: String,
                location: String?, createdAt: Date, htmlURL: URL?) {
        self.id = id; self.author = author; self.verdict = verdict; self.body = body
        self.location = location; self.createdAt = createdAt; self.htmlURL = htmlURL
    }
}

// MARK: - Wire DTOs

/// GET /repos/{o}/{r}/pulls/{n}/reviews
struct ReviewDTO: Decodable, Sendable {
    let id: Int
    let user: UserRef?
    let body: String?
    let state: String?            // APPROVED / CHANGES_REQUESTED / COMMENTED / PENDING / DISMISSED
    let submittedAt: Date?
    let htmlURL: URL?
    struct UserRef: Decodable, Sendable { let login: String }
    enum CodingKeys: String, CodingKey {
        case id, user, body, state
        case submittedAt = "submitted_at"
        case htmlURL = "html_url"
    }
}

/// GET /repos/{o}/{r}/pulls/{n}/comments (inline review comments)
struct ReviewCommentDTO: Decodable, Sendable {
    let id: Int
    let user: UserRef?
    let body: String?
    let path: String?
    let line: Int?
    let originalLine: Int?
    let createdAt: Date?
    let htmlURL: URL?
    struct UserRef: Decodable, Sendable { let login: String }
    enum CodingKeys: String, CodingKey {
        case id, user, body, path, line
        case originalLine = "original_line"
        case createdAt = "created_at"
        case htmlURL = "html_url"
    }
}

/// Merge logic kept pure so it's testable without the network.
public enum ReviewThread {
    static func verdict(from state: String?) -> ReviewVerdict {
        switch state?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: return .commented
        }
    }

    /// Reviews + inline comments -> one chronological timeline, capped.
    /// Drops noise: PENDING reviews (your own unsubmitted) and the empty
    /// COMMENTED review wrapper GitHub auto-creates when you leave inline comments.
    static func merge(reviews: [ReviewDTO], comments: [ReviewCommentDTO], cap: Int = 30) -> [ReviewComment] {
        var out: [ReviewComment] = []
        for r in reviews {
            if r.state?.uppercased() == "PENDING" { continue }
            let v = verdict(from: r.state)
            let body = r.body ?? ""
            if v == .commented && body.isEmpty { continue }   // empty wrapper review
            out.append(ReviewComment(id: "r\(r.id)", author: r.user?.login ?? "?", verdict: v,
                                     body: body, location: nil,
                                     createdAt: r.submittedAt ?? .distantPast, htmlURL: r.htmlURL))
        }
        for c in comments {
            let loc = c.path.map { p in (c.line ?? c.originalLine).map { "\(p):\($0)" } ?? p }
            out.append(ReviewComment(id: "c\(c.id)", author: c.user?.login ?? "?", verdict: .commented,
                                     body: c.body ?? "", location: loc,
                                     createdAt: c.createdAt ?? .distantPast, htmlURL: c.htmlURL))
        }
        return Array(out.sorted { $0.createdAt < $1.createdAt }.suffix(cap))
    }
}

public extension GitHubClient {
    /// On-demand (NOT in the refresh loop): a PR's review thread. Two conditional,
    /// paginated GETs merged into a timeline. ETag-cached like every other read.
    func reviewThread(owner: String, repo: String, number: Int) async throws -> [ReviewComment] {
        // Two independent round-trips — overlap them (getCollection suspends at its
        // network await, releasing the actor), so latency is max(RTT) not the sum.
        async let reviews: [ReviewDTO] = getCollection(path: "/repos/\(owner)/\(repo)/pulls/\(number)/reviews")
        async let comments: [ReviewCommentDTO] = getCollection(path: "/repos/\(owner)/\(repo)/pulls/\(number)/comments")
        return try await ReviewThread.merge(reviews: reviews, comments: comments)
    }
}
