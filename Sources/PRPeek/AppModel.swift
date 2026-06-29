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
    private var viewer: ViewerContext?
    private var previousPRs: [PullRequest] = []
    private var refreshing = false
    private var loopTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    /// Bumped on every token change / sign-out. A refresh started under an old
    /// token discards its results if the epoch moved (no cross-account leakage).
    private var epoch = 0
    /// First refresh seeds `previousPRs` WITHOUT notifying — otherwise a fresh
    /// launch would fire a notification for every existing waiting PR.
    private var firstPass = true
    private let interval: UInt64 = 180 * 1_000_000_000   // 3 min, well under search 30/min

    /// StatusController subscribes here to rebuild the menu + badge.
    var onChange: (@MainActor () -> Void)?

    // Views
    var needsMe: [PullRequest] { state.pullRequests.filter(\.waitingOnMe) }
    var mine: [PullRequest] { state.pullRequests.filter { $0.author == viewer?.login } }
    var all: [PullRequest] { state.pullRequests }
    var lastUpdated: Date? { state.lastUpdated }

    init() {
        self.tokenStore = KeychainTokenStore()
        self.store = JSONStore(url: JSONStore.defaultURL())
        self.state = store.load()                 // instant cached PRs on launch
        self.previousPRs = state.pullRequests
        let token = try? tokenStore.read()
        self.client = GitHubClient(transport: URLSessionTransport(), token: token)
        self.engine = RefreshEngine(client: client)
        self.status = (token == nil) ? .signedOut : .loading
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
        return interval
    }

    func kickRefresh() { Task { await refreshNow() } }

    func refreshNow() async {
        guard (try? tokenStore.read()) != nil else { setStatus(.signedOut); return }
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
                notifier.deliver(NotificationPlanner.events(previous: previousPRs, current: prs, viewerLogin: login))
            }
            firstPass = false
            previousPRs = prs
            state.pullRequests = prs
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
    }
}
