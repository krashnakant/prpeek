import AppKit
import PRPeekCore

/// A compact floating PRPeek panel with native controls. It is intentionally
/// AppKit: the app is an SPM menubar shell, and this surface needs window-level
/// drag/float behavior plus direct status-menu integration.
@MainActor
final class DesktopPanel: NSObject {
    private static let showKey = "showPanel"
    private static let keepOnTopKey = "desktopPanelKeepOnTop"

    private let model: AppModel
    private var window: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "PRPeek")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")

    init(model: AppModel) {
        self.model = model
        super.init()
        if UserDefaults.standard.bool(forKey: Self.showKey) { show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var keepOnTop: Bool {
        if UserDefaults.standard.object(forKey: Self.keepOnTopKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: Self.keepOnTopKey)
    }

    func toggle() {
        let willShow = !isVisible
        AppLog.desktopPanel.info("Desktop panel toggled visible=\(willShow, privacy: .public)")
        isVisible ? hide() : show()
    }

    func show() {
        if window == nil { window = makeWindow() }
        UserDefaults.standard.set(true, forKey: Self.showKey)
        applyWindowPlacement()
        AppLog.desktopPanel.info("Desktop panel shown")
        window?.orderFrontRegardless()
        refresh()
    }

    func hide() {
        window?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.showKey)
        AppLog.desktopPanel.info("Desktop panel hidden")
    }

    func setKeepOnTop(_ on: Bool) {
        guard on != keepOnTop else { return }
        UserDefaults.standard.set(on, forKey: Self.keepOnTopKey)
        applyWindowPlacement()
        AppLog.desktopPanel.info("Desktop panel keep-on-top changed enabled=\(on, privacy: .public)")
    }

    /// Re-render from the model. Cheap; called on every model change.
    func refresh() {
        guard isVisible else { return }
        applyTheme()
        summaryLabel.stringValue = summaryText()
        footerLabel.stringValue = footerText()
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let p = model.palette
        guard model.status != .signedOut else {
            addRow(emptyState("person.crop.circle.badge.questionmark",
                              p?.subtext ?? .secondaryLabelColor, "Not signed in"))
            return
        }

        let needs = model.needsMe
        if needs.isEmpty {
            if model.status == .offline {
                addRow(emptyState("wifi.slash", p?.yellow ?? .systemYellow, "Offline — showing cached"))
            } else {
                addRow(emptyState("checkmark.circle.fill", p?.green ?? .systemGreen, "All clear"))
            }
        } else {
            let cap = 8
            for pr in needs.prefix(cap) {
                addRow(prRow(pr))
            }
            if needs.count > cap {
                addRow(messageRow("+\(needs.count - cap) more in the menu"))
            }
        }
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        AppLog.desktopPanel.info("Desktop panel refresh clicked")
        model.kickRefresh()
    }

    @objc private func closeClicked() {
        AppLog.desktopPanel.info("Desktop panel close clicked")
        hide()
    }

    // MARK: - Build

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 390),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false   // we hold a strong ref; AppKit must not release on close
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        // Pin width to 340 — a borderless window otherwise grows to fit the
        // longest untruncated title instead of truncating it.
        w.contentMinSize = NSSize(width: 340, height: 200)
        w.contentMaxSize = NSSize(width: 340, height: 4000)
        w.setFrameAutosaveName("PRPeekDesktopPanel")
        w.contentView = rootView()
        w.setContentSize(NSSize(width: 340, height: 390))
        applyWindowPlacement(w)
        return w
    }

    private func applyWindowPlacement(_ target: NSWindow? = nil) {
        guard let w = target ?? window else { return }
        if keepOnTop {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    private func rootView() -> NSView {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 7
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(stack)
        stack.addArrangedSubview(headerView())
        stack.addArrangedSubview(rowsContainer())
        stack.addArrangedSubview(footerLabel)

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        return bg
    }

    private func headerView() -> NSView {
        let header = DraggableHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(summaryLabel)

        let refreshButton = iconButton("arrow.clockwise", action: #selector(refreshClicked), label: "Refresh")
        let closeButton = iconButton("xmark", action: #selector(closeClicked), label: "Hide")

        header.addSubview(titleStack)
        header.addSubview(refreshButton)
        header.addSubview(closeButton)

        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 38),
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -10),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func rowsContainer() -> NSView {
        let clip = NSScrollView()
        clip.drawsBackground = false
        clip.hasVerticalScroller = true
        clip.borderType = .noBorder
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.documentView = rowsStack

        NSLayoutConstraint.activate([
            rowsStack.widthAnchor.constraint(equalTo: clip.widthAnchor),
            clip.heightAnchor.constraint(equalToConstant: 270),
        ])
        return clip
    }

    private func prRow(_ pr: PullRequest) -> NSView {
        PRCardView(pr: pr, palette: model.palette) {
            AppLog.desktopPanel.info("Desktop panel PR row opened")
            NSWorkspace.shared.open(pr.htmlURL)
        }
    }

    /// Add a row that fills the panel width — a vertical NSStackView otherwise
    /// sizes each child to its content and centers it (rows scatter, long titles
    /// never truncate).
    private func addRow(_ view: NSView) {
        rowsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func messageRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return label
    }

    /// Centered big-glyph + caption for the empty/offline/signed-out body.
    private func emptyState(_ symbol: String, _ color: NSColor, _ text: String) -> NSView {
        let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage())

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = model.palette?.subtext ?? .secondaryLabelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 200).isActive = true   // fills the body so it reads centered
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func iconButton(_ symbol: String, action: Selector, label: String) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    // MARK: - Content

    private func summaryText() -> String {
        switch model.status {
        case .signedOut: return "Not signed in"
        case .loading: return "Refreshing..."
        case .offline: return "Offline, cached"
        case .rateLimited: return "Rate limited"
        case .error: return "Needs attention"
        default:
            let need = model.needsMe.count
            return need == 0 ? "All clear" : "\(need) need you"
        }
    }

    private func footerText() -> String {
        var parts = ["Mine \(model.mine.count)", "Open \(model.all.count)"]
        if let updated = model.lastUpdated {
            parts.append("Updated \(StatusController.shortTime.string(from: updated))")
        }
        return parts.joined(separator: "  -  ")
    }

    private func applyTheme() {
        let p = model.palette
        titleLabel.textColor = p?.text ?? .labelColor
        summaryLabel.textColor = model.needsMe.isEmpty ? (p?.subtext ?? .secondaryLabelColor) : (p?.red ?? .systemRed)
        footerLabel.textColor = p?.subtext ?? .secondaryLabelColor
    }

    /// Template SF Symbol for the header buttons — tints to the system label color.
    private static func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }
}

