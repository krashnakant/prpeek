import AppKit
import PRPeekCore

enum AppStatus: Equatable {
    case signedOut
    case authorizing(code: String)
    case loading
    case loaded
    case offline
    case rateLimited(until: Date?)
    case error(String)
}

/// The brain. Owns state, the refresh loop, auth, and lifecycle wiring. Drives
/// the menubar via `onChange`. @MainActor: all UI-facing state stays on main;
/// only the GitHubClient actor + engine run off it.
@MainActor
final class AppModel {
    // OAuth App client id (public — device flow needs no secret). Resolution:
    // env PRPEEK_CLIENT_ID (dev) -> Info.plist PRPeekClientID (baked by
    // make-app.sh) -> empty. The PAT-paste path works without it.
    static let clientID: String = {
        if let env = ProcessInfo.processInfo.environment["PRPEEK_CLIENT_ID"], !env.isEmpty { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "PRPeekClientID") as? String { return plist }
        return ""
    }()

    private let tokenStore: TokenStore
    private let store: JSONStore
    private let client: GitHubClient
    private let engine: RefreshEngine
    private let notifier = NotificationService()
    private let lifecycle = LifecycleMonitor()

    private(set) var state: PRPeekState
    private(set) var status: AppStatus = .signedOut
    private(set) var theme: Theme = .system
    /// Parsed once per theme change, not re-derived on every menu render (the
    /// Catppuccin palette parses 6 hex strings).
    private(set) var palette: Palette?
    private var viewer: ViewerContext?
    private var previousPRs: [PullRequest] = []
    private var seenRepos: Set<String> = []   // every repo seen this session (for the filter picker)
    // Cache token presence in memory so the 3-min refresh loop never re-reads the
    // Keychain — each read on an ad-hoc-signed build re-prompts for access.
    // `tokenKnown` stays false only while a launch read failed (Keychain locked),
    // so refreshNow retries until it succeeds, then caches.
    private var tokenKnown = false
    private var hasToken = false
    private var refreshing = false
    private var loopTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    /// Bumped on every token change / sign-out. A refresh started under an old
    /// token discards its results if the epoch moved (no cross-account leakage).
    private var epoch = 0
    /// First refresh seeds `previousPRs` WITHOUT notifying — otherwise a fresh
    /// launch would fire a notification for every existing waiting PR.
    private var firstPass = true
    /// Poll cadence in seconds, user-configurable (15m/1h/3h/1d). Default 15m —
    /// all options stay well under the search API's 30/min.
    private(set) var refreshIntervalSecs: Int = 900

    /// StatusController subscribes here to rebuild the menu + badge.
    var onChange: (@MainActor () -> Void)?
    /// Fired with a PR id when its review comments or commits finish loading, so
    /// the controller can repopulate just that submenu (no full menu rebuild).
    var onSubmenuReload: (@MainActor (String) -> Void)?

    // Review comments + commits are fetched on demand (submenu open), never in the
    // loop. Caches capture the GitHubClient actor (not self) so the fetch closures
    // are @Sendable — initialized in init once `client` exists.
    private let commentsCache: PerPRLazyCache<[ReviewComment]>
    private let commitsCache: PerPRLazyCache<[Commit]>

    // Views. `needsMe` drives the red badge, so muted PRs drop out of it.
    var needsMe: [PullRequest] { state.pullRequests.filter { $0.waitingOnMe && !isMuted($0) } }
    var mine: [PullRequest] { state.pullRequests.filter { $0.author == viewer?.login } }
    var all: [PullRequest] { state.pullRequests }
    var muted: [PullRequest] { state.pullRequests.filter(isMuted) }
    var lastUpdated: Date? { state.lastUpdated }

