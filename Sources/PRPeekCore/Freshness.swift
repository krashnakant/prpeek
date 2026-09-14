import Foundation

/// How fresh a waiting PR is — the "have I dealt with this yet?" axis, separate
/// from `WaitReason` ("why does it want me?").
///
/// Two of the three inputs are local and free: whether the user has opened the
/// PR from PRPeek, and when PRPeek first saw it waiting. The third, re-review,
/// is exact and comes from the API (see `ReviewRound`).
public enum Freshness {
    /// A PR waiting on you longer than this reads as stale. Three days: long
    /// enough that a weekend doesn't turn everything orange, short enough that a
    /// forgotten review still surfaces.
    public static let staleAfter: TimeInterval = 3 * 24 * 3600

    /// nil = not waiting on you, so nothing to say about freshness.
    ///
    /// Priority: a re-request outranks everything (the author is blocked on you
    /// *again*), then never-opened, then age. A PR you have opened and that is
    /// still inside the window gets `.seen` — which the UI renders as no badge
    /// at all, so only the things you haven't handled carry a mark.
    public static func state(for pr: PullRequest, seen: Date?, waitingSince: Date?,
                             now: Date, staleAfter: TimeInterval = Freshness.staleAfter) -> PRFreshness? {
        guard pr.waitingOnMe else { return nil }
        if pr.reviewRound == .again { return .reReview }
        if seen == nil { return .new }
        if let waitingSince, now.timeIntervalSince(waitingSince) >= staleAfter { return .stale }
        return .seen
    }

    /// Roll the waiting-since clock forward one refresh pass: start it for PRs
    /// that are newly waiting, keep it for ones still waiting, drop everything
    /// else so the map can't grow without bound.
    public static func trackWaiting(_ previous: [String: Date], current: [PullRequest],
                                    now: Date) -> [String: Date] {
        var out: [String: Date] = [:]
        for pr in current where pr.waitingOnMe {
            out[pr.key] = previous[pr.key] ?? now
        }
        return out
    }

    /// Forget "seen" for PRs that are gone, and for any PR the author has pushed
    /// to since you looked — a new commit means what you saw is out of date.
    public static func pruneSeen(_ previous: [String: Date], current: [PullRequest]) -> [String: Date] {
        var out: [String: Date] = [:]
        for pr in current {
            guard let at = previous[pr.key] else { continue }
            if pr.updatedAt <= at { out[pr.key] = at }
        }
        return out
    }
}
