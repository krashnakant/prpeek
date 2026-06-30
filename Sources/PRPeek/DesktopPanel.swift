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

        guard model.status != .signedOut else {
            rowsStack.addArrangedSubview(messageRow("Not signed in"))
            return
        }

        let needs = model.needsMe
        if needs.isEmpty {
            rowsStack.addArrangedSubview(messageRow("All clear"))
        } else {
            for pr in needs.prefix(8) {
                rowsStack.addArrangedSubview(prRow(pr))
            }
            if needs.count > 8 {
                rowsStack.addArrangedSubview(messageRow("+\(needs.count - 8) more in the menu"))
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

    @objc private func openPR(_ sender: PRRowButton) {
        guard let url = sender.url else { return }
        AppLog.desktopPanel.info("Desktop panel PR row opened")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Build

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 390),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.setFrameAutosaveName("PRPeekDesktopPanel")
        w.contentView = rootView()
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
        rowsStack.spacing = 6
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
        let row = PRRowButton()
        row.url = pr.htmlURL
        row.target = self
        row.action = #selector(openPR(_:))
        row.isBordered = false
        row.bezelStyle = .regularSquare
        row.alignment = .left
        row.imagePosition = .imageLeft
        row.image = ciImage(pr.ciState, palette: model.palette)
        row.toolTip = "\(pr.repoFullName)#\(pr.number)\n\(pr.title)"
        row.attributedTitle = rowTitle(pr)
        row.setButtonType(.momentaryChange)
        row.contentTintColor = model.palette?.text ?? .labelColor
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return row
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

    private func rowTitle(_ pr: PullRequest) -> NSAttributedString {
        let title = "\(pr.repoFullName)#\(pr.number)  \(pr.title)"
        let p = model.palette
        let color = p?.text ?? NSColor.labelColor
        let sub = p?.subtext ?? NSColor.secondaryLabelColor
        let out = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
        )
        if let reason = pr.waitReason {
            out.append(NSAttributedString(
                string: "  -  \(reason.panelLabel)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: sub]
            ))
        }
        return out
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

private final class PRRowButton: NSButton {
    var url: URL?
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
