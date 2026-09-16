import Foundation

/// The only three calls in PRPeek that change anything on GitHub — merge a PR,
/// ask someone to review it again, reply to a review comment. Everything else in
/// Core reads, so the writes live together: one file to audit, one file to hand
/// a read-only token and watch fail.

/// How GitHub should land the branch. Mirrors `merge_method`.
public enum MergeMethod: String, Sendable, CaseIterable {
    case merge, squash, rebase
}

/// Review submission event kind.
public enum ReviewVerdictEvent: String, Sendable, CaseIterable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"

    public var title: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request Changes"
        case .comment: return "Comment"
        }
    }

    public var symbol: String {
        switch self {
        case .approve: return "checkmark.circle.fill"
        case .requestChanges: return "exclamationmark.circle.fill"
        case .comment: return "bubble.left.fill"
        }
    }
}

public extension GitHubClient {

    /// PUT /repos/{o}/{r}/pulls/{n}/merge.
    ///
    /// `headSHA` pins the merge to the commit the user was actually looking at in
    /// the menu. If the branch moved since the last refresh GitHub answers 409
    /// instead of merging work nobody in front of this menu has seen.
    func merge(owner: String, repo: String, number: Int,
               headSHA: String, method: MergeMethod = .merge) async throws {
        try await rawWrite(method: "PUT",
                           path: "/repos/\(owner)/\(repo)/pulls/\(number)/merge",
                           body: ["sha": headSHA, "merge_method": method.rawValue])
    }

    /// POST /repos/{o}/{r}/pulls/{n}/requested_reviewers.
    ///
    /// There is no "re-review" endpoint: GitHub drops a reviewer from
    /// `requested_reviewers` the moment they submit, so re-requesting someone who
    /// already reviewed IS asking for a re-review. Same call, no flag.
    func requestReview(owner: String, repo: String, number: Int, reviewers: [String]) async throws {
        guard !reviewers.isEmpty else { return }
        try await rawWrite(method: "POST",
                           path: "/repos/\(owner)/\(repo)/pulls/\(number)/requested_reviewers",
                           body: ["reviewers": reviewers])
    }

    /// Reply to one entry in the review timeline.
    ///
    /// Inline comments thread properly via the replies endpoint. A review has no
    /// reply endpoint at all, so its reply lands as a top-level PR comment (a PR
    /// is an issue, hence the issues path) — the caller warns before posting.
    func reply(owner: String, repo: String, number: Int,
               to comment: ReviewComment, body: String) async throws {
        let path = comment.inlineCommentID.map {
            "/repos/\(owner)/\(repo)/pulls/\(number)/comments/\($0)/replies"
        } ?? "/repos/\(owner)/\(repo)/issues/\(number)/comments"
        try await rawWrite(method: "POST", path: path, body: ["body": body])
    }

    /// POST /repos/{o}/{r}/pulls/{n}/reviews
    /// Submits a formal pull request review verdict (APPROVE, REQUEST_CHANGES, or COMMENT).
    func submitReview(owner: String, repo: String, number: Int,
                      event: ReviewVerdictEvent, body: String? = nil) async throws {
        var payload: [String: any Sendable] = ["event": event.rawValue]
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            payload["body"] = body
        }
        try await rawWrite(method: "POST",
                           path: "/repos/\(owner)/\(repo)/pulls/\(number)/reviews",
                           body: payload)
    }

    /// POST /repos/{o}/{r}/pulls/{n}/comments
    /// Creates a new inline code comment on a specific line of the PR diff.
    func createReviewComment(owner: String, repo: String, number: Int,
                             commitSHA: String, path: String, line: Int,
                             side: String = "RIGHT", body: String) async throws {
        let payload: [String: any Sendable] = [
            "body": body,
            "commit_id": commitSHA,
            "path": path,
            "line": line,
            "side": side
        ]
        try await rawWrite(method: "POST",
                           path: "/repos/\(owner)/\(repo)/pulls/\(number)/comments",
                           body: payload)
    }
}
