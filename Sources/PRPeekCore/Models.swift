import Foundation

/// CI/checks rollup for a PR's head commit. Precise definition lives in the
/// classifier (T5); this is the displayed state.
public enum CIState: String, Codable, Sendable {
    case passing, failing, pending, none
}

/// WHY a PR is "waiting on me" — the classifier computes this; the menu surfaces
/// it so the badge isn't just a binary "something needs you".
public enum WaitReason: String, Codable, Sendable, Equatable {
    case reviewRequested   // you are individually requested as a reviewer
    case teamReview        // your team is requested (the CODEOWNERS path)
    case ciFailing         // your own PR, CI is red
}

/// Domain model (NOT the wire DTO). Identified by `id` = GitHub `node_id`, which
/// survives repo rename/transfer (plan: cache identity). `number` is repo-local.
public struct PullRequest: Codable, Sendable, Identifiable, Equatable {
    public let id: String            // node_id — stable cache key
    public let number: Int
    public let repoFullName: String  // "owner/name" for display
    public let title: String
    public let htmlURL: URL
    public let isDraft: Bool
    public let author: String
    public var headSHA: String?
    public var ciState: CIState
    public var waitingOnMe: Bool
    /// The reason it's waiting (nil when not waiting). Surfaced in the menu.
    public var waitReason: WaitReason?
    public let updatedAt: Date

    public init(id: String, number: Int, repoFullName: String, title: String,
                htmlURL: URL, isDraft: Bool, author: String, headSHA: String? = nil,
                ciState: CIState = .none, waitingOnMe: Bool = false,
                waitReason: WaitReason? = nil, updatedAt: Date) {
        self.id = id; self.number = number; self.repoFullName = repoFullName
        self.title = title; self.htmlURL = htmlURL; self.isDraft = isDraft
        self.author = author; self.headSHA = headSHA; self.ciState = ciState
        self.waitingOnMe = waitingOnMe; self.waitReason = waitReason; self.updatedAt = updatedAt
    }

    /// "owner/name" -> (owner, name). The one owner of this split (was copied in
    /// RefreshEngine and AppModel).
    public var ownerRepo: (owner: String, repo: String) {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}

/// A per-PR mute (snooze). Either a timed snooze (`until` set) or "hide until it
/// updates" (`until` nil — muted while the PR's `updatedAt` hasn't moved past the
/// snapshot taken when muted).
public struct Mute: Codable, Sendable, Equatable {
    public let updatedAtSnapshot: Date
    public let until: Date?
    public init(updatedAtSnapshot: Date, until: Date?) {
        self.updatedAtSnapshot = updatedAtSnapshot; self.until = until
    }
    /// Still muted at `now`? Timed: before the deadline. Until-updated: the PR
    /// hasn't changed since it was muted.
    public func active(for pr: PullRequest, now: Date) -> Bool {
        if let until { return now < until }
        return pr.updatedAt <= updatedAtSnapshot
    }
}

/// Everything persisted to disk. `schemaVersion` gates migration/recovery.
public struct PRPeekState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var filters: [String]          // curated repo qualifiers, e.g. "owner/name"
    public var pullRequests: [PullRequest] // last-known cache -> instant UI on launch
    public var lastUpdated: Date?
    public var mutes: [String: Mute]      // PR id -> snooze; pruned each refresh

    public init(schemaVersion: Int = PRPeekState.currentSchema,
                filters: [String] = [],
                pullRequests: [PullRequest] = [],
                lastUpdated: Date? = nil,
                mutes: [String: Mute] = [:]) {
        self.schemaVersion = schemaVersion
        self.filters = filters
        self.pullRequests = pullRequests
        self.lastUpdated = lastUpdated
        self.mutes = mutes
    }

    // Tolerant decode: `mutes` is additive, so a cache written before it existed
    // (key absent) still loads — no schema bump, no cache drop on upgrade.
    enum CodingKeys: String, CodingKey { case schemaVersion, filters, pullRequests, lastUpdated, mutes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? PRPeekState.currentSchema
        filters = try c.decodeIfPresent([String].self, forKey: .filters) ?? []
        pullRequests = try c.decodeIfPresent([PullRequest].self, forKey: .pullRequests) ?? []
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        mutes = try c.decodeIfPresent([String: Mute].self, forKey: .mutes) ?? [:]
    }

    /// Is this PR currently muted?
    public func isMuted(_ pr: PullRequest, now: Date) -> Bool {
        mutes[pr.id]?.active(for: pr, now: now) ?? false
    }

    public static let empty = PRPeekState()
}
