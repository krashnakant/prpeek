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

/// Whether this is the first time you've been asked to review a PR, or you
/// already reviewed it and the author has asked again. Exact, not a heuristic:
/// GitHub drops you from `requested_reviewers` the moment you submit a review,
/// so "has a prior review by me AND is requesting me now" can only mean a
/// re-request. nil = not currently asking for your review.
public enum ReviewRound: String, Codable, Sendable, Equatable {
    case first    // never reviewed by you
    case again    // you reviewed, the author pushed and re-requested
}

/// What the UI shows about how fresh a waiting PR is. Derived, never stored —
/// see `Freshness.state(...)`.
public enum PRFreshness: String, Sendable, Equatable {
    case new        // waiting, you have not opened it in PRPeek
    case seen       // waiting, you opened it, still within the stale window
    case stale      // waiting on you longer than `Freshness.staleAfter`
    case reReview   // you reviewed it once; the author asked again
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
    /// Which signed-in account saw this PR. "" only in a cache written before
    /// multi-account existed — the app backfills it on load.
    public var accountID: String
    /// Authored by the viewer of `accountID`. Stored rather than recomputed so
    /// nothing above the engine needs to know which viewer a PR belongs to.
    public var isMine: Bool
    /// First-review vs re-review, for PRs currently requesting your review.
    public var reviewRound: ReviewRound?

    public init(id: String, number: Int, repoFullName: String, title: String,
                htmlURL: URL, isDraft: Bool, author: String, headSHA: String? = nil,
                ciState: CIState = .none, waitingOnMe: Bool = false,
                waitReason: WaitReason? = nil, updatedAt: Date,
                accountID: String = "", isMine: Bool = false,
                reviewRound: ReviewRound? = nil) {
        self.id = id; self.number = number; self.repoFullName = repoFullName
        self.title = title; self.htmlURL = htmlURL; self.isDraft = isDraft
        self.author = author; self.headSHA = headSHA; self.ciState = ciState
        self.waitingOnMe = waitingOnMe; self.waitReason = waitReason; self.updatedAt = updatedAt
        self.accountID = accountID; self.isMine = isMine; self.reviewRound = reviewRound
    }

    /// Account-scoped identity. `id` is a GitHub node_id, which is only unique
    /// WITHIN a host — github.com and a GHES instance can mint the same one — so
    /// every per-PR map (mutes, seen, waiting-since, notification dedup) keys on
    /// this, never on `id` alone.
    public var key: String { "\(accountID):\(id)" }

    public var repoOwner: String {
        repoFullName.components(separatedBy: "/").first ?? ""
    }

    public var repoName: String {
        repoFullName.components(separatedBy: "/").last ?? repoFullName
    }

    // Tolerant decode: the three multi-account/freshness fields are additive, so
    // a cache written before them still loads instead of being quarantined.
    enum CodingKeys: String, CodingKey {
        case id, number, repoFullName, title, htmlURL, isDraft, author, headSHA
        case ciState, waitingOnMe, waitReason, updatedAt, accountID, isMine, reviewRound
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        repoFullName = try c.decode(String.self, forKey: .repoFullName)
        title = try c.decode(String.self, forKey: .title)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        author = try c.decode(String.self, forKey: .author)
        headSHA = try c.decodeIfPresent(String.self, forKey: .headSHA)
        ciState = try c.decodeIfPresent(CIState.self, forKey: .ciState) ?? .none
        waitingOnMe = try c.decodeIfPresent(Bool.self, forKey: .waitingOnMe) ?? false
        waitReason = try c.decodeIfPresent(WaitReason.self, forKey: .waitReason)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        isMine = try c.decodeIfPresent(Bool.self, forKey: .isMine) ?? false
        reviewRound = try c.decodeIfPresent(ReviewRound.self, forKey: .reviewRound)
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
    /// 2 = PRs carry `accountID` and the per-PR maps key on `PullRequest.key`.
    public static let currentSchema = 2

