import AppKit
import PRPeekCore

/// Owns the NSStatusItem: paints the badge and rebuilds the menu whenever the
/// model changes. v1 menu = three sections with a per-section overflow cap
/// (search box deferred — see plan NOT-in-scope).
@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let panel: DesktopPanel
    private let sectionCap = 15
    /// PR id -> its live submenu(s), rebuilt each render. A self-authored failing
    /// PR shows in both "Needs me" and "Mine", so one id can have two submenus;
    /// a finished comment/commit load must repopulate all of them.
    private var submenus: [String: [PRSubmenu]] = [:]
    /// Sticky toggles depend on the menu staying open, so a full rebuild is
    /// deferred while any (sub)menu is open and flushed when it all closes.
    private var openMenus = 0
    private var pendingRender = false
    private var toggleViews: [MenuToggleView] = []   // live toggles to refresh in place

    init(model: AppModel) {
        self.model = model
        self.panel = DesktopPanel(model: model)
        super.init()
        model.onChange = { [weak self] in self?.render() }
        model.onSubmenuReload = { [weak self] id in
            self?.submenus[id]?.forEach { self?.populate($0) }
        }
        render()
    }

    private func render() {
        panel.refresh()   // desktop widget updates even while the menu is open

        // Don't rebuild while the menu is open — it would close a sticky toggle
        // session. Flush on close (menuDidClose).
        if openMenus > 0 { pendingRender = true; return }

        // Badge
        let signedOut = model.status == .signedOut
        let offline = model.status == .offline
        item.button?.image = BadgeRenderer.icon(needsMe: model.needsMe.count,
                                                 total: model.all.count,
                                                 signedOut: signedOut, offline: offline,
                                                 accent: palette?.red ?? .systemRed)
        item.button?.imagePosition = .imageOnly

        // Menu
        submenus.removeAll(); toggleViews.removeAll()   // stale refs from the previous menu
        let menu = NSMenu()
        menu.delegate = self                            // open/close tracking for deferred rebuilds
        menu.addItem(statusRow())
        menu.addItem(.separator())

        if signedOut {
            menu.addItem(action("Sign in with GitHub…", #selector(signIn)))
            menu.addItem(action("Paste token…", #selector(pasteToken)))
        } else {
            // F3: "All" was a superset of the first two -> every PR shown up to 3×.
            // Third section is the remainder so each PR appears once.
            let needIDs = Set(model.needsMe.map(\.id))
            let mineIDs = Set(model.mine.map(\.id))
            let others = model.all.filter { !needIDs.contains($0.id) && !mineIDs.contains($0.id) }
            section(menu, "Needs me", model.needsMe)
            section(menu, "Mine", model.mine)
            section(menu, "Others", others)
            menu.addItem(.separator())
            menu.addItem(filterReposItem())
            menu.addItem(action("Refresh now", #selector(refresh)))
            menu.addItem(action("Sign out", #selector(signOut)))
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Desktop panel", isOn: { [weak self] in self?.panel.isVisible ?? false }) {
            [weak self] in self?.panel.toggle()
        })
        menu.addItem(intervalItem())
        menu.addItem(themeItem())
        menu.addItem(action("Quit PRPeek", #selector(quit), key: "q"))

        // NSApp.appearance alone doesn't repaint a status-item menu — set it on
        // the menu directly. nil = follow the system (System theme). Do NOT theme
        // item.button: the menubar icon must follow the system menubar appearance,
        // else a dark theme on a light menubar renders the template glyph invisibly.
        menu.appearance = model.theme.nsAppearance
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

    /// Catppuccin palette for the active theme (cached on the model), or nil for
    /// System/Light/Dark (which use stock label/system colors).
    private var palette: Palette? { model.palette }

    /// Tint a menu item's title for Catppuccin themes. No-op for System/Light/Dark
    /// so AppKit keeps its automatic title inversion on the selection highlight.
    private func tint(_ item: NSMenuItem, _ color: (Palette) -> NSColor) {
        if let p = palette {
            item.attributedTitle = NSAttributedString(string: item.title,
                                                      attributes: [.foregroundColor: color(p)])
        }
    }

    private func section(_ menu: NSMenu, _ name: String, _ prs: [PullRequest]) {
        let header = NSMenuItem(title: "\(name) (\(prs.count))", action: nil, keyEquivalent: "")
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        if let p = palette { attrs[.foregroundColor] = p.subtext }
        header.attributedTitle = NSAttributedString(string: "\(name) (\(prs.count))", attributes: attrs)
        header.isEnabled = false
        menu.addItem(header)

        if prs.isEmpty {
            let empty = NSMenuItem(title: "   none", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for pr in prs.prefix(sectionCap) {
            let i = NSMenuItem(title: "\(pr.repoFullName)#\(pr.number)  \(pr.title)",
                               action: nil, keyEquivalent: "")   // submenu = expand; "Open" lives inside it
            tint(i) { $0.text }
            i.image = ciImage(pr.ciState)   // semantic SF Symbol, not emoji (F2)
            let sub = PRSubmenu(pr: pr)
            sub.delegate = self                  // menuWillOpen -> lazy-load + populate
            sub.addItem(disabledRow("PR details…"))   // placeholder so the arrow shows; replaced on open
            submenus[pr.id, default: []].append(sub)
            i.submenu = sub
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

    // MARK: repo filter

    /// Submenu: "All repos" + a sticky toggle per known repo. Checked = included.
    /// Empty filter == all, so when showing all every repo reads as checked.
    /// Sticky: flip several repos without the menu closing each time.
    private func filterReposItem() -> NSMenuItem {
        let repos = model.knownRepos
        let parent = NSMenuItem(title: "Filter repos", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.delegate = self

        sub.addItem(toggle("All repos", isOn: { [weak self] in self?.model.repoFilters.isEmpty ?? true }) {
            [weak self] in self?.model.setRepoFilters([])
        })

        if repos.isEmpty {
            let none = NSMenuItem(title: "   (no repos yet)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            sub.addItem(.separator())
            for repo in repos {
                sub.addItem(toggle(repo,
                    isOn: { [weak self] in
                        guard let self else { return false }
                        return self.model.repoFilters.isEmpty || self.model.repoFilters.contains(repo)
                    },
                    action: { [weak self] in self?.toggleRepoFilter(repo) }))
            }
        }
        parent.submenu = sub
        return parent
    }

    private func toggleRepoFilter(_ repo: String) {
        var current = Set(model.repoFilters.isEmpty ? model.knownRepos : model.repoFilters)
        if current.contains(repo) { current.remove(repo) } else { current.insert(repo) }
        model.setRepoFilters(Array(current))
    }

    // MARK: refresh interval

    private static let intervals: [(String, Int)] =
        [("Every 15 minutes", 900), ("Every hour", 3600), ("Every 3 hours", 10800), ("Every day", 86400)]

    private func intervalItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.delegate = self
        for (label, secs) in Self.intervals {
            sub.addItem(toggle(label, isOn: { [weak self] in self?.model.refreshIntervalSecs == secs }) {
                [weak self] in self?.model.setRefreshInterval(secs)
            })
        }
        parent.submenu = sub
        return parent
    }

    // MARK: theme

    private func themeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.delegate = self
        for (idx, t) in Theme.allCases.enumerated() {
            if idx == 3 { sub.addItem(.separator()) }   // divide System/Light/Dark from Catppuccin
            sub.addItem(toggle(t.label, isOn: { [weak self] in self?.model.theme == t }) { [weak self] in
                guard let self else { return }
                self.model.setTheme(t)
                // Apply the new appearance to the OPEN menu now — full effect for
                // System/Light/Dark; Catppuccin base flips live, text tint on reopen
                // (per-item recolor needs a rebuild, which would close the menu).
                self.item.menu?.appearance = t.nsAppearance
                sub.appearance = t.nsAppearance
            })
        }
        parent.submenu = sub
        return parent
    }

    /// Build a sticky toggle menu item: clicking it runs `action`, refreshes all
    /// live toggles' checkmarks in place, and leaves the menu open.
    private func toggle(_ title: String, isOn: @escaping () -> Bool, action: @escaping () -> Void) -> NSMenuItem {
        let view = MenuToggleView(title: title, tint: palette?.text, isOn: isOn) { [weak self] in
            action()
            self?.toggleViews.forEach { $0.refresh() }   // sibling checkmarks update without rebuild
        }
        toggleViews.append(view)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    // MARK: PR submenu (review comments)

    /// Fill a PR's submenu from the current cache state. Called at build time, on
    /// submenu open (shows "Loading…"), and again when the load finishes.
    private func populate(_ sub: PRSubmenu) {
        sub.removeAllItems()
        let open = NSMenuItem(title: "Open PR in browser", action: #selector(openPR(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = sub.pr.htmlURL
        sub.addItem(open)
        sub.addItem(.separator())

        // Review comments
        if let comments = model.comments(for: sub.pr) {
            if comments.isEmpty {
                sub.addItem(disabledRow("No review comments"))
            } else {
                sub.addItem(disabledRow("\(comments.count) review comment\(comments.count == 1 ? "" : "s")"))
                for c in comments { sub.addItem(commentItem(c)) }
            }
        } else {
            sub.addItem(disabledRow(model.isLoadingComments(sub.pr) ? "Loading comments…" : "Review comments"))
        }

        sub.addItem(.separator())

        // Commit timeline
        if let commits = model.commits(for: sub.pr) {
            if commits.isEmpty {
                sub.addItem(disabledRow("No commits"))
            } else {
                sub.addItem(disabledRow("\(commits.count) commit\(commits.count == 1 ? "" : "s")"))
                for c in commits { sub.addItem(commitItem(c)) }
            }
        } else {
            sub.addItem(disabledRow(model.isLoadingCommits(sub.pr) ? "Loading commits…" : "Commits"))
        }
    }

    private func commitItem(_ c: Commit) -> NSMenuItem {
        let title = "\(c.message.prefix(56))  ·  \(c.shortSHA)  ·  \(c.author) \(Self.age.localizedString(for: c.date, relativeTo: Date()))"
        return linkRow(title: title, image: ciImage(c.ciState), url: c.htmlURL)   // per-commit check-runs
    }

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private func commentItem(_ c: ReviewComment) -> NSMenuItem {
        let snippet = c.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let loc = c.location.map { " (\($0))" } ?? ""
        return linkRow(title: "\(c.author): \(snippet.prefix(64))\(loc)", image: verdictImage(c.verdict), url: c.htmlURL)
    }

    /// A clickable, optionally-themed menu row that opens `url` in the browser.
    private func linkRow(title: String, image: NSImage?, url: URL?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: url != nil ? #selector(openPR(_:)) : nil, keyEquivalent: "")
        i.target = self
        i.representedObject = url
        tint(i) { $0.text }
        i.image = image
        return i
    }

    private func disabledRow(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: "   \(title)", action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func verdictImage(_ v: ReviewVerdict) -> NSImage? {
        let symbol: String, color: NSColor
        switch v {
        case .approved:         symbol = "checkmark.seal.fill"; color = palette?.green ?? .systemGreen
        case .changesRequested: symbol = "xmark.octagon.fill";  color = palette?.red ?? .systemRed
        case .commented:        symbol = "text.bubble.fill";    color = palette?.subtext ?? .secondaryLabelColor
        }
        return Self.symbolImage(symbol, color: color)
    }

    @objc private func signIn() {
        // Non-blocking: copies the code, opens the pre-filled URL, shows progress
        // in the menu status row. No modal that would stall polling.
        model.signInWithDeviceFlow()
    }

    @objc private func pasteToken() {
        let alert = NSAlert()
        alert.messageText = "Paste a GitHub token"
        alert.informativeText = "Fine-grained or classic PAT with repo + read:org access."
        // F4: a token is a secret — secure field (masked, no echo), focused so
        // the user can paste immediately.
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "ghp_… or github_pat_…"
        // Accessory app has no Edit menu, so ⌘V is dead. Prefill from the
        // clipboard if it looks like a token, and give an explicit Paste button.
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        if clip.hasPrefix("ghp_") || clip.hasPrefix("github_pat_") { field.stringValue = clip }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Paste from Clipboard")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:  model.pastePAT(field.stringValue)              // Save (typed or prefilled)
        case .alertSecondButtonReturn: model.pastePAT(NSPasteboard.general.string(forType: .string) ?? "")  // Paste
        default: break                                                                // Cancel
        }
    }

    // MARK: helpers
    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }
    /// CI status as a color SF Symbol (HIG-native, not emoji). Shape + color so
    /// it's not color-only encoding. Color follows the theme palette when set.
    private func ciImage(_ s: CIState) -> NSImage? {
        let symbol: String, color: NSColor
        switch s {
        case .passing: symbol = "checkmark.circle.fill"; color = palette?.green ?? .systemGreen
        case .failing: symbol = "xmark.octagon.fill";    color = palette?.red ?? .systemRed
        case .pending: symbol = "clock.fill";            color = palette?.yellow ?? .systemYellow
        case .none:    symbol = "minus.circle";          color = palette?.subtext ?? .tertiaryLabelColor
        }
        return Self.symbolImage(symbol, color: color)
    }

    /// Color SF Symbol that keeps its color in the menu (not template-tinted).
    private static func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let img = base.withSymbolConfiguration(.init(paletteColors: [color])) ?? base
        img.isTemplate = false
        return img
    }
    static let shortTime: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    private static func time(_ d: Date) -> String { shortTime.string(from: d) }
}

/// An NSMenu that remembers which PR it belongs to, so the delegate can lazy-load
/// that PR's review comments when the submenu opens.
final class PRSubmenu: NSMenu {
    let pr: PullRequest
    init(pr: PullRequest) { self.pr = pr; super.init(title: pr.title) }
    required init(coder: NSCoder) { fatalError("not from a nib") }
}

extension StatusController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        openMenus += 1
        if let sub = menu as? PRSubmenu {
            model.loadComments(for: sub.pr)
            model.loadCommits(for: sub.pr)
            populate(sub)   // reflect "Loading…" immediately; onSubmenuReload repopulates with content
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenus = max(0, openMenus - 1)
        // When the whole menu tree has closed, apply any rebuild we deferred
        // while it was open (theme recolor, refreshed PR list, …).
        if openMenus == 0, pendingRender {
            pendingRender = false
            render()
        }
    }
}
