import Foundation
import OSLog

enum AppTelemetry {
    static let subsystem = Bundle.main.bundleIdentifier ?? "PRPeek"

    static let statusMenu = Logger(subsystem: subsystem, category: "StatusMenu")
    static let appModel = Logger(subsystem: subsystem, category: "AppModel")
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let desktopPanel = Logger(subsystem: subsystem, category: "DesktopPanel")
    static let notifications = Logger(subsystem: subsystem, category: "Notifications")
}

extension AppStatus {
    var telemetryName: String {
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
