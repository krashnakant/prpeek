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
    private let search: SearchWindow
    private let sectionCap = 15
    /// One truncation budget for every menu row that elides (commit subject,
    /// comment snippet, error text) — the untruncated text is in the tooltip.
    private static let snippetLimit = 64
    /// PR key -> its live submenu(s), rebuilt each render. A self-authored failing
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
        self.search = SearchWindow(model: model)
        super.init()
        model.onChange = { [weak self] in self?.render() }
        model.onSubmenuReload = { [weak self] id in
            self?.submenus[id]?.forEach { self?.populate($0) }
        }
        render()
    }

    private func render() {
        panel.refresh()   // desktop widget updates even while the menu is open
        search.refresh()  // keep the search list live if its window is open

        // Don't rebuild while the menu is open — it would close a sticky toggle
        // session. Flush on close (menuDidClose).
        if openMenus > 0 {
            pendingRender = true
            AppLog.statusMenu.debug("Deferred menu render while menu tree is open")
            return
        }
        AppLog.statusMenu.debug(
            "Rendering menu status=\(self.model.status.logName, privacy: .public) needsMe=\(self.model.needsMe.count, privacy: .public) mine=\(self.model.mine.count, privacy: .public) all=\(self.model.all.count, privacy: .public)"
        )

        // Badge
        let signedOut = model.status.isSignedOut
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
            menu.addItem(action("Sign in with GitHub…", #selector(signIn), symbol: "person.crop.circle"))
            menu.addItem(action("Add account with token…", #selector(pasteToken), symbol: "key.fill"))
            menu.addItem(.separator())
            menu.addItem(desktopPanelItem())
            menu.addItem(preferencesItem())
        } else {
            // F3: "All" was a superset of the first two -> every PR shown up to 3×.
            // Remaining sections show the remainder so each PR appears once.
            // Muted PRs live only in the Muted section (excluded from the rest).
            // Keyed on `key`, not `id`: two accounts can carry the same node_id,
            // and one account's PR would then hide the other's.
            let mutedIDs = Set(model.muted.map(\.key))
            let needIDs = Set(model.needsMe.map(\.key))          // needsMe already excludes muted
            let mine = model.mine.filter { !mutedIDs.contains($0.key) }
            let mineIDs = Set(mine.map(\.key))
            let others = model.all.filter {
                !needIDs.contains($0.key) && !mineIDs.contains($0.key) && !mutedIDs.contains($0.key)
            }
            section(menu, "Needs me", model.needsMe)
            section(menu, "Mine", mine)
            section(menu, "Others", others)
            if !model.muted.isEmpty { section(menu, "Muted", model.muted) }
            menu.addItem(.separator())
            menu.addItem(action("Search PRs…", #selector(openSearch), key: "f", symbol: "magnifyingglass"))
            menu.addItem(action("Refresh now", #selector(refresh), symbol: "arrow.clockwise"))
            menu.addItem(filterReposItem())
            menu.addItem(.separator())
            menu.addItem(desktopPanelItem())
            menu.addItem(preferencesItem())
            menu.addItem(.separator())
            menu.addItem(accountsItem())
        }
        menu.addItem(action("Quit PRPeek", #selector(quit), key: "q", symbol: "power"))

        // NSApp.appearance alone doesn't repaint a status-item menu — set it on
        // the menu directly. nil = follow the system (System theme). Do NOT theme
        // item.button: the menubar icon must follow the system menubar appearance,
        // else a dark theme on a light menubar renders the template glyph invisibly.
        menu.appearance = model.theme.nsAppearance
        item.menu = menu
    }

    private func statusRow() -> NSMenuItem {
        let text = model.status.text(
            loaded: model.lastUpdated.map { "Updated \(Self.time($0))" } ?? "Up to date",
            time: Self.time, errorLimit: Self.snippetLimit)
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// Catppuccin palette for the active theme (cached on the model), or nil for
    /// System/Light/Dark (which use stock label/system colors).
    private var palette: Palette? { model.palette }

    private func styleSectionHeader(_ h: NSMenuItem) {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        if let p = palette { attrs[.foregroundColor] = p.subtext }
        h.attributedTitle = NSAttributedString(string: h.title, attributes: attrs)
    }

    /// Tint a menu item's title for Catppuccin themes. For System/Light/Dark it
    /// clears the attributed title so AppKit keeps its automatic color + selection
    /// highlight inversion. Setting it both ways makes it safe to call on a live
    /// theme switch (Catppuccin -> System must drop the stale tint).
    private func tint(_ item: NSMenuItem, _ color: (Palette) -> NSColor) {
        if let p = palette {
            item.attributedTitle = NSAttributedString(string: item.title,
                                                      attributes: [.foregroundColor: color(p)])
        } else {
            item.attributedTitle = nil
        }
    }

    private func section(_ menu: NSMenu, _ name: String, _ prs: [PullRequest]) {
        let header = NSMenuItem(title: "\(name) (\(prs.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        styleSectionHeader(header)
        menu.addItem(header)

        if prs.isEmpty {
            let empty = NSMenuItem(title: "none", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        }
        for pr in prs.prefix(sectionCap) {
            // Surface WHY it needs me and HOW FRESH it is, inline + on hover.
            let freshness = model.freshness(pr)
            let suffix = pr.waitReason.map { "  —  \($0.short)" } ?? ""
            let fresh = freshness?.pillLabel.map { "  ·  \($0)" } ?? ""
            // Account prefix only once more than one identity is signed in.
            let account = accountTag(model.accountLabel(for: pr))
            let i = NSMenuItem(title: "\(account)\(pr.repoFullName)#\(pr.number)  \(pr.title)\(suffix)\(fresh)",
                               action: nil, keyEquivalent: "")   // submenu = expand; "Open" lives inside it
            i.toolTip = [pr.waitReason?.long, freshness?.long]
                .compactMap { $0 }.joined(separator: "\n")
            tint(i) { $0.text }
            i.image = ciImage(pr.ciState, palette: palette)   // semantic SF Symbol, not emoji (F2)
            let sub = PRSubmenu(pr: pr)
            sub.delegate = self                  // menuWillOpen -> lazy-load + populate
            sub.addItem(disabledRow("PR details…"))   // placeholder so the arrow shows; replaced on open
            submenus[pr.key, default: []].append(sub)
            i.submenu = sub
            menu.addItem(i)
        }
        if prs.count > sectionCap {
            let more = action("+\(prs.count - sectionCap) more on GitHub…", #selector(openAll))
            more.indentationLevel = 1
            menu.addItem(more)
        }
    }

    // MARK: actions
    @objc private func openPR(_ sender: NSMenuItem) {
        AppLog.statusMenu.info("Open PR action selected")
        // A PR opens through the model so it counts as seen; plain URLs (a
        // commit, a review comment) just open.
        if let pr = sender.representedObject as? PullRequest { model.open(pr) }
        else if let url = sender.representedObject as? URL { NSWorkspace.shared.openSafeWebURL(url) }
    }
    @objc private func copyPRURL(_ sender: NSMenuItem) {
        AppLog.statusMenu.info("Copy PR URL action selected")
        if let pr = sender.representedObject as? PullRequest {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.htmlURL.absoluteString, forType: .string)
        } else if let url = sender.representedObject as? URL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
    @objc private func openAll() {
        AppLog.statusMenu.info("Open GitHub pulls action selected")
        let ghesHost = model.sessions.first(where: { !$0.account.host.isEmpty })?.account.host ?? ""
        let url = GitHubClient.webBase(forHost: ghesHost).appending(path: "pulls")
        NSWorkspace.shared.openSafeWebURL(url)
    }
    @objc private func refresh() {
        AppLog.statusMenu.info("Manual refresh action selected")
        model.kickRefresh()
    }
    @objc private func openSearch() {
        AppLog.statusMenu.info("Search PRs action selected")
        search.show()
    }
    // MARK: accounts

    /// "Accounts ▸ {one row per identity, Add…, Sign out of all}". Each account
    /// row shows its own status, so a rate-limited or rejected account is
    /// visible without hunting through the merged PR list.
    private func accountsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("person.2")
        let sub = NSMenu()
        for session in model.sessions {
            let row = NSMenuItem(title: session.displayName, action: nil, keyEquivalent: "")
            row.image = Self.menuIcon("person.crop.circle")
            let detail = NSMenu()
            detail.addItem(disabledRow(session.account.displayHost))
            detail.addItem(disabledRow(session.status.text(loaded: "OK", time: Self.time, errorLimit: Self.snippetLimit)))
            detail.addItem(.separator())
            let remove = NSMenuItem(title: "Sign out of this account",
                                    action: #selector(removeAccount(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = session.account.id
            remove.image = Self.menuIcon("rectangle.portrait.and.arrow.right")
            detail.addItem(remove)
            row.submenu = detail
            sub.addItem(row)
        }
        sub.addItem(.separator())
        let add = NSMenuItem(title: "Add account with token…", action: #selector(pasteToken), keyEquivalent: "")
        add.target = self; add.image = Self.menuIcon("plus")
        sub.addItem(add)
        if !AppModel.clientID.isEmpty {
            let device = NSMenuItem(title: "Add github.com account…", action: #selector(signIn), keyEquivalent: "")
            device.target = self; device.image = Self.menuIcon("person.crop.circle.badge.plus")
            sub.addItem(device)
        }
        sub.addItem(.separator())
        let all = NSMenuItem(title: "Sign out of all", action: #selector(signOutAll), keyEquivalent: "")
        all.target = self; all.image = Self.menuIcon("rectangle.portrait.and.arrow.right")
        sub.addItem(all)
        parent.submenu = sub
        return parent
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppLog.statusMenu.info("Remove account action selected")
        model.removeAccount(id)
    }

    @objc private func signOutAll() {
        AppLog.statusMenu.info("Sign out of all accounts action selected")
        model.signOutAll()
    }
    @objc private func quit() {
        AppLog.statusMenu.info("Quit action selected")
        NSApp.terminate(nil)
    }

    // MARK: mute / snooze

    /// "Snooze ▸ {1h, 4h, Until it updates}", or "Unmute" if already snoozed.
    private func muteControl(for pr: PullRequest) -> NSMenuItem {
        if model.isMuted(pr) {
            let un = NSMenuItem(title: "Unmute", action: #selector(unmutePR(_:)), keyEquivalent: "")
            un.target = self; un.representedObject = pr; un.image = Self.menuIcon("bell")
            return un
        }
        let parent = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("moon.zzz")
        let sub = NSMenu()
        sub.addItem(snoozeRow("1 hour", 3600, pr))
        sub.addItem(snoozeRow("4 hours", 14400, pr))
        sub.addItem(snoozeRow("Until it updates", 0, pr))   // tag 0 = until-updated
        parent.submenu = sub
        return parent
    }
    private func snoozeRow(_ label: String, _ secs: Int, _ pr: PullRequest) -> NSMenuItem {
        let i = NSMenuItem(title: label, action: #selector(snoozePR(_:)), keyEquivalent: "")
        i.target = self; i.representedObject = pr; i.tag = secs
        return i
    }
    @objc private func snoozePR(_ sender: NSMenuItem) {
        guard let pr = sender.representedObject as? PullRequest else { return }
        AppLog.statusMenu.info("Snooze action selected seconds=\(sender.tag, privacy: .public)")
        if sender.tag > 0 { model.mute(pr, for: TimeInterval(sender.tag)) }
        else { model.muteUntilUpdated(pr) }
    }
    @objc private func unmutePR(_ sender: NSMenuItem) {
        guard let pr = sender.representedObject as? PullRequest else { return }
        AppLog.statusMenu.info("Unmute action selected")
        model.unmute(pr)
    }

    // MARK: repo filter

    /// Submenu: "All repos" + a sticky toggle per known repo. Checked = included.
    /// Empty filter == all, so when showing all every repo reads as checked.
    /// Sticky: flip several repos without the menu closing each time.
    private func filterReposItem() -> NSMenuItem {
        let repos = model.knownRepos
        let parent = NSMenuItem(title: "Filter repos", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("line.3.horizontal.decrease.circle")
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
        AppLog.statusMenu.info("Repo filter toggled")
        var current = Set(model.repoFilters.isEmpty ? model.knownRepos : model.repoFilters)
        if current.contains(repo) { current.remove(repo) } else { current.insert(repo) }
        model.setRepoFilters(Array(current))
    }

    // MARK: desktop panel

    private func desktopPanelItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Desktop panel", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("rectangle.on.rectangle")
        let sub = NSMenu(); sub.delegate = self
        sub.addItem(toggle("Show panel", isOn: { [weak self] in self?.panel.isVisible ?? false }) {
            [weak self] in self?.panel.toggle()
        })
        sub.addItem(toggle("Keep panel on top", isOn: { [weak self] in self?.panel.keepOnTop ?? true }) {
            [weak self] in
            guard let panel = self?.panel else { return }
            panel.setKeepOnTop(!panel.keepOnTop)
        })
        parent.submenu = sub
        return parent
    }

    // MARK: preferences

    private func preferencesItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("gearshape")
        let sub = NSMenu(); sub.delegate = self
        sub.addItem(toggle("Launch at login", isOn: { [weak self] in self?.model.launchAtLogin ?? false }) {
            [weak self] in guard let self else { return }; self.model.setLaunchAtLogin(!self.model.launchAtLogin)
        })
        sub.addItem(intervalItem())
        sub.addItem(themeItem())
        // The GHES host moved onto the account itself (Accounts ▸ Add account),
        // so there's no global host setting to expose here any more.
        parent.submenu = sub
        return parent
    }

    // MARK: refresh interval

    private static let intervals: [(String, Int)] =
        [("Every 15 minutes", 900), ("Every hour", 3600), ("Every 3 hours", 10800), ("Every day", 86400)]

    private func intervalItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("timer")
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
        parent.image = Self.menuIcon("paintpalette")
        let sub = NSMenu(); sub.delegate = self
        for (idx, t) in Theme.allCases.enumerated() {
            if idx == 3 { sub.addItem(.separator()) }   // divide System/Light/Dark from Catppuccin
            sub.addItem(toggle(t.label, isOn: { [weak self] in self?.model.theme == t }) { [weak self] in
                guard let self else { return }
                self.model.setTheme(t)
                // Live appearance (light/dark base) on the open menu. Catppuccin's
                // per-item text/CI recolor applies on the next open: mutating a live
                // vibrant NSMenu's items in place hangs AppKit and ghosts the text.
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
        open.image = Self.menuIcon("arrow.up.right.square")
        open.representedObject = sub.pr
        sub.addItem(open)

        let copyURL = NSMenuItem(title: "Copy URL", action: #selector(copyPRURL(_:)), keyEquivalent: "")
        copyURL.target = self
        copyURL.image = Self.menuIcon("doc.on.doc")
        copyURL.representedObject = sub.pr
        sub.addItem(copyURL)

        sub.addItem(muteControl(for: sub.pr))
        if let reReview = reReviewControl(for: sub.pr) { sub.addItem(reReview) }
        if let merge = mergeControl(for: sub.pr) { sub.addItem(merge) }
        sub.addItem(.separator())

        // Review comments
        if let comments = model.comments(for: sub.pr) {
            if comments.isEmpty {
                sub.addItem(disabledRow("No review comments"))
            } else {
                sub.addItem(disabledRow("\(comments.count) review comment\(comments.count == 1 ? "" : "s")  ·  ⌥ to reply"))
                for c in comments {
                    let row = commentItem(c)
                    row.keyEquivalentModifierMask = []   // must differ from the alternate's ⌥
                    sub.addItem(row)
                    sub.addItem(replyItem(c, on: sub.pr))
                }
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
        let title = "\(c.message.prefix(Self.snippetLimit))  ·  \(c.shortSHA)  ·  \(c.author) \(Self.age.localizedString(for: c.date, relativeTo: Date()))"
        // Hover summary: full (untruncated) subject + metadata.
        let tip = "\(c.message)\n\(c.shortSHA) · \(c.author) · \(Self.age.localizedString(for: c.date, relativeTo: Date()))"
        return linkRow(title: title, image: ciImage(c.ciState, palette: palette), url: c.htmlURL, toolTip: tip)   // per-commit check-runs
    }

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private func commentItem(_ c: ReviewComment) -> NSMenuItem {
        let snippet = c.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let loc = c.location.map { " (\($0))" } ?? ""
        // Hover summary: author + verdict + location, then the full comment body.
        let tip = "\(c.author) · \(c.verdict.rawValue)\(loc)\n\n\(c.body)"
        return linkRow(title: "\(c.author): \(snippet.prefix(Self.snippetLimit))\(loc)", image: verdictImage(c.verdict),
                       url: c.htmlURL, toolTip: tip)
    }

    /// A clickable, optionally-themed menu row that opens `url` in the browser.
    /// `toolTip` shows the full summary on hover (titles are truncated).
    private func linkRow(title: String, image: NSImage?, url: URL?, toolTip: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: url != nil ? #selector(openPR(_:)) : nil, keyEquivalent: "")
        i.target = self
        i.representedObject = url
        tint(i) { $0.text }
        i.image = image
        i.toolTip = toolTip
        return i
    }

    private func disabledRow(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.indentationLevel = 1
        return i
    }

    private func verdictImage(_ v: ReviewVerdict) -> NSImage? {
        let symbol: String, color: NSColor
        switch v {
        case .approved:         symbol = "checkmark.seal.fill"; color = palette?.green ?? .systemGreen
        case .changesRequested: symbol = "xmark.octagon.fill";  color = palette?.red ?? .systemRed
        case .commented:        symbol = "text.bubble.fill";    color = palette?.subtext ?? .secondaryLabelColor
        }
        return coloredSymbol(symbol, color)
    }

    @objc private func signIn() {
        // Non-blocking: copies the code, opens the pre-filled URL, shows progress
        // in the menu status row. No modal that would stall polling.
        AppLog.statusMenu.info("Device sign-in action selected")
        model.signInWithDeviceFlow()
    }

    /// Add one account: name, host, token. This is also the only way in for a
    /// GitHub Enterprise account — device flow would need an OAuth App registered
    /// on that host, which a distributed build has no client id for.
    @objc private func pasteToken() {
        AppLog.statusMenu.info("Add account action selected")
        let alert = NSAlert()
        alert.messageText = "Add a GitHub account"
        // Least privilege: a read-only fine-grained PAT is preferred over "Sign in"
        // (device flow), whose classic `repo` scope grants write wholesale. Watching
        // needs no write at all — only merge/re-review/reply do.
        alert.informativeText = "Recommended: a fine-grained PAT (read-only) — "
            + "Pull requests: Read, Contents: Read, and Org ▸ Members: Read (for team review). "
            + "Add Pull requests: Write only if you want to merge, ask for a re-review, or reply "
            + "from the menu. A classic PAT works too but needs repo + read:org (grants write)."

        let name = NSTextField(frame: NSRect(x: 0, y: 56, width: 300, height: 24))
        name.placeholderString = "Name (e.g. Work)"
        let host = NSTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        host.placeholderString = "github.com (or github.acme.com for Enterprise)"
        // F4: a token is a secret — secure field (masked, no echo), focused so
        // the user can paste immediately.
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        token.placeholderString = "ghp_… or github_pat_…"
        // ⌘V works via the hidden Edit menu (main.swift). Belt-and-braces:
        // prefill from the clipboard if it looks like a token, plus an explicit
        // Paste button for mouse-only users.
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        if clip.hasPrefix("ghp_") || clip.hasPrefix("github_pat_") { token.stringValue = clip }

        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        fields.addSubview(name); fields.addSubview(host); fields.addSubview(token)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Paste from Clipboard")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = token
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.addAccount(label: name.stringValue, host: host.stringValue, token: token.stringValue)
        case .alertSecondButtonReturn:
            model.addAccount(label: name.stringValue, host: host.stringValue,
                             token: NSPasteboard.general.string(forType: .string) ?? "")
        default: break                                                                // Cancel
        }
    }

    // MARK: write actions (merge / re-review / reply)
    // The only menu rows that change anything on GitHub. Each confirms first,
    // hands off to AppModel, and shows whatever sentence comes back on failure.

    /// Both halves a write needs, carried through `representedObject`.
    private struct MergeTarget { let pr: PullRequest; let method: MergeMethod }
    private struct ReplyTarget { let pr: PullRequest; let comment: ReviewComment }

    /// "Merge ▸ {Merge commit, Squash, Rebase}". Omitted (not disabled) when the
    /// PR can't be merged from here: menu items in an autoenabled menu ignore
    /// `isEnabled`, and a draft or an unknown head SHA would only earn a 405.
    private func mergeControl(for pr: PullRequest) -> NSMenuItem? {
        guard !pr.isDraft, pr.headSHA != nil else { return nil }
        let parent = NSMenuItem(title: "Merge", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("arrow.triangle.merge")
        let sub = NSMenu()
        for method in MergeMethod.allCases {
            let i = NSMenuItem(title: method.label, action: #selector(mergePR(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = MergeTarget(pr: pr, method: method)
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    /// "Request re-review ▸ {people who already reviewed}". Only on your own PRs,
    /// and only once the thread has loaded — the names come from it, not a fetch.
    private func reReviewControl(for pr: PullRequest) -> NSMenuItem? {
        guard pr.isMine else { return nil }
        let logins = model.pastReviewers(of: pr)
        guard !logins.isEmpty else { return nil }
        let parent = NSMenuItem(title: "Request re-review", action: nil, keyEquivalent: "")
        parent.image = Self.menuIcon("arrow.clockwise.circle")
        let sub = NSMenu()
        for login in logins {
            let i = NSMenuItem(title: login, action: #selector(requestReReview(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = ReReviewTarget(pr: pr, login: login)
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }
    private struct ReReviewTarget { let pr: PullRequest; let login: String }

    /// The ⌥-variant of the comment row above it: click opens the comment in the
    /// browser, ⌥-click replies. An alternate item is the native way to add a
    /// second action without doubling the visible rows on a 30-comment thread.
    private func replyItem(_ c: ReviewComment, on pr: PullRequest) -> NSMenuItem {
        let i = NSMenuItem(title: "Reply to \(c.author)…", action: #selector(replyToComment(_:)), keyEquivalent: "")
        i.target = self
        i.keyEquivalentModifierMask = .option
        i.isAlternate = true
        i.image = Self.menuIcon("arrowshape.turn.up.left")
        i.representedObject = ReplyTarget(pr: pr, comment: c)
        return i
    }

    @objc private func mergePR(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? MergeTarget else { return }
        AppLog.statusMenu.info("Merge action selected method=\(t.method.rawValue, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "\(t.method.label) #\(t.pr.number)?"
        // Name the head SHA: the merge is pinned to it, so it's what actually lands.
        alert.informativeText = "\(t.pr.repoFullName) — \(t.pr.title)\n\n"
            + "Merges \(t.pr.headSHA?.prefix(7) ?? "the head commit") as seen at the last refresh. "
            + "PRPeek can't undo this."
        alert.addButton(withTitle: t.method.label)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { await self.model.merge(t.pr, method: t.method) }
    }

    @objc private func requestReReview(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? ReReviewTarget else { return }
        AppLog.statusMenu.info("Re-review action selected")
        run { await self.model.requestReview(t.pr, from: t.login) }
    }

    @objc private func replyToComment(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? ReplyTarget else { return }
        AppLog.statusMenu.info("Reply action selected")
        let alert = NSAlert()
        alert.messageText = "Reply to \(t.comment.author)"
        let quoted = t.comment.body.prefix(Self.replyQuoteLimit)
        let note = t.comment.inlineCommentID == nil
            ? "\(quoted)\n\nThis posts as a new PR comment — GitHub has no reply endpoint for a review."
            : "\(quoted)"
        alert.informativeText = "\(note)\n\n(Tip: Enter inserts newline; click Reply or press Return to submit)"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Reply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textView
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        run { await self.model.reply(to: t.comment, on: t.pr, body: body) }
    }

    private static let replyQuoteLimit = 240

    /// Fire a write and surface its failure sentence. Nothing to show on success —
    /// the refresh AppModel kicks repaints the menu.
    private func run(_ action: @escaping @MainActor () async -> String?) {
        Task { @MainActor in
            guard let message = await action() else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "GitHub turned that down"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: helpers
    private func action(_ title: String, _ sel: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = Self.menuIcon(symbol) }
        return i
    }

    /// Template SF Symbol for a menu row — tints to the menu's label color, so it
    /// follows the active theme without per-palette wiring.
    private static func menuIcon(_ name: String) -> NSImage? {
        PRPeek.menuIcon(name)
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
            AppLog.statusMenu.debug("PR submenu opened")
            model.markSeen(sub.pr)
            model.loadComments(for: sub.pr)
            model.loadCommits(for: sub.pr)
            populate(sub)   // reflect "Loading…" immediately; onSubmenuReload repopulates with content
        } else {
            AppLog.statusMenu.debug("Status menu opened")
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === item.menu {
            openMenus = 0
        } else {
            openMenus = max(0, openMenus - 1)
        }
        AppLog.statusMenu.debug("Menu closed remainingOpenMenus=\(self.openMenus, privacy: .public)")
        // When the whole menu tree has closed, apply any rebuild we deferred
        // while it was open (theme recolor, refreshed PR list, …).
        if openMenus == 0, pendingRender {
            pendingRender = false
            AppLog.statusMenu.debug("Flushing deferred menu render")
            render()
        }
    }
}

/// Menu wording for a merge method — display text, so it lives with the menu.
private extension MergeMethod {
    var label: String {
        switch self {
        case .merge:  return "Merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }
}

/// Human-readable "why it needs me" — inline suffix + hover tooltip.
private extension WaitReason {
    var short: String {
        switch self {
        case .reviewRequested: return "review requested"
        case .teamReview:      return "team review"
        case .ciFailing:       return "CI failing"
        }
    }
    var long: String {
        switch self {
        case .reviewRequested: return "Review requested of you"
        case .teamReview:      return "Your team's review was requested (CODEOWNERS)"
        case .ciFailing:       return "Your PR — CI is failing"
        }
    }
}