    public var schemaVersion: Int
    public var filters: [String]          // curated repo qualifiers, e.g. "owner/name"
    public var pullRequests: [PullRequest] // last-known cache -> instant UI on launch
    public var lastUpdated: Date?
    public var mutes: [String: Mute]      // PR key -> snooze; pruned each refresh
    /// Every signed-in identity. Empty in a pre-multi-account cache; the app
    /// seeds the migrated primary account on load.
    public var accounts: [Account]
    /// PR key -> when the user opened it from PRPeek. Drives new-vs-seen.
    public var seen: [String: Date]
    /// PR key -> the first refresh pass that saw it waiting on the user. An
    /// honest "waiting since at least"; GitHub's review-request timestamp needs
    /// the timeline API, which is a whole extra call per PR.
    public var waitingSince: [String: Date]

    public init(schemaVersion: Int = PRPeekState.currentSchema,
                filters: [String] = [],
                pullRequests: [PullRequest] = [],
                lastUpdated: Date? = nil,
                mutes: [String: Mute] = [:],
                accounts: [Account] = [],
                seen: [String: Date] = [:],
                waitingSince: [String: Date] = [:]) {
        self.schemaVersion = schemaVersion
        self.filters = filters
        self.pullRequests = pullRequests
        self.lastUpdated = lastUpdated
        self.mutes = mutes
        self.accounts = accounts
        self.seen = seen
        self.waitingSince = waitingSince
    }

    // Tolerant decode: every field past `pullRequests` is additive, so a cache
    // written before it existed still loads — no schema bump, no cache drop, and
    // an upgrading user keeps their mutes.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, filters, pullRequests, lastUpdated, mutes, accounts, seen, waitingSince
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? PRPeekState.currentSchema
        filters = try c.decodeIfPresent([String].self, forKey: .filters) ?? []
        pullRequests = try c.decodeIfPresent([PullRequest].self, forKey: .pullRequests) ?? []
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        mutes = try c.decodeIfPresent([String: Mute].self, forKey: .mutes) ?? [:]
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        waitingSince = try c.decodeIfPresent([String: Date].self, forKey: .waitingSince) ?? [:]
    }

    /// Is this PR currently muted?
    public func isMuted(_ pr: PullRequest, now: Date) -> Bool {
        mutes[pr.key]?.active(for: pr, now: now) ?? false
    }

    /// Migrate a v1 (single-account) cache: stamp every PR with the adopted
    /// account and re-key the mutes, which used the bare node_id.
    ///
    /// Triggered by `schemaVersion`, not by sniffing the contents. Content
    /// sniffing ("no accounts yet") can't tell a v1 cache from the legitimately
    /// empty state after signing out of everything, and would keep re-seeding a
    /// token-less phantom account on every launch.
    public mutating func migrate(adopting primary: Account) {
        guard schemaVersion < 2 else { return }
        let prefix = "\(primary.id):"
        for i in pullRequests.indices where pullRequests[i].accountID.isEmpty {
            pullRequests[i].accountID = primary.id
        }
        mutes = Dictionary(uniqueKeysWithValues: mutes.map { k, v in
            (k.contains(":") ? k : prefix + k, v)
        })
        if accounts.isEmpty { accounts = [primary] }
        schemaVersion = PRPeekState.currentSchema
    }

    /// Advance every per-PR map against the PRs this pass returned: start or keep
    /// the waiting clock, forget stale "seen" marks, drop lapsed mutes. One owner
    /// for all three, so a fourth map can't be added and silently never pruned.
    public mutating func prune(against prs: [PullRequest], now: Date) {
        waitingSince = Freshness.trackWaiting(waitingSince, current: prs, now: now)
        seen = Freshness.pruneSeen(seen, current: prs)
        let byKey = Dictionary(prs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        mutes = mutes.filter { key, m in
            guard let pr = byKey[key] else { return false }
            return m.active(for: pr, now: now)
        }
    }

    /// Drop an account's rows and everything keyed to them. Lives here because
    /// `PullRequest.key`'s format is defined here — the UI shouldn't be
    /// hand-matching a `"<id>:"` prefix in three places.
    public mutating func forget(account id: String) {
        let prefix = "\(id):"
        pullRequests.removeAll { $0.accountID == id }
        accounts.removeAll { $0.id == id }
        mutes = mutes.filter { !$0.key.hasPrefix(prefix) }
        seen = seen.filter { !$0.key.hasPrefix(prefix) }
        waitingSince = waitingSince.filter { !$0.key.hasPrefix(prefix) }
    }

    public static let empty = PRPeekState()
}
