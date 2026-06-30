import Foundation

public enum NotificationKind: String, Sendable, Equatable {
    case reviewRequested
    case ciFailed
}

public struct NotificationEvent: Sendable, Equatable, Identifiable {
    public let prID: String
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let url: URL
    public init(prID: String, kind: NotificationKind, title: String, body: String, url: URL) {
        self.prID = prID; self.kind = kind; self.title = title; self.body = body; self.url = url
    }
    /// Dedup key: one notification per (PR, kind).
    public var id: String { "\(prID):\(kind.rawValue)" }
}

/// Decides which notifications to fire by diffing the previous pass against the
/// current one. Firing only on the TRANSITION (edge) is the dedup: a PR that
/// stays "waiting" doesn't re-notify every poll.
public enum NotificationPlanner {
    public static func events(previous: [PullRequest],
                              current: [PullRequest],
                              viewerLogin: String) -> [NotificationEvent] {
        let prev = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [NotificationEvent] = []
        var seen = Set<String>()

        for pr in current {
            let before = prev[pr.id]

            // Review requested of you: waiting via reviewer/team (author != you),
            // and it wasn't in that state last pass.
            let nowReview = pr.waitingOnMe && pr.author != viewerLogin
            let wasReview = (before?.waitingOnMe ?? false) && (before?.author != viewerLogin)
            if nowReview && !wasReview {
                add(&out, &seen, NotificationEvent(
                    prID: pr.id, kind: .reviewRequested,
                    title: "Review requested",
                    body: "\(pr.author) — \(pr.repoFullName)#\(pr.number)",
                    url: pr.htmlURL))
            }

            // CI failed on your own PR, edge-triggered.
            let nowCIFail = pr.author == viewerLogin && pr.ciState == .failing
            let wasCIFail = (before?.author == viewerLogin) && (before?.ciState == .failing)
            if nowCIFail && !wasCIFail {
                add(&out, &seen, NotificationEvent(
                    prID: pr.id, kind: .ciFailed,
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
            guard let m = mutes[pr.id], m.until == nil, !m.active(for: pr, now: now),
                  pr.waitingOnMe, let reason = pr.waitReason else { return nil }
            let kind: NotificationKind = reason == .ciFailing ? .ciFailed : .reviewRequested
            return NotificationEvent(
                prID: pr.id, kind: kind,
                title: kind == .ciFailed ? "CI still failing" : "Still waiting on you",
                body: "\(pr.repoFullName)#\(pr.number)", url: pr.htmlURL)
        }
    }
}
