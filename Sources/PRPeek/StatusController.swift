import AppKit
import PRPeekCore

/// Owns the NSStatusItem: paints the badge and rebuilds the menu whenever the
/// model changes. v1 menu = three sections with a per-section overflow cap
/// (search box deferred — see plan NOT-in-scope).
@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let sectionCap = 15

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    private func render() {
        // Badge
        let signedOut = model.status == .signedOut
        let offline = model.status == .offline
        item.button?.image = BadgeRenderer.icon(needsMe: model.needsMe.count,
                                                 total: model.all.count,
                                                 signedOut: signedOut, offline: offline)
        item.button?.imagePosition = .imageOnly

        // Menu
        let menu = NSMenu()
        menu.addItem(statusRow())
        menu.addItem(.separator())

        if signedOut {
            menu.addItem(action("Sign in with GitHub…", #selector(signIn)))
            menu.addItem(action("Paste token…", #selector(pasteToken)))
        } else {
            section(menu, "Needs me", model.needsMe)
            section(menu, "Mine", model.mine)
            section(menu, "All", model.all)
            menu.addItem(.separator())
            menu.addItem(action("Refresh now", #selector(refresh)))
            menu.addItem(action("Sign out", #selector(signOut)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit PRPeek", #selector(quit), key: "q"))
        item.menu = menu
    }

    private func statusRow() -> NSMenuItem {
        let text: String
        switch model.status {
        case .signedOut: text = "Not signed in"
        case .authorizing(let code): text = "Authorizing — code \(code) (copied)"
        case .loading: text = "Refreshing…"
        case .offline: text = "Offline — showing cached"
        case .rateLimited(let until):
            text = "Rate limited" + (until.map { " until \(Self.time($0))" } ?? "")
        case .error(let m): text = "Error: \(m.prefix(60))"
        case .loaded:
            text = model.lastUpdated.map { "Updated \(Self.time($0))" } ?? "Up to date"
        }
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func section(_ menu: NSMenu, _ name: String, _ prs: [PullRequest]) {
        let header = NSMenuItem(title: "\(name) (\(prs.count))", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "\(name) (\(prs.count))",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
        header.isEnabled = false
        menu.addItem(header)

        if prs.isEmpty {
            let empty = NSMenuItem(title: "   none", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for pr in prs.prefix(sectionCap) {
            let i = NSMenuItem(title: "\(Self.ciMark(pr.ciState)) \(pr.repoFullName)#\(pr.number)  \(pr.title)",
                               action: #selector(openPR(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = pr.htmlURL
            menu.addItem(i)
        }
        if prs.count > sectionCap {
            let more = action("   +\(prs.count - sectionCap) more on GitHub…", #selector(openAll))
            menu.addItem(more)
        }
    }

    // MARK: actions
    @objc private func openPR(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }
    @objc private func openAll() { NSWorkspace.shared.open(URL(string: "https://github.com/pulls")!) }
    @objc private func refresh() { model.kickRefresh() }
    @objc private func signOut() { model.signOut() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func signIn() {
        // Non-blocking: copies the code, opens the pre-filled URL, shows progress
        // in the menu status row. No modal that would stall polling.
        model.signInWithDeviceFlow()
    }

    @objc private func pasteToken() {
        let alert = NSAlert()
        alert.messageText = "Paste a GitHub token"
        alert.informativeText = "Fine-grained or classic PAT with repo + read:org access."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.pastePAT(field.stringValue) }
    }

    // MARK: helpers
    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }
    private static func ciMark(_ s: CIState) -> String {
        switch s { case .passing: return "✅"; case .failing: return "❌"; case .pending: return "🟡"; case .none: return "▫️" }
    }
    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
    }
}
