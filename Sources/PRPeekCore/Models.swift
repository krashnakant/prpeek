import Foundation

/// CI/checks rollup for a PR's head commit. Precise definition lives in the
/// classifier (T5); this is the displayed state.
public enum CIState: String, Codable, Sendable {
    case passing, failing, pending, none
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
    public let updatedAt: Date

    public init(id: String, number: Int, repoFullName: String, title: String,
                htmlURL: URL, isDraft: Bool, author: String, headSHA: String? = nil,
                ciState: CIState = .none, waitingOnMe: Bool = false, updatedAt: Date) {
        self.id = id; self.number = number; self.repoFullName = repoFullName
        self.title = title; self.htmlURL = htmlURL; self.isDraft = isDraft
        self.author = author; self.headSHA = headSHA; self.ciState = ciState
        self.waitingOnMe = waitingOnMe; self.updatedAt = updatedAt
    }

    /// "owner/name" -> (owner, name). The one owner of this split (was copied in
    /// RefreshEngine and AppModel).
    public var ownerRepo: (owner: String, repo: String) {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}

/// Everything persisted to disk. `schemaVersion` gates migration/recovery.
public struct PRPeekState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var filters: [String]          // curated repo qualifiers, e.g. "owner/name"
    public var pullRequests: [PullRequest] // last-known cache -> instant UI on launch
    public var lastUpdated: Date?

    public init(schemaVersion: Int = PRPeekState.currentSchema,
                filters: [String] = [],
                pullRequests: [PullRequest] = [],
                lastUpdated: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.filters = filters
        self.pullRequests = pullRequests
        self.lastUpdated = lastUpdated
    }

    public static let empty = PRPeekState()
}
