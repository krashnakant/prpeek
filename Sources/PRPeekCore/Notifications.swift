import Foundation

public enum NotificationKind: String, Sendable, Equatable {
    case reviewRequested
    case ciFailed
}

public struct NotificationEvent: Sendable, Equatable, Identifiable {
    /// Account-scoped PR key (`PullRequest.key`), not the bare node_id — two
    /// hosts can mint the same node_id, and one would silently swallow the
    /// other's notification.
    public let prKey: String
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let url: URL
    public init(prKey: String, kind: NotificationKind, title: String, body: String, url: URL) {
        self.prKey = prKey; self.kind = kind; self.title = title; self.body = body; self.url = url
    }
    /// Dedup key: one notification per (PR, kind).
    public var id: String { "\(prKey):\(kind.rawValue)" }
}

/// Decides which notifications to fire by diffing the previous pass against the
/// current one. Firing only on the TRANSITION (edge) is the dedup: a PR that
/// stays "waiting" doesn't re-notify every poll.
public enum NotificationPlanner {
    /// `isMine` on the PR replaces the old `viewerLogin:` parameter — with
    /// several accounts in one list there is no single viewer to compare against,
    /// and the engine already knew the answer when it enriched each PR.
    public static func events(previous: [PullRequest],
                              current: [PullRequest]) -> [NotificationEvent] {
        let prev = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [NotificationEvent] = []
        var seen = Set<String>()

        for pr in current {
            let before = prev[pr.key]

            // Review requested of you: waiting via reviewer/team (not your PR),
            // and it wasn't in that state last pass.
            let nowReview = pr.waitingOnMe && !pr.isMine
            let wasReview = (before?.waitingOnMe ?? false) && !(before?.isMine ?? false)
            if nowReview && !wasReview {
                add(&out, &seen, NotificationEvent(
                    prKey: pr.key, kind: .reviewRequested,
                    title: pr.reviewRound == .again ? "Re-review requested" : "Review requested",
                    body: "\(pr.author) — \(pr.repoFullName)#\(pr.number)",
                    url: pr.htmlURL))
            }

            // CI failed on your own PR, edge-triggered.
            let nowCIFail = pr.isMine && pr.ciState == .failing
            let wasCIFail = (before?.isMine ?? false) && (before?.ciState == .failing)
            if nowCIFail && !wasCIFail {
                add(&out, &seen, NotificationEvent(
                    prKey: pr.key, kind: .ciFailed,
                    title: "CI failed",
                    body: "\(pr.repoFullName)#\(pr.number)",
                    url: pr.htmlURL))
            }
        }
        return out
    }

    private static func add(_ out: inout [NotificationEvent], _ seen: inout Set<String>,
                            _ e: NotificationEvent) {
        guard !seen.contains(e.id) else { return }
        seen.insert(e.id)
        out.append(e)
    }

    /// "Hide until updated" mutes that just cleared (the PR changed) and are still
    /// waiting -> re-notify once. The edge-triggered `events` can't catch this: the
    /// PR stayed in the waiting state across the mute, so there's no transition.
    /// `mutes` is the PRE-prune snapshot (a cleared mute is still present here).
    public static func resurfacedMutes(current: [PullRequest], mutes: [String: Mute],
                                       now: Date) -> [NotificationEvent] {
        current.compactMap { pr in
            guard let m = mutes[pr.key], m.until == nil, !m.active(for: pr, now: now),
                  pr.waitingOnMe, let reason = pr.waitReason else { return nil }
            let kind: NotificationKind = reason == .ciFailing ? .ciFailed : .reviewRequested
            return NotificationEvent(
                prKey: pr.key, kind: kind,
                title: kind == .ciFailed ? "CI still failing" : "Still waiting on you",
                body: "\(pr.repoFullName)#\(pr.number)", url: pr.htmlURL)
        }
    }
}