private final class DraggableHeaderView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// A two-line PR card: a tinted CI chip, the PR title, and a meta line
/// (repo#number + a "why it waits" pill). Clickable (opens the PR) with a hover
/// highlight — a plain NSButton can't host this two-line layout cleanly.
private final class PRCardView: NSView {
    private let onOpen: () -> Void
    private var hovered = false

    init(pr: PullRequest, palette: Palette?, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        // labelColor-based so the card reads on light AND dark themes (white-only
        // fill vanished on the System/Light appearance).
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 46).isActive = true

        // CI chip: a tinted rounded box around the colored CI glyph.
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        chip.layer?.backgroundColor = ciColor(pr.ciState, palette: palette).withAlphaComponent(0.16).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: ciImage(pr.ciState, palette: palette))
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(glyph)

        let title = NSTextField(labelWithString: pr.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = palette?.text ?? .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        title.setAccessibilityElement(false)   // the card itself is the a11y button

        let repo = NSTextField(labelWithString: "\(pr.repoFullName)#\(pr.number)")
        repo.font = .systemFont(ofSize: 11)
        repo.textColor = palette?.subtext ?? .secondaryLabelColor
        repo.lineBreakMode = .byTruncatingTail
        repo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repo.setAccessibilityElement(false)
        repo.translatesAutoresizingMaskIntoConstraints = false

        let meta = NSStackView(views: [repo])
        meta.spacing = 6
        meta.translatesAutoresizingMaskIntoConstraints = false
        if let reason = pr.waitReason { meta.addArrangedSubview(Self.reasonPill(reason, palette: palette)) }

        addSubview(chip); addSubview(title); addSubview(meta)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 22),
            chip.heightAnchor.constraint(equalToConstant: 22),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
            glyph.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])

        toolTip = "\(pr.repoFullName)#\(pr.number)\n\(pr.title)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(pr.repoFullName) number \(pr.number), \(pr.title)")
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered ? 0.11 : 0.06).cgColor
    }
    override func mouseUp(with event: NSEvent) { onOpen() }
    // Whole card is one click target — without this, the title/repo NSTextField
    // labels return themselves from hitTest and swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with e: NSEvent) { hovered = false; updateBackground() }

    /// Small tinted "why it waits" pill. ponytail: review/team use system accent
    /// colors — the Catppuccin Palette has no blue/mauve to map them to.
    private static func reasonPill(_ reason: WaitReason, palette: Palette?) -> NSView {
        let color: NSColor
        switch reason {
        case .reviewRequested: color = .systemPurple
        case .teamReview:      color = .systemBlue
        case .ciFailing:       color = palette?.red ?? .systemRed
        }
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 7
        pill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: reason.panelLabel)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }
}

private extension WaitReason {
    var panelLabel: String {
        switch self {
        case .reviewRequested: return "review"
        case .teamReview: return "team"
        case .ciFailing: return "CI"
        }
    }
}
