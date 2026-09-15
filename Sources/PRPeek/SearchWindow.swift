import AppKit
import PRPeekCore

/// Keyboard-first search across ALL loaded PRs — the menu caps each section at
/// 15 and can't search, so this is the surface for "find that one PR". A titled
/// window with a search field over an NSTableView: type to filter, ↑↓ to move,
/// Enter to open, Esc to close.
/// ponytail: filters the already-loaded `model.all` in memory — no new fetch.
@MainActor
final class SearchWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Scope: Int, CaseIterable {
        case all = 0
        case needsMe = 1
        case mine = 2
        case muted = 3

        var baseTitle: String {
            switch self {
            case .all: return "All"
            case .needsMe: return "Needs Me"
            case .mine: return "Mine"
            case .muted: return "Muted"
            }
        }
    }

    private let model: AppModel
    private var window: NSWindow?
    private let searchField = KeySearchField()
    private let scopeControl = NSSegmentedControl()
    private let table = KeyTableView()
    private let countLabel = NSTextField(labelWithString: "")

    private struct SearchItem {
        let pr: PullRequest
        let searchableText: String
    }
    private var indexedPRs: [SearchItem] = []
    private var results: [PullRequest] = []

    init(model: AppModel) { self.model = model; super.init() }

    var isVisible: Bool { window?.isVisible ?? false }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        if window == nil { window = makeWindow() }
        reindex()
        updateScopeCounts()
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // accessory app needs this to take focus
        window?.makeFirstResponder(searchField)
    }
    func hide() { window?.orderOut(nil) }

    /// Keep results live while the model refreshes underneath an open window.
    func refresh() {
        if isVisible {
            reindex()
            updateScopeCounts()
            reload()
        }
    }

    private func reindex() {
        indexedPRs = model.all.map { pr in
            let acct = model.accountLabel(for: pr) ?? ""
            let text = "\(pr.repoFullName)#\(pr.number) \(pr.title) \(pr.author) \(acct)".lowercased()
            return SearchItem(pr: pr, searchableText: text)
        }
    }

    private func updateScopeCounts() {
        let allCount = model.all.count
        let needsCount = model.needsMe.count
        let mineCount = model.mine.count
        let mutedCount = model.muted.count
        scopeControl.setLabel("All (\(allCount))", forSegment: Scope.all.rawValue)
        scopeControl.setLabel("Needs Me (\(needsCount))", forSegment: Scope.needsMe.rawValue)
        scopeControl.setLabel("Mine (\(mineCount))", forSegment: Scope.mine.rawValue)
        scopeControl.setLabel("Muted (\(mutedCount))", forSegment: Scope.muted.rawValue)
    }

    private func selectScope(_ index: Int) {
        guard index >= 0, index < scopeControl.segmentCount else { return }
        scopeControl.selectedSegment = index
        reload()
    }

    @objc private func scopeChanged() {
        reload()
    }

    // MARK: build

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Search PRs"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PRPeekSearchWindow")
        w.minSize = NSSize(width: 480, height: 300)
        w.center()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter by repo, number, title, or author"
        searchField.delegate = self
        searchField.onScopeShortcut = { [weak self] index in self?.selectScope(index) }

        scopeControl.segmentCount = Scope.allCases.count
        for scope in Scope.allCases {
            scopeControl.setLabel(scope.baseTitle, forSegment: scope.rawValue)
        }
        scopeControl.selectedSegment = Scope.all.rawValue
        scopeControl.segmentDistribution = .fillEqually
        scopeControl.trackingMode = .selectOne
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.setToolTip("All PRs (⌘1)", forSegment: Scope.all.rawValue)
        scopeControl.setToolTip("PRs waiting on your review (⌘2)", forSegment: Scope.needsMe.rawValue)
        scopeControl.setToolTip("PRs created by you (⌘3)", forSegment: Scope.mine.rawValue)
        scopeControl.setToolTip("Muted / snoozed PRs (⌘4)", forSegment: Scope.muted.rawValue)
        updateScopeCounts()

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .regular

        let col = NSTableColumn(identifier: .init("pr"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onEnter = { [weak self] in self?.openSelected() }
        table.onEscape = { [weak self] in self?.hide() }
        table.onCopy = { [weak self] in self?.copySelectedURL() }
        table.onScopeShortcut = { [weak self] index in self?.selectScope(index) }
        table.contextMenuProvider = { [weak self] in self?.makeContextMenu() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = w.contentView!
        content.addSubview(searchField)
        content.addSubview(scopeControl)
        content.addSubview(countLabel)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            scopeControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scopeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scopeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            countLabel.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        return w
    }

    // MARK: data

    private func reload() {
        let q = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelectedID = selectedPR?.id

        let currentScope = Scope(rawValue: scopeControl.selectedSegment) ?? .all
        let scopedPRs: [SearchItem]
        switch currentScope {
        case .all:
            scopedPRs = indexedPRs
        case .needsMe:
            let set = Set(model.needsMe.map(\.id))
            scopedPRs = indexedPRs.filter { set.contains($0.pr.id) }
        case .mine:
            let set = Set(model.mine.map(\.id))
            scopedPRs = indexedPRs.filter { set.contains($0.pr.id) }
        case .muted:
            let set = Set(model.muted.map(\.id))
            scopedPRs = indexedPRs.filter { set.contains($0.pr.id) }
        }

        if q.isEmpty {
            results = scopedPRs.map(\.pr)
        } else {
            let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
            results = scopedPRs.filter { item in
                terms.allSatisfy { item.searchableText.contains($0) }
            }.map(\.pr)
        }

        table.reloadData()

        let total = scopedPRs.count
        if results.isEmpty {
            countLabel.stringValue = total == 0 ? "No PRs in \(currentScope.baseTitle.lowercased())" : (q.isEmpty ? "No PRs" : "No matches for \"\(q)\"")
            table.deselectAll(nil)
        } else {
            if q.isEmpty {
                countLabel.stringValue = "\(results.count) open PR\(results.count == 1 ? "" : "s")"
            } else {
                countLabel.stringValue = "\(results.count) of \(total) PR\(total == 1 ? "" : "s")"
            }
            if let prevID = previousSelectedID, let matchIdx = results.firstIndex(where: { $0.id == prevID }) {
                table.selectRowIndexes([matchIdx], byExtendingSelection: false)
                table.scrollRowToVisible(matchIdx)
            } else {
                table.selectRowIndexes([0], byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PRSearchCellView.reuseIdentifier, owner: self) as? PRSearchCellView)
            ?? PRSearchCellView(frame: .zero)
        cell.identifier = PRSearchCellView.reuseIdentifier
        guard results.indices.contains(row) else { return cell }
        cell.configure(with: results[row], model: model)
        return cell
    }

    // Live filter as the user types.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        reload()
    }

    /// Focus starts in the field, so Esc, Enter, and ↑↓ have to work from there too —
    /// NSSearchField otherwise eats Esc to clear the text and never closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let step = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = min(max(table.selectedRow + step, 0), results.count - 1)
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSText.copy(_:)):
            if textView.selectedRange.length == 0, selectedPR != nil {
                copySelectedURL()
                return true
            }
            return false
        default:
            return false
        }
    }

    private var selectedPR: PullRequest? {
        let row = table.selectedRow >= 0 ? table.selectedRow : (results.isEmpty ? -1 : 0)
        guard results.indices.contains(row) else { return nil }
        return results[row]
    }

    @objc private func openSelected() {
        guard let pr = selectedPR else { return }
        model.open(pr)   // via the model so opening clears the "new" marker
        hide()
    }

    @objc private func copySelectedURL() {
        guard let pr = selectedPR else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.htmlURL.absoluteString, forType: .string)
        countLabel.stringValue = "Copied \(pr.repoFullName)#\(pr.number) URL to clipboard"
    }

    @objc private func copySelectedTitle() {
        guard let pr = selectedPR else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.title, forType: .string)
        countLabel.stringValue = "Copied \(pr.repoFullName)#\(pr.number) title to clipboard"
    }

    @objc private func unmuteSelected() {
        guard let pr = selectedPR else { return }
        model.unmute(pr)
        updateScopeCounts()
        reload()
        countLabel.stringValue = "Unmuted \(pr.repoFullName)#\(pr.number)"
    }

    @objc private func snoozeSelected1h() {
        guard let pr = selectedPR else { return }
        model.mute(pr, for: 3600)
        updateScopeCounts()
        reload()
        countLabel.stringValue = "Snoozed \(pr.repoFullName)#\(pr.number) for 1 hour"
    }

    @objc private func snoozeSelected4h() {
        guard let pr = selectedPR else { return }
        model.mute(pr, for: 14400)
        updateScopeCounts()
        reload()
        countLabel.stringValue = "Snoozed \(pr.repoFullName)#\(pr.number) for 4 hours"
    }

    @objc private func snoozeSelectedUntilUpdated() {
        guard let pr = selectedPR else { return }
        model.muteUntilUpdated(pr)
        updateScopeCounts()
        reload()
        countLabel.stringValue = "Snoozed \(pr.repoFullName)#\(pr.number) until updated"
    }

    private func makeContextMenu() -> NSMenu? {
        guard let pr = selectedPR else { return nil }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open in Browser", action: #selector(openSelected), keyEquivalent: "")
        open.target = self
        open.image = menuIcon("arrow.up.right.square")
        menu.addItem(open)

        let copyURL = NSMenuItem(title: "Copy URL", action: #selector(copySelectedURL), keyEquivalent: "")
        copyURL.target = self
        copyURL.image = menuIcon("doc.on.doc")
        menu.addItem(copyURL)

        let copyTitle = NSMenuItem(title: "Copy Title", action: #selector(copySelectedTitle), keyEquivalent: "")
        copyTitle.target = self
        copyTitle.image = menuIcon("text.alignleft")
        menu.addItem(copyTitle)

        menu.addItem(.separator())

        if model.isMuted(pr) {
            let unmute = NSMenuItem(title: "Unmute", action: #selector(unmuteSelected), keyEquivalent: "")
            unmute.target = self
            unmute.image = menuIcon("bell")
            menu.addItem(unmute)
        } else {
            let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
            snooze.image = menuIcon("moon.zzz")
            let sub = NSMenu()
            let s1 = NSMenuItem(title: "1 hour", action: #selector(snoozeSelected1h), keyEquivalent: "")
            s1.target = self
            sub.addItem(s1)
            let s4 = NSMenuItem(title: "4 hours", action: #selector(snoozeSelected4h), keyEquivalent: "")
            s4.target = self
            sub.addItem(s4)
            let sUp = NSMenuItem(title: "Until it updates", action: #selector(snoozeSelectedUntilUpdated), keyEquivalent: "")
            sUp.target = self
            sub.addItem(sUp)
            snooze.submenu = sub
            menu.addItem(snooze)
        }
        return menu
    }
}

/// Dedicated, high-performance two-line cell for PR search results.
/// Never overlaps: lines are strictly pinned to 1 line each with tail truncation.
private final class PRSearchCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PRSearchCell")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let repoLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let accountBadge = makePill()
    private let reasonBadge = makePill()
    private let freshnessBadge = makePill()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError("not from nib") }

    private static func makePill() -> (view: NSView, label: NSTextField) {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return (pill, label)
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.cell?.isScrollable = true

        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        repoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        repoLabel.textColor = .secondaryLabelColor
        repoLabel.lineBreakMode = .byTruncatingTail
        repoLabel.maximumNumberOfLines = 1
        repoLabel.usesSingleLineMode = true
        repoLabel.cell?.wraps = false
        repoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.usesSingleLineMode = true
        authorLabel.cell?.wraps = false
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metaStack = NSStackView(views: [repoLabel, authorLabel, accountBadge.view, reasonBadge.view, freshnessBadge.view])
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaStack.orientation = .horizontal
        metaStack.spacing = 6
        metaStack.alignment = .centerY

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(metaStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            metaStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            metaStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        ])
    }

    func configure(with pr: PullRequest, model: AppModel) {
        let p = model.palette
        iconView.image = ciImage(pr.ciState, palette: p)

        let cleanTitle = pr.title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        titleLabel.stringValue = cleanTitle
        titleLabel.textColor = p?.text ?? .labelColor

        repoLabel.stringValue = "\(pr.repoFullName)#\(pr.number)"
        repoLabel.textColor = p?.subtext ?? .secondaryLabelColor

        authorLabel.stringValue = "by \(pr.author)"
        authorLabel.textColor = (p?.subtext ?? .secondaryLabelColor).withAlphaComponent(0.8)

        if let acct = model.accountLabel(for: pr) {
            accountBadge.label.stringValue = acct
            let c = p?.subtext ?? .secondaryLabelColor
            accountBadge.label.textColor = c
            accountBadge.view.layer?.backgroundColor = c.withAlphaComponent(0.14).cgColor
            accountBadge.view.isHidden = false
        } else {
            accountBadge.view.isHidden = true
        }

        if let reason = pr.waitReason {
            reasonBadge.label.stringValue = reason.panelLabel
            let c = reasonColor(reason, palette: p)
            reasonBadge.label.textColor = c
            reasonBadge.view.layer?.backgroundColor = c.withAlphaComponent(0.16).cgColor
            reasonBadge.view.isHidden = false
        } else {
            reasonBadge.view.isHidden = true
        }

        let freshness = model.freshness(pr)
        if let text = freshness?.pillLabel, let f = freshness {
            freshnessBadge.label.stringValue = text
            let c = freshnessColor(f, palette: p)
            freshnessBadge.label.textColor = c
            freshnessBadge.view.layer?.backgroundColor = c.withAlphaComponent(0.16).cgColor
            freshnessBadge.view.isHidden = false
        } else {
            freshnessBadge.view.isHidden = true
        }

        toolTip = "\(pr.repoFullName)#\(pr.number)\n\(cleanTitle)\nAuthor: \(pr.author)"
    }
}

/// NSSearchField that traps Cmd+1..4 so users can switch scopes without tabbing out of the search bar.
final class KeySearchField: NSSearchField {
    var onScopeShortcut: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "1": onScopeShortcut?(0); return true
            case "2": onScopeShortcut?(1); return true
            case "3": onScopeShortcut?(2); return true
            case "4": onScopeShortcut?(3); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSTableView that reports Return/Escape/Copy/Cmd+1-4 so the window can open, dismiss, copy, or switch scopes.
final class KeyTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var onScopeShortcut: ((Int) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "c":
                onCopy?()
                return
            case "1":
                onScopeShortcut?(0); return
            case "2":
                onScopeShortcut?(1); return
            case "3":
                onScopeShortcut?(2); return
            case "4":
                onScopeShortcut?(3); return
            default:
                break
            }
        }
        switch event.keyCode {
        case 36, 76: onEnter?()       // Return, keypad Enter
        case 53:     onEscape?()      // Escape
        default:     super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let r = row(at: pt)
        if r >= 0 && r < numberOfRows {
            selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        }
        return contextMenuProvider?() ?? super.menu(for: event)
    }
}
