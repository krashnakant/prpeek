import Foundation
import OSLog

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "PRPeek"

    static let statusMenu = Logger(subsystem: subsystem, category: "StatusMenu")
    static let appModel = Logger(subsystem: subsystem, category: "AppModel")
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let desktopPanel = Logger(subsystem: subsystem, category: "DesktopPanel")
    static let notifications = Logger(subsystem: subsystem, category: "Notifications")
}
