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
}