    // MARK: - Mute / snooze (local triage, no API)
    func isMuted(_ pr: PullRequest) -> Bool { state.isMuted(pr, now: Date()) }
    /// Snooze for a fixed window (e.g. 1h, 4h).
    func mute(_ pr: PullRequest, for interval: TimeInterval) {
        state.mutes[pr.id] = Mute(updatedAtSnapshot: pr.updatedAt, until: Date().addingTimeInterval(interval))
        saveState(); onChange?()
    }
    /// Hide until the PR changes (its `updatedAt` moves).
    func muteUntilUpdated(_ pr: PullRequest) {
        state.mutes[pr.id] = Mute(updatedAtSnapshot: pr.updatedAt, until: nil)
        saveState(); onChange?()
    }
    func unmute(_ pr: PullRequest) {
        guard state.mutes.removeValue(forKey: pr.id) != nil else { return }
        saveState(); onChange?()
    }
    /// Drop mutes for PRs that are gone or whose snooze has lapsed — keeps the
    /// dictionary from growing without bound.
    private func pruneMutes(against prs: [PullRequest]) {
        let now = Date()
        let byID = Dictionary(prs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        state.mutes = state.mutes.filter { id, m in
            guard let pr = byID[id] else { return false }
            return m.active(for: pr, now: now)
        }
    }

    // Repo filter (UI: "Filter repos" submenu). `state.filters` empty == all repos.
    var repoFilters: [String] { state.filters }
    /// Repos to offer in the picker: every repo seen this session, plus current
    /// PRs and active filters. Accumulator means a repo you uncheck (and thus
    /// filter out of results) still shows so you can toggle it back on.
    /// ponytail: in-memory, reseeded from cached PRs on launch — a repo unchecked
    /// before quit won't list until "All repos" refetches it. Persist seenRepos
    /// if that matters.
    var knownRepos: [String] {
        seenRepos.union(state.pullRequests.map(\.repoFullName)).union(state.filters).sorted()
    }
    /// Selecting every known repo == no filter. Normalize so the badge query
    /// drops the `repo:` qualifiers (cheaper, and "All" reads clean).
    func setRepoFilters(_ repos: [String]) {
        let normalized = Set(repos) == Set(knownRepos) ? [] : repos.sorted()
        guard normalized != state.filters else { return }
        state.filters = normalized
        saveState()
        kickRefresh()
    }

    init() {
        self.tokenStore = KeychainTokenStore()
        self.store = JSONStore(url: JSONStore.defaultURL())
        self.state = store.load()                 // instant cached PRs on launch
        self.previousPRs = state.pullRequests
        self.seenRepos = Set(state.pullRequests.map(\.repoFullName))
        self.theme = UserDefaults.standard.string(forKey: "theme").flatMap(Theme.init) ?? .system
        self.palette = theme.palette
        Theme.apply(theme)
        if let secs = UserDefaults.standard.object(forKey: "refreshIntervalSecs") as? Int, secs > 0 {
            self.refreshIntervalSecs = secs
        }
        let token: String?
        let readOK: Bool
        do { token = try tokenStore.read(); readOK = true }
        catch { token = nil; readOK = false }   // Keychain locked at launch
        self.tokenKnown = readOK
        self.hasToken = readOK && token != nil
        self.client = GitHubClient(transport: URLSessionTransport(), token: token)
        self.engine = RefreshEngine(client: client)
        let client = self.client   // capture the actor, not self, for the @Sendable fetch closures
        self.commentsCache = PerPRLazyCache { o, r, n in
            (try? await client.reviewThread(owner: o, repo: r, number: n)) ?? []
        }
        self.commitsCache = PerPRLazyCache { o, r, n in
            (try? await client.commits(owner: o, repo: r, number: n)) ?? []
        }
        // Locked (readOK false) -> .loading so the loop retries; don't claim signed-out.
        self.status = (readOK && token == nil) ? .signedOut : .loading
    }

    func start() {
        notifier.onOpen = { url in NSWorkspace.shared.open(url) }
        // Wake / reconnect RESTART the loop (not a one-shot) — else periodic
        // polling dies after the first sleep.
        lifecycle.onWake = { [weak self] in self?.startLoop() }
        lifecycle.onNetworkSatisfied = { [weak self] in self?.startLoop() }
        lifecycle.onSleep = { [weak self] in self?.loopTask?.cancel() }
        lifecycle.start()
        notifier.requestAuthorizationIfNeeded()
        startLoop()
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshNow()
                try? await Task.sleep(nanoseconds: self.nextSleepNanos())
            }
        }
    }

    /// Back off until the rate-limit reset when limited; otherwise normal cadence.
    private func nextSleepNanos() -> UInt64 {
        if case .rateLimited(let until) = status, let until {
            let secs = max(until.timeIntervalSinceNow, 5)
            return UInt64(secs * 1_000_000_000)
        }
        return UInt64(refreshIntervalSecs) * 1_000_000_000
    }

    func kickRefresh() { Task { await refreshNow() } }

    func refreshNow() async {
        if !tokenKnown {   // launch read was blocked (Keychain locked) — retry, don't re-read once known
            do {
                let t = try tokenStore.read()
                hasToken = t != nil; tokenKnown = true
                if let t { await client.setToken(t) }   // deliver it: client was built token-less on a locked launch
            } catch { setStatus(.error("Keychain locked — unlock to refresh")); return }
        }
        guard hasToken else { setStatus(.signedOut); return }
        guard lifecycle.networkAvailable else { setStatus(.offline); return }
        guard !refreshing else { return }     // single-flight: coalesce overlapping ticks
        refreshing = true
        defer { refreshing = false }
        let myEpoch = epoch                   // detect token change mid-flight
        if status != .loaded { setStatus(.loading) }

        do {
            let fetchedViewer: ViewerContext?
            let prs: [PullRequest]
            if let v = viewer {
                fetchedViewer = v
                prs = try await engine.refresh(filters: state.filters, viewer: v)
            } else {
                let (v, p) = try await engine.refresh(filters: state.filters)
                fetchedViewer = v; prs = p
            }
            guard myEpoch == epoch else { return }   // token changed -> discard stale (no leakage)
            if let v = fetchedViewer { viewer = v }
            if let login = viewer?.login, !firstPass {
                // Don't notify for snoozed PRs (the whole point of a snooze).
                let mutedIDs = Set(prs.filter { state.isMuted($0, now: Date()) }.map(\.id))
                let events = NotificationPlanner.events(previous: previousPRs, current: prs, viewerLogin: login)
                    .filter { !mutedIDs.contains($0.prID) }
                notifier.deliver(events)
            }
            firstPass = false
            previousPRs = prs
            state.pullRequests = prs
            pruneMutes(against: prs)
            seenRepos.formUnion(prs.map(\.repoFullName))   // remember repos even after they're filtered out
            state.lastUpdated = Date()
            saveState()
            setStatus(.loaded)
        } catch {
            guard myEpoch == epoch else { return }   // don't clobber status after a token change
            switch error {
            case GitHubError.rateLimited(let until): setStatus(.rateLimited(until: until))
            case GitHubError.unauthorized:           setStatus(.signedOut)
            case GitHubError.network:                setStatus(.offline)
            default:                                 setStatus(.error("\(error)"))
            }
        }
    }

    // MARK: - Review comments + commits (lazy, per-PR)
    // nil from value(for:) = not loaded yet; non-nil = loaded (may be empty).

    func comments(for pr: PullRequest) -> [ReviewComment]? { commentsCache.value(for: pr) }
    func isLoadingComments(_ pr: PullRequest) -> Bool { commentsCache.isLoading(pr) }
    func loadComments(for pr: PullRequest) {
        commentsCache.load(pr, epoch: self.epoch) { [weak self] id in self?.onSubmenuReload?(id) }
    }

    func commits(for pr: PullRequest) -> [Commit]? { commitsCache.value(for: pr) }
    func isLoadingCommits(_ pr: PullRequest) -> Bool { commitsCache.isLoading(pr) }
    func loadCommits(for pr: PullRequest) {
        commitsCache.load(pr, epoch: self.epoch) { [weak self] id in self?.onSubmenuReload?(id) }
    }

    func setTheme(_ t: Theme) {
        theme = t
        palette = t.palette
        UserDefaults.standard.set(t.rawValue, forKey: "theme")
        Theme.apply(t)
        onChange?()   // re-render with the new palette
    }

    func setRefreshInterval(_ secs: Int) {
        guard secs > 0, secs != refreshIntervalSecs else { return }
        refreshIntervalSecs = secs
        UserDefaults.standard.set(secs, forKey: "refreshIntervalSecs")
        startLoop()   // restart so the new cadence takes effect immediately
        onChange?()
    }

    private func setStatus(_ s: AppStatus) { status = s; onChange?() }
    private func saveState() {
        do { try store.save(state) } catch { /* disk-full etc: cache is best-effort, keep running */ }
    }

    // MARK: - Auth

    func pastePAT(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try tokenStore.save(trimmed) }
        catch { setStatus(.error("Couldn't save token to Keychain.")); return }
        tokenKnown = true; hasToken = true
        beginNewSession()
        Task { await client.setToken(trimmed); startLoop() }
    }

    func signInWithDeviceFlow() {
        guard !Self.clientID.isEmpty else {
            setStatus(.error("No client id — register an OAuth App (Settings ▸ Developer settings), "
                             + "set PRPeekClientID, or just Paste token.")); return
        }
        guard signInTask == nil else { return }   // re-entrancy guard: one sign-in at a time
        let flow = DeviceFlowAuth(transport: URLSessionTransport(), clientID: Self.clientID)
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.signInTask = nil }
            do {
                // Classic device flow has no read-only private-repo scope: `repo`
                // is the minimum that lets search see private PRs, but it also
                // grants write. The least-privilege path is a read-only
                // fine-grained PAT via "Paste token…" (see pasteToken copy).
                // read:org powers /user/teams for team-review (CODEOWNERS) PRs.
                let token = try await flow.authorize(scope: "repo read:org", onCode: { code in
                    Task { @MainActor in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                        self.setStatus(.authorizing(code: code.userCode))
                        if let url = code.bestVerificationURL { NSWorkspace.shared.open(url) }
                    }
                })
                do { try self.tokenStore.save(token) }
                catch { self.setStatus(.error("Couldn't save token to Keychain.")); return }
                self.tokenKnown = true; self.hasToken = true
                self.beginNewSession()
                await self.client.setToken(token)
                self.startLoop()
            } catch DeviceFlowAuth.DeviceFlowError.denied {
                self.setStatus(.error("Authorization denied."))
            } catch DeviceFlowAuth.DeviceFlowError.expired {
                self.setStatus(.error("Code expired — try Sign in again."))
            } catch is CancellationError {
                // sign-out cancelled it; no status change
            } catch {
                self.setStatus(.error("Sign-in failed: \(error)"))
            }
        }
    }

    func signOut() {
        signInTask?.cancel(); signInTask = nil
        beginNewSession()
        tokenKnown = true; hasToken = false
        do { try tokenStore.delete() } catch { /* best effort; in-memory token cleared below */ }
        previousPRs = []
        state.pullRequests = []
        saveState()
        Task { await client.setToken(nil) }
        loopTask?.cancel()
        setStatus(.signedOut)
    }

    /// Mark a token boundary: invalidate in-flight refreshes, reset identity, and
    /// suppress the next pass's notifications.
    private func beginNewSession() {
        epoch += 1
        viewer = nil
        firstPass = true
        commentsCache.reset(); commitsCache.reset()   // account-scoped
    }
}
