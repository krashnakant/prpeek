import Foundation

/// One signed-in GitHub identity. PRPeek watches several at once (personal +
/// work GHES, say), so everything that used to be implicitly "the" account —
/// token, client, viewer, ETag cache — is now scoped by one of these.
///
/// The token itself never lives here: it stays in the Keychain under
/// `keychainAccount`, so an `Account` is safe to persist in the plain JSON cache.
public struct Account: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    /// GitHub Enterprise Server host, or "" for github.com. Drives both the API
    /// base and the web base — see `GitHubClient.apiBase(forHost:)`.
    public var host: String
    /// What the menu calls it. Defaults to the login once the viewer resolves.
    public var label: String

    public init(id: String = UUID().uuidString, host: String = "", label: String) {
        self.id = id; self.host = GitHubClient.cleanHost(host); self.label = label
    }

    /// Keychain account name for this identity's token. The first account keeps
    /// the pre-multi-account name so an existing install signs in as itself
    /// instead of landing on a sign-in screen after upgrading.
    public var keychainAccount: String {
        id == Account.primaryID ? "github-token" : "github-token-\(id)"
    }

    /// Stable id for the account migrated from the single-account era.
    public static let primaryID = "primary"

    /// Display host, for menus: "github.com" when blank.
    public var displayHost: String { host.isEmpty ? "github.com" : host }
}
