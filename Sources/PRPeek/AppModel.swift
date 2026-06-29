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
        lifecycle.onWake = { [weak self] in self?.kickRefresh() }
        lifecycle.onNetworkSatisfied = { [weak self] in self?.kickRefresh() }
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
                try? await Task.sleep(nanoseconds: self.interval)
            }
        }
    }

    func kickRefresh() { Task { await refreshNow() } }

    func refreshNow() async {
        guard (try? tokenStore.read()) != nil else { setStatus(.signedOut); return }
        guard lifecycle.networkAvailable else { setStatus(.offline); return }
        guard !refreshing else { return }     // single-flight: coalesce overlapping ticks
        refreshing = true
        defer { refreshing = false }
        if status != .loaded { setStatus(.loading) }

        do {
            let prs: [PullRequest]
            if let v = viewer {
                prs = try await engine.refresh(filters: state.filters, viewer: v)
            } else {
                let (v, p) = try await engine.refresh(filters: state.filters)
                viewer = v; prs = p
            }
            // notifications on transitions, then persist + publish
            if let login = viewer?.login {
                notifier.deliver(NotificationPlanner.events(previous: previousPRs, current: prs, viewerLogin: login))
            }
            previousPRs = prs
            state.pullRequests = prs
            state.lastUpdated = Date()
            try? store.save(state)
            setStatus(.loaded)
        } catch let GitHubError.rateLimited(until) {
            setStatus(.rateLimited(until: until))
        } catch GitHubError.unauthorized {
            setStatus(.signedOut)             // token revoked -> re-auth
        } catch GitHubError.network {
            setStatus(.offline)
        } catch {
            setStatus(.error("\(error)"))
        }
    }

    private func setStatus(_ s: AppStatus) { status = s; onChange?() }

    // MARK: - Auth

    func pastePAT(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? tokenStore.save(trimmed)
        viewer = nil
        Task { await client.setToken(trimmed); startLoop() }
    }

    /// Non-blocking device-flow sign-in: copy the code, open the pre-filled URL,
    /// show the code in the menu, and poll in the background.
    func signInWithDeviceFlow() {
        guard !Self.clientID.isEmpty else {
            setStatus(.error("No client id — register an OAuth App (Settings ▸ Developer settings), "
                             + "set PRPeekClientID, or just Paste token.")); return
        }
        let flow = DeviceFlowAuth(transport: URLSessionTransport(), clientID: Self.clientID)
        Task {
            do {
                let token = try await flow.authorize(scope: "repo read:org", onCode: { code in
                    Task { @MainActor in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                        self.setStatus(.authorizing(code: code.userCode))
                        if let url = code.bestVerificationURL { NSWorkspace.shared.open(url) }
                    }
                })
                try? tokenStore.save(token)
                viewer = nil
                await client.setToken(token)
                startLoop()
            } catch DeviceFlowAuth.DeviceFlowError.denied {
                setStatus(.error("Authorization denied."))
            } catch DeviceFlowAuth.DeviceFlowError.expired {
                setStatus(.error("Code expired — try Sign in again."))
            } catch {
                setStatus(.error("Sign-in failed: \(error)"))
            }
        }
    }

    func signOut() {
        try? tokenStore.delete()
        viewer = nil; previousPRs = []
        state.pullRequests = []
        try? store.save(state)
        Task { await client.setToken(nil) }
        loopTask?.cancel()
        setStatus(.signedOut)
    }
}
