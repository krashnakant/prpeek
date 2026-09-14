import Foundation

/// The only three calls in PRPeek that change anything on GitHub — merge a PR,
/// ask someone to review it again, reply to a review comment. Everything else in
/// Core reads, so the writes live together: one file to audit, one file to hand
/// a read-only token and watch fail.

/// How GitHub should land the branch. Mirrors `merge_method`.
public enum MergeMethod: String, Sendable, CaseIterable {
    case merge, squash, rebase
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
}
