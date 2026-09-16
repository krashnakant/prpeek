import AppKit
import ServiceManagement
import PRPeekCore

/// The brain. Owns state, the refresh loop, auth, and lifecycle wiring. Drives
/// the menubar via `onChange`. @MainActor: all UI-facing state stays on main;
/// only the GitHubClient actors + engines run off it.
///
/// Multi-account: every per-identity thing lives in an `AccountSession`; this
/// type fans a refresh out across them and merges the results into one list.
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

    private let store: JSONStore
    private let notifier = NotificationService()
    private let lifecycle = LifecycleMonitor()

    private(set) var sessions: [AccountSession] = []
    private(set) var state: PRPeekState
    private(set) var status: AppStatus = .signedOut(reason: nil)
    private(set) var theme: Theme = .system
    /// Parsed once per theme change, not re-derived on every menu render (the
    /// Catppuccin palette parses 7 hex strings).
    private(set) var palette: Palette?
    private var seenRepos: Set<String> = []   // every repo seen this session (for the filter picker)
    private var refreshing = false
    private var refreshPending = false   // a tick arrived mid-refresh; run once more after
    private var loopTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    /// Bumped on every token change / account add / removal. A refresh started
    /// under an old token discards its results if the epoch moved.
    /// ponytail: one global epoch — removing account B redundantly invalidates
    /// account A's in-flight pass. Costs one refresh, never correctness; make it
    /// per-session if that ever shows up.
    private var epoch = 0
    /// Poll cadence in seconds, user-configurable (15m/1h/3h/1d). Default 15m —
    /// all options stay well under the search API's 30/min.
    private(set) var refreshIntervalSecs: Int = 900

    /// StatusController subscribes here to rebuild the menu + badge.
    var onChange: (@MainActor () -> Void)?
    /// Fired with a PR id when its review comments or commits finish loading, so
    /// the controller can repopulate just that submenu (no full menu rebuild).
    var onSubmenuReload: (@MainActor (String) -> Void)?
    /// Fired with a PR key when its file diffs finish loading.
    var onFilesLoaded: (@MainActor (String) -> Void)?

    // Views. `needsMe` drives the red badge, so muted PRs drop out of it.
    var needsMe: [PullRequest] { state.pullRequests.filter { $0.waitingOnMe && !isMuted($0) } }
    var mine: [PullRequest] { state.pullRequests.filter(\.isMine) }
    var all: [PullRequest] { state.pullRequests }
    var muted: [PullRequest] { state.pullRequests.filter(isMuted) }
    var lastUpdated: Date? { state.lastUpdated }
    var accounts: [Account] { sessions.map(\.account) }

    // MARK: - Accounts

    func session(for pr: PullRequest) -> AccountSession? {
        sessions.first { $0.account.id == pr.accountID }
    }
    /// nil with a single account: the UI only spends space on an account tag
    /// once it actually disambiguates something.
    func accountLabel(for pr: PullRequest) -> String? {
        guard sessions.count > 1 else { return nil }
        return session(for: pr)?.displayName
    }

    /// Add an identity and immediately store its token. GHES accounts come
    /// through here only: device flow needs an OAuth App registered on that host,
    /// which a distributed build can't have, so enterprise sign-in is PAT-only.
    func addAccount(label: String, host: String, token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                              label: name.isEmpty ? "GitHub" : name)
        let session = AccountSession(account: account)
        do { try session.save(token: trimmed) }
        catch { setStatus(.error("Couldn't save token to Keychain.")); return }
        AppLog.appModel.info("Account added host=\(account.displayHost, privacy: .public)")
        sessions.append(session)
        state.accounts = accounts
        epoch += 1
        saveState()
        startLoop()
    }

    func removeAccount(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.account.id == id }) else { return }
        AppLog.appModel.info("Account removed")
        sessions[idx].signOut()
        sessions.remove(at: idx)
        epoch += 1
        state.forget(account: id)
        saveState()
        if sessions.isEmpty { loopTask?.cancel(); setStatus(.signedOut(reason: nil)) }
        onChange?()
    }

    /// Remove every account (the old "Sign out"). Not a loop over
    /// `removeAccount`: that would write the state file and rebuild the menu once
    /// per account, each time re-serializing rows about to be dropped anyway.
    func signOutAll() {
        AppLog.appModel.info("Signing out of every account")
        signInTask?.cancel(); signInTask = nil
        sessions.forEach { $0.signOut() }
        sessions = []
        epoch += 1
        state.accounts = []; state.pullRequests = []
        state.mutes = [:]; state.seen = [:]; state.waitingSince = [:]
        loopTask?.cancel()
        saveState()
        setStatus(.signedOut(reason: nil))
    }

    // MARK: - Freshness (new / seen / stale / re-review)

    /// nil = not waiting on you, so no freshness marker.
    func freshness(_ pr: PullRequest) -> PRFreshness? {
        Freshness.state(for: pr, seen: state.seen[pr.key],
                        waitingSince: state.waitingSince[pr.key], now: Date())
    }

    /// The user looked at this PR — opened it in the browser, or opened its
    /// submenu to read the reviews. Flips `.new` to `.seen`.
    func markSeen(_ pr: PullRequest) {
        guard state.seen[pr.key] == nil else { return }
        state.seen[pr.key] = Date()
        scheduleSave()   // hovering down a section marks every row: coalesce the writes
        onChange?()
    }

    /// Open a PR and count it as seen — the one path the UI should use, so no
    /// surface can open a PR without clearing its "new" marker.
    func open(_ pr: PullRequest) {
        markSeen(pr)
        NSWorkspace.shared.openSafeWebURL(pr.htmlURL)
    }

    // MARK: - Mute / snooze (local triage, no API)
    func isMuted(_ pr: PullRequest) -> Bool { state.isMuted(pr, now: Date()) }
    /// Snooze for a fixed window (e.g. 1h, 4h).
    func mute(_ pr: PullRequest, for interval: TimeInterval) {
        AppLog.appModel.info("Muted PR for seconds=\(Int(interval), privacy: .public)")
        state.mutes[pr.key] = Mute(updatedAtSnapshot: pr.updatedAt, until: Date().addingTimeInterval(interval))
        saveState(); onChange?()
    }
    /// Hide until the PR changes (its `updatedAt` moves).
    func muteUntilUpdated(_ pr: PullRequest) {
        AppLog.appModel.info("Muted PR until update")
        state.mutes[pr.key] = Mute(updatedAtSnapshot: pr.updatedAt, until: nil)
        saveState(); onChange?()
    }
    func unmute(_ pr: PullRequest) {
        guard state.mutes.removeValue(forKey: pr.key) != nil else { return }
        AppLog.appModel.info("Unmuted PR")
        saveState(); onChange?()
    }

    // MARK: - Launch at login (SMAppService — no helper bundle needed)
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            AppLog.appModel.info("Launch at login changed enabled=\(on, privacy: .public)")
        } catch {
            AppLog.appModel.error("Launch at login change failed: \(String(describing: error), privacy: .private)")
            setStatus(.error("Login item failed: \(error.localizedDescription)"))
        }
        onChange?()
    }

    // MARK: - Menubar Badge Preferences
    var hideCalmCount: Bool {
        UserDefaults.standard.bool(forKey: "hideCalmCount")
    }
    func setHideCalmCount(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hideCalmCount")
        AppLog.appModel.info("Hide calm count changed enabled=\(on, privacy: .public)")
        onChange?()
    }

    var useDotBadge: Bool {
        UserDefaults.standard.bool(forKey: "useDotBadge")
    }
    func setUseDotBadge(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "useDotBadge")
        AppLog.appModel.info("Use dot badge changed enabled=\(on, privacy: .public)")
        onChange?()
    }

    var globalHotkeysEnabled: Bool {
        GlobalHotkeyManager.shared.isEnabled
    }
    func setGlobalHotkeysEnabled(_ on: Bool) {
        GlobalHotkeyManager.shared.setEnabled(on)
        onChange?()
    }
    // Repo filter (UI: "Filter repos" submenu). `state.filters` empty == all repos.
    // ponytail: one global list across accounts — a `repo:` qualifier naming a
    // repo an account can't see just matches nothing there, so no per-account
    // wiring is needed until someone has same-named repos on two hosts.
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
        AppLog.appModel.info("Repo filters changed count=\(normalized.count, privacy: .public)")
        saveState()
        kickRefresh()
    }

    init() {
        self.store = JSONStore(url: JSONStore.defaultURL())
        self.state = store.load()                 // instant cached PRs on launch
        // Pre-multi-account install: adopt the existing token and cache as the
        // primary account instead of dropping the user at a sign-in screen.
        let legacyHost = UserDefaults.standard.string(forKey: "githubHost") ?? ""
        state.migrate(adopting: Account(id: Account.primaryID, host: legacyHost, label: "GitHub"))
        self.seenRepos = Set(state.pullRequests.map(\.repoFullName))
        self.theme = UserDefaults.standard.string(forKey: "theme").flatMap(Theme.init) ?? .system
        self.palette = theme.palette
        Theme.apply(theme)
        if let secs = UserDefaults.standard.object(forKey: "refreshIntervalSecs") as? Int, secs > 0 {
            self.refreshIntervalSecs = secs
        }
        let cached = Dictionary(grouping: state.pullRequests, by: \.accountID)
        self.sessions = state.accounts.map { AccountSession(account: $0, cachedPRs: cached[$0.id] ?? []) }
        self.status = AppStatus.aggregate(sessions.map(\.status))
    }

    func start() {
        AppLog.appModel.info("App model starting")
        notifier.onOpen = { url in NSWorkspace.shared.openSafeWebURL(url) }
        notifier.onSnoozePRKey = { [weak self] prKey in
            guard let self, let pr = self.all.first(where: { $0.key == prKey }) else { return }
            self.mute(pr, for: 3600)
        }
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
        AppLog.appModel.debug("Refresh loop starting intervalSeconds=\(self.refreshIntervalSecs, privacy: .public)")
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshNow()
                try? await Task.sleep(nanoseconds: self.nextSleepNanos())
            }
        }
    }

    /// Back off until the rate-limit reset when all active accounts are limited; otherwise normal cadence.
    private func nextSleepNanos() -> UInt64 {
        let activeSessions = sessions.filter { !$0.status.isSignedOut }
        if !activeSessions.isEmpty && activeSessions.allSatisfy({ if case .rateLimited = $0.status { true } else { false } }) {
            let resets = activeSessions.compactMap { session -> Date? in
                if case .rateLimited(let until) = session.status { return until }
                return nil
            }
            if let earliest = resets.min() {
                let secs = max(earliest.timeIntervalSinceNow, 5)
                return UInt64(secs * 1_000_000_000)
            }
        }
        return UInt64(refreshIntervalSecs) * 1_000_000_000
    }

    func kickRefresh() { Task { await refreshNow() } }

    func refreshNow() async {
        AppLog.appModel.debug("Refresh requested status=\(self.status.logName, privacy: .public)")
        guard !sessions.isEmpty else { setStatus(.signedOut(reason: nil)); return }
        guard lifecycle.networkAvailable else { setStatus(.offline); return }
        guard !refreshing else {
            AppLog.appModel.debug("Refresh queued because another refresh is active")
            refreshPending = true   // e.g. wake poll landing on a timer tick — don't drop it
            return
        }     // single-flight: coalesce overlapping ticks
        refreshing = true
        defer {
            refreshing = false
            if refreshPending {
                refreshPending = false
                Task { await self.refreshNow() }
            }
        }
        let myEpoch = epoch                   // detect account/token change mid-flight
        if status != .loaded { setStatus(.loading) }

        // Each account refreshes independently: one rate-limited or broken
        // account must not blank the others' PRs.
        // Accounts are independent — separate tokens, often separate hosts — and
        // GitHub's rate limits are per-token, so overlapping them costs nothing
        // and makes a pass take as long as the slowest account, not all of them.
        // Each engine still self-caps its own fan-out.
        var events: [NotificationEvent] = []
        var merged: [PullRequest] = []
        let running = sessions.map { session in
            (session, Task { await self.refresh(session) })
        }
        for (session, task) in running {
            let prs = await task.value
            merged += prs
            events += pendingEvents(for: session, current: prs)
            session.previousPRs = prs
            session.firstPass = false
        }
        guard myEpoch == epoch else { return }   // account set changed -> discard stale

        let now = Date()
        // Don't notify for still-snoozed PRs (the whole point of a snooze)...
        let mutedKeys = Set(merged.filter { state.isMuted($0, now: now) }.map(\.key))
        var out = events.filter { !mutedKeys.contains($0.prKey) }
        // ...but a "hide until updated" mute that just cleared re-notifies once.
        // Read mutes BEFORE pruneMutes drops the cleared entry.
        var seenIDs = Set(out.map(\.id))
        for e in NotificationPlanner.resurfacedMutes(current: merged, mutes: state.mutes, now: now)
        where !seenIDs.contains(e.id) { seenIDs.insert(e.id); out.append(e) }
        notifier.deliver(out)

        state.pullRequests = merged
        state.prune(against: merged, now: now)
        seenRepos.formUnion(merged.map(\.repoFullName))   // remember repos even after they're filtered out
        state.lastUpdated = now
        saveState()
        AppLog.appModel.debug(
            "Refresh finished total=\(merged.count, privacy: .public) notifications=\(out.count, privacy: .public)"
        )
        setStatus(AppStatus.aggregate(sessions.map(\.status)))
    }

    /// One account's pass. Never throws: a failure is recorded on the session's
    /// own status and its last-known PRs are kept, so the merged list degrades
    /// per account instead of all at once.
    private func refresh(_ session: AccountSession) async -> [PullRequest] {
        if case .rateLimited(let until) = session.status, let until, until > Date() {
            AppLog.appModel.debug("Account rate-limited; skipping poll until reset")
            return session.previousPRs
        }
        guard await session.resolveTokenIfNeeded() else {
            AppLog.appModel.error("Refresh blocked by Keychain read failure")
            session.status = .error("Keychain locked — unlock to refresh")
            return session.previousPRs
        }
        guard session.hasToken else {
            session.status = .signedOut(reason: nil)
            return []
        }
        do {
            let prs: [PullRequest]
            if let v = session.viewer {
                prs = try await session.engine.refresh(filters: state.filters, viewer: v,
                                                       previous: session.previousPRs)
            } else {
                let (v, fetched) = try await session.engine.refresh(filters: state.filters,
                                                                    previous: session.previousPRs)
                session.viewer = v
                prs = fetched
            }
            session.status = .loaded   // both paths: a good pass clears a stale error
            return prs
        } catch is CancellationError {
            // Loop restart (interval change) cancelled us mid-flight — the new loop
            // refreshes immediately; don't flash an error/offline status.
            return session.previousPRs
        } catch {
            AppLog.appModel.error("Refresh failed: \(String(describing: error), privacy: .private)")
            switch error {
            case GitHubError.rateLimited(let until): session.status = .rateLimited(until: until)
            case GitHubError.unauthorized:
                session.status = .signedOut(reason: "GitHub rejected the token (expired or revoked?) — sign in again")
            case GitHubError.network:                session.status = .offline
            default:                                 session.status = .error("\(error)")
            }
            return session.previousPRs
        }
    }

    /// Edge-triggered notifications for one account, suppressed on its first pass
    /// (a fresh launch, or a just-added account, must not fire for every PR that
    /// was already waiting).
    private func pendingEvents(for session: AccountSession, current: [PullRequest]) -> [NotificationEvent] {
        guard !session.firstPass else { return [] }
        return NotificationPlanner.events(previous: session.previousPRs, current: current)
    }

    // MARK: - Review comments + commits (lazy, per-PR, routed to the PR's account)
    // nil from value(for:) = not loaded yet; non-nil = loaded (may be empty).

    func comments(for pr: PullRequest) -> [ReviewComment]? { session(for: pr)?.commentsCache.value(for: pr) }
    func isLoadingComments(_ pr: PullRequest) -> Bool { session(for: pr)?.commentsCache.isLoading(pr) ?? false }
    func loadComments(for pr: PullRequest) {
        session(for: pr)?.commentsCache.load(pr, epoch: self.epoch) { [weak self] id in self?.onSubmenuReload?(id) }
    }

    func commits(for pr: PullRequest) -> [Commit]? { session(for: pr)?.commitsCache.value(for: pr) }
    func isLoadingCommits(_ pr: PullRequest) -> Bool { session(for: pr)?.commitsCache.isLoading(pr) ?? false }
    func loadCommits(for pr: PullRequest) {
        session(for: pr)?.commitsCache.load(pr, epoch: self.epoch) { [weak self] id in self?.onSubmenuReload?(id) }
    }

    func files(for pr: PullRequest) -> [PullRequestFile]? { session(for: pr)?.filesCache.value(for: pr) }
    func isLoadingFiles(_ pr: PullRequest) -> Bool { session(for: pr)?.filesCache.isLoading(pr) ?? false }
    func loadFiles(for pr: PullRequest, onLoaded: (@MainActor ([PullRequestFile]) -> Void)? = nil) {
        session(for: pr)?.filesCache.load(pr, epoch: self.epoch) { [weak self] id in
            self?.onFilesLoaded?(id)
            if let files = self?.files(for: pr) {
                onLoaded?(files)
            }
        }
    }

    // MARK: - Write actions (the only calls that change anything on GitHub)
    // Each returns nil on success or a sentence to show the user. Failures do NOT
    // go through `status`: that badge reports the refresh loop's health, and a
    // rejected merge the user just asked for is not a broken app.

    /// Merge the PR, pinned to the head commit currently in the menu.
    func merge(_ pr: PullRequest, method: MergeMethod) async -> String? {
        guard let client = session(for: pr)?.client else { return "No account for this PR." }
        guard let sha = pr.headSHA else { return "No head commit known yet — refresh and try again." }
        let (owner, repo) = pr.ownerRepo
        AppLog.appModel.info("Merge requested method=\(method.rawValue, privacy: .public)")
        return await perform {
            try await client.merge(owner: owner, repo: repo, number: pr.number, headSHA: sha, method: method)
        }
    }

    /// Ask `login` to look again. See `GitHubClient.requestReview` — same endpoint
    /// as a first request, because GitHub un-requests a reviewer when they submit.
    func requestReview(_ pr: PullRequest, from login: String) async -> String? {
        guard let client = session(for: pr)?.client else { return "No account for this PR." }
        let (owner, repo) = pr.ownerRepo
        AppLog.appModel.info("Re-review requested")
        return await perform {
            try await client.requestReview(owner: owner, repo: repo, number: pr.number, reviewers: [login])
        }
    }

    /// Post a reply to one review comment, then drop the cached thread so the
    /// submenu refetches it (the reply is now part of it).
    func reply(to comment: ReviewComment, on pr: PullRequest, body: String) async -> String? {
        guard let session = session(for: pr) else { return "No account for this PR." }
        let (owner, repo) = pr.ownerRepo
        AppLog.appModel.info("Reply requested threaded=\(comment.inlineCommentID != nil, privacy: .public)")
        let failure = await perform {
            try await session.client.reply(owner: owner, repo: repo, number: pr.number, to: comment, body: body)
        }
        if failure == nil { session.commentsCache.reset() }
        return failure
    }

    /// Who could be asked to look again: everyone who has already reviewed, minus
    /// you. Read straight off the cached thread — no extra request.
    func pastReviewers(of pr: PullRequest) -> [String] {
        guard let comments = comments(for: pr) else { return [] }
        let me = session(for: pr)?.viewer?.login
        var seen = Set<String>()
        return comments.map(\.author).filter { $0 != "?" && $0 != me && seen.insert($0).inserted }
    }

    /// Run a write, refresh so the menu reflects it, translate any failure.
    private func perform(_ op: () async throws -> Void) async -> String? {
        do {
            try await op()
            kickRefresh()
            return nil
        } catch {
            AppLog.appModel.error("Write action failed: \(String(describing: error), privacy: .private)")
            return Self.failureText(error)
        }
    }

    /// A write failure is something the user just asked for, so it gets a
    /// sentence with a remedy — not the enum case dumped into a status row.
    static func failureText(_ error: Error) -> String {
        switch error {
        case GitHubError.unauthorized:
            return "GitHub rejected the token (expired or revoked?) — sign in again."
        case GitHubError.forbidden:
            // Covers both halves of "no": a read-only token, or a repo you can't
            // push to. GitHub answers 403/404 for either, so say both.
            return "No write access. The token needs Pull requests: Write (fine-grained) or repo "
                 + "(classic), and the account needs write access to this repository."
        case GitHubError.rateLimited:
            return "GitHub is rate-limiting this account — try again in a few minutes."
        case GitHubError.rejected(_, let message) where !message.isEmpty:
            return message                      // GitHub's own sentence beats ours
        case GitHubError.network:
            return "No network."
        default:
            return "Failed: \(error)"
        }
    }

    func setTheme(_ t: Theme) {
        theme = t
        palette = t.palette
        UserDefaults.standard.set(t.rawValue, forKey: "theme")
        Theme.apply(t)
        AppLog.appModel.info("Theme changed")
        onChange?()   // re-render with the new palette
    }

    func setRefreshInterval(_ secs: Int) {
        guard secs > 0, secs != refreshIntervalSecs else { return }
        refreshIntervalSecs = secs
        UserDefaults.standard.set(secs, forKey: "refreshIntervalSecs")
        AppLog.appModel.info("Refresh interval changed seconds=\(secs, privacy: .public)")
        startLoop()   // restart so the new cadence takes effect immediately
        onChange?()
    }

    private func setStatus(_ s: AppStatus) {
        if status != s {
            AppLog.appModel.debug(
                "Status changed from=\(self.status.logName, privacy: .public) to=\(s.logName, privacy: .public)"
            )
        }
        status = s
        onChange?()
    }
    private func saveState() {
        saveScheduled = false
        do { try store.save(state) } catch { /* disk-full etc: cache is best-effort, keep running */ }
    }

    private var saveScheduled = false
    /// Coalesce a burst of small edits into one write. Walking down the menu
    /// marks each PR seen in turn; without this that's one full encode + atomic
    /// rename of the whole state file per row, on the main actor, during menu
    /// tracking.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard saveScheduled else { return }   // a full save already flushed it
            saveState()
        }
    }

    // MARK: - Auth

    /// Device flow, github.com only. A GHES host needs an OAuth App registered on
    /// that host, which a distributed build has no id for — enterprise accounts
    /// come in through `addAccount(label:host:token:)` with a PAT instead.
    func signInWithDeviceFlow() {
        guard !Self.clientID.isEmpty else {
            setStatus(.error("No client id — register an OAuth App (Settings ▸ Developer settings), "
                             + "set PRPeekClientID, or just Paste token.")); return
        }
        guard signInTask == nil else { return }   // re-entrancy guard: one sign-in at a time
        AppLog.appModel.info("Device sign-in started")
        let flow = DeviceFlowAuth(transport: URLSessionTransport(), clientID: Self.clientID,
                                  webBaseURL: GitHubClient.webBase(forHost: ""))
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
                        if let url = code.bestVerificationURL { NSWorkspace.shared.openSafeWebURL(url) }
                    }
                })
                AppLog.appModel.info("Device sign-in completed")
                self.addAccount(label: "GitHub", host: "", token: token)
            } catch DeviceFlowAuth.DeviceFlowError.denied {
                AppLog.appModel.error("Device sign-in denied")
                self.setStatus(.error("Authorization denied."))
            } catch DeviceFlowAuth.DeviceFlowError.expired {
                AppLog.appModel.error("Device sign-in expired")
                self.setStatus(.error("Code expired — try Sign in again."))
            } catch is CancellationError {
                // sign-out cancelled it; no status change
            } catch {
                AppLog.appModel.error("Device sign-in failed: \(String(describing: error), privacy: .private)")
                self.setStatus(.error("Sign-in failed: \(error)"))
            }
        }
    }
}

extension NSWorkspace {
    /// Opens a web URL only if the scheme is https or http, protecting against
    /// arbitrary scheme execution (file://, terminal://, applescript://, etc.).
    @discardableResult
    func openSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        return open(url)
    }
}
