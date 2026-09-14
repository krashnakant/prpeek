import Foundation

/// Everything that used to be a single-account field on `AppModel` — token,
/// client, engine, viewer, per-PR caches, last pass's PRs, status — scoped to
/// one signed-in identity. `AppModel` now owns an array of these and merges
/// their results.
///
/// One session per account also means one ETag cache per account, which is what
/// keeps a conditional request for the byte-identical `/search/issues` URL from
/// returning another account's body.
@MainActor
public final class AccountSession {
    public let account: Account
    public let client: GitHubClient
    public let engine: RefreshEngine
    private let tokenStore: TokenStore

    public var viewer: ViewerContext?
    public var status: AppStatus
    public var previousPRs: [PullRequest] = []
    /// Suppress notifications for this account's first pass — otherwise adding an
    /// account fires one notification per PR already waiting in it.
    public var firstPass = true
    /// See `AppModel`'s note: a Keychain read on an ad-hoc-signed build re-prompts,
    /// so presence is cached in memory and only re-read while a read has failed.
    public var tokenKnown: Bool
    public var hasToken: Bool

    public let commentsCache: PerPRLazyCache<[ReviewComment]>
    public let commitsCache: PerPRLazyCache<[Commit]>

    /// `tokenStore` and `transport` are injectable so tests can exercise the
    /// locked-Keychain and token-lifecycle paths without touching the real one.
    public init(account: Account, cachedPRs: [PullRequest] = [],
                tokenStore: TokenStore? = nil, transport: Transport? = nil) {
        self.account = account
        self.tokenStore = tokenStore ?? KeychainTokenStore(account: account.keychainAccount)
        self.previousPRs = cachedPRs

        let token: String?
        let readOK: Bool
        do { token = try self.tokenStore.read(); readOK = true }
        catch { token = nil; readOK = false }   // Keychain locked at launch
        self.tokenKnown = readOK
        self.hasToken = readOK && token != nil

        let client = GitHubClient(transport: transport ?? URLSessionTransport(),
                                  token: token,
                                  baseURL: GitHubClient.apiBase(forHost: account.host))
        self.client = client
        self.engine = RefreshEngine(client: client, accountID: account.id)
        self.commentsCache = PerPRLazyCache { o, r, n in
            try? await client.reviewThread(owner: o, repo: r, number: n)
        }
        self.commitsCache = PerPRLazyCache { o, r, n in
            try? await client.commits(owner: o, repo: r, number: n)
        }
        self.status = (readOK && token == nil) ? .signedOut(reason: nil) : .loading
    }

    /// Label for the menu: the resolved login once we have it, else whatever the
    /// user typed when adding. GHES accounts get the host too, since the same
    /// login can exist on two hosts.
    public var displayName: String {
        let name = viewer?.login ?? account.label
        return account.host.isEmpty ? name : "\(name) @ \(account.host)"
    }

    /// Retry a launch-time Keychain read that was blocked. Returns false if it's
    /// still locked — the caller must NOT treat that as signed out.
    public func resolveTokenIfNeeded() async -> Bool {
        guard !tokenKnown else { return true }
        do {
            let t = try tokenStore.read()
            hasToken = t != nil
            tokenKnown = true
            if let t { await client.setToken(t) }   // client was built token-less
            return true
        } catch {
            return false
        }
    }

    public func save(token: String) throws {
        try tokenStore.save(token)
        tokenKnown = true
        hasToken = true
    }

    /// Forget this identity entirely: Keychain entry, in-memory token, caches.
    public func signOut() {
        try? tokenStore.delete()   // best effort; the in-memory token is cleared below
        hasToken = false
        tokenKnown = true
        viewer = nil
        previousPRs = []
        firstPass = true
        commentsCache.reset(); commitsCache.reset()
        status = .signedOut(reason: nil)
        let client = self.client
        Task { await client.setToken(nil) }
    }
}
