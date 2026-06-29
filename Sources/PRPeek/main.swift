import AppKit
import PRPeekCore

// PRPeek — macOS menubar watcher for open GitHub PRs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var status: StatusController?

    func applicationDidFinishLaunching(_ note: Notification) {
        status = StatusController(model: model)   // paints cached PRs immediately
        model.start()                              // lifecycle + refresh loop
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menubar-only, no dock icon (== LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
