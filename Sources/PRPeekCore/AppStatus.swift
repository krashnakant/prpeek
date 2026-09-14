import Foundation

public enum AppStatus: Equatable {
    /// `reason` is why the session ended (e.g. GitHub rejected the token) —
    /// nil for a plain signed-out state. Shown in the status row so a bad
    /// paste or an expired token isn't mistaken for "never signed in".
    case signedOut(reason: String?)
    case authorizing(code: String)
    case loading
    case loaded
    case offline
    case rateLimited(until: Date?)
    case error(String)

    public var isSignedOut: Bool { if case .signedOut = self { true } else { false } }

    /// How much this state wants the user's attention. Signed-out has no rank:
    /// `aggregate` filters those accounts out instead.
    public var severity: Int {
        switch self {
        case .authorizing: return 5
        case .rateLimited: return 4
        case .error:       return 3
        case .offline:     return 2
        case .loading:     return 1
        case .loaded, .signedOut: return 0
        }
    }

    /// Worst-of across accounts, so one rate-limited account stays visible in the
    /// menubar while the others are fine. A signed-out account among signed-in
    /// ones says nothing — the rest still have PRs — so it only wins when every
    /// account is signed out.
    public static func aggregate(_ all: [AppStatus]) -> AppStatus {
        guard let worst = all.filter({ !$0.isSignedOut }).max(by: { $0.severity < $1.severity })
        else { return all.first ?? .signedOut(reason: nil) }   // all signed out, or no accounts
        return worst
    }
}

extension AppStatus {
    /// Stable, non-localized name for log lines.
    public var logName: String {
        switch self {
        case .signedOut: return "signedOut"
        case .authorizing: return "authorizing"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .offline: return "offline"
        case .rateLimited: return "rateLimited"
        case .error: return "error"
        }
    }
}

public extension AppStatus {
    /// Human-readable status. One mapping for every surface that shows one — the
    /// menu's top row, the per-account rows, and the desktop panel's summary —
    /// because when they each kept their own switch the wording drifted apart.
    /// `loaded` is the only state each surface words differently, so it's the
    /// only one the caller supplies.
    func text(loaded: @autoclosure () -> String, time: (Date) -> String = AppStatus.shortTime,
              errorLimit: Int = 64) -> String {
        switch self {
        case .signedOut(let reason): return reason ?? "Not signed in"
        case .authorizing(let code): return "Authorizing — code \(code) (copied)"
        case .loading:               return "Refreshing…"
        case .offline:               return "Offline — showing cached"
        case .rateLimited(let until): return "Rate limited" + (until.map { " until \(time($0))" } ?? "")
        case .error(let m):          return "Error: \(m.prefix(errorLimit))"
        case .loaded:                return loaded()
        }
    }

    static func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: d)
    }
}
