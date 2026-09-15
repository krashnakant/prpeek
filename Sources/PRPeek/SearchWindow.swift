import AppKit
import PRPeekCore

/// Keyboard-first search across ALL loaded PRs — the menu caps each section at
/// 15 and can't search, so this is the surface for "find that one PR". A titled
/// window with a search field over an NSTableView: type to filter, ↑↓ to move,
/// Enter to open, Esc to close.
/// ponytail: filters the already-loaded `model.all` in memory — no new fetch.
@MainActor
final class SearchWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private let searchField = NSSearchField()
    private let table = KeyTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var results: [PullRequest] = []

    init(model: AppModel) { self.model = model; super.init() }

    var isVisible: Bool { window?.isVisible ?? false }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        if window == nil { window = makeWindow() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // accessory app needs this to take focus
        window?.makeFirstResponder(searchField)
    }
    func hide() { window?.orderOut(nil) }

    /// Keep results live while the model refreshes underneath an open window.
    func refresh() { if isVisible { reload() } }

    // MARK: build

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Search PRs"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PRPeekSearchWindow")
        w.center()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter by repo, number, title, or author"
        searchField.delegate = self

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 24   // fits the CI glyph the panel and menu also show
        table.addTableColumn(NSTableColumn(identifier: .init("pr")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onEnter = { [weak self] in self?.openSelected() }
        table.onEscape = { [weak self] in self?.hide() }
        table.onCopy = { [weak self] in self?.copySelectedURL() }
        table.contextMenuProvider = { [weak self] in self?.makeContextMenu() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = w.contentView!
        content.addSubview(searchField)
        content.addSubview(countLabel)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            countLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
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
        let q = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let all = model.all
        results = q.isEmpty ? all : all.filter {
            "\($0.repoFullName)#\($0.number) \($0.title) \($0.author)".lowercased().contains(q)
        }
        table.reloadData()
        countLabel.stringValue = results.isEmpty
            ? (all.isEmpty ? "No PRs loaded" : "No matches")
            : "\(results.count) of \(all.count)"
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(iv); c.addSubview(tf)
            c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalToConstant: 13),
                iv.heightAnchor.constraint(equalToConstant: 13),
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        let pr = results[row]
        cell.imageView?.image = ciImage(pr.ciState, palette: model.palette)
        cell.textField?.attributedStringValue = Self.rowText(pr, palette: model.palette,
                                                            freshness: model.freshness(pr),
                                                            account: model.accountLabel(for: pr))
        cell.textField?.toolTip = pr.waitReason.map { "Waiting on you — \($0.panelLabel)" }
        return cell
    }

    /// Same visual language as the panel card and the menu row: dimmed
    /// repo#number, full-strength title, reason in its own color.
    private static func rowText(_ pr: PullRequest, palette: Palette?,
                                freshness: PRFreshness?, account: String?) -> NSAttributedString {
        let dim = palette?.subtext ?? NSColor.secondaryLabelColor
        let s = NSMutableAttributedString(string: "", attributes: [.foregroundColor: dim])
        s.append(NSAttributedString(string: accountTag(account), attributes: [.foregroundColor: dim]))
        s.append(NSAttributedString(string: "\(pr.repoFullName)#\(pr.number)  ",
                                    attributes: [.foregroundColor: dim]))
        s.append(NSAttributedString(string: pr.title,
                                    attributes: [.foregroundColor: palette?.text ?? NSColor.labelColor]))
        let tagFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        if let reason = pr.waitReason {
            s.append(NSAttributedString(
                string: "  \(reason.panelLabel)",
                attributes: [.foregroundColor: reasonColor(reason, palette: palette), .font: tagFont]))
        }
        if let freshness, let text = freshness.pillLabel {
            s.append(NSAttributedString(
                string: "  \(text)",
                attributes: [.foregroundColor: freshnessColor(freshness, palette: palette), .font: tagFont]))
        }
        return s
    }

    // Live filter as the user types.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        reload()
    }

    /// Focus starts in the field, so Esc and ↑↓ have to work from there too —
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
        countLabel.stringValue = "Unmuted \(pr.repoFullName)#\(pr.number)"
    }

    @objc private func snoozeSelected1h() {
        guard let pr = selectedPR else { return }
        model.mute(pr, for: 3600)
        countLabel.stringValue = "Snoozed \(pr.repoFullName)#\(pr.number) for 1 hour"
    }

    @objc private func snoozeSelected4h() {
        guard let pr = selectedPR else { return }
        model.mute(pr, for: 14400)
        countLabel.stringValue = "Snoozed \(pr.repoFullName)#\(pr.number) for 4 hours"
    }

    @objc private func snoozeSelectedUntilUpdated() {
        guard let pr = selectedPR else { return }
        model.muteUntilUpdated(pr)
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

/// NSTableView that reports Return/Escape/Copy so the window can open, dismiss, or copy.
final class KeyTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return
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
