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

// Accessory apps have no visible menu bar, but ⌘-key equivalents still route
// through NSApp.mainMenu — without an Edit menu, ⌘V/⌘C/⌘X/⌘A are dead in every
// text field (token paste, GHES host, search). Install an invisible one.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let mainMenu = NSMenu()
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
mainMenu.setSubmenu(editMenu, for: editItem)
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
