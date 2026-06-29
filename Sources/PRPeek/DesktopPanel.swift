import AppKit

/// A borderless always-on-desktop widget: a small card listing your "needs me"
/// PRs plus counts. Lives at desktop-icon window level (behind real windows,
/// above the wallpaper), draggable, position remembered across launches.
/// ponytail: a plain NSWindow, not a WidgetKit widget — WidgetKit needs an
/// Xcode app + extension + App Group + signing, which this SPM build can't host.
@MainActor
final class DesktopPanel {
    private let model: AppModel
    private var window: NSWindow?
    private let label = NSTextField(wrappingLabelWithString: "")

    init(model: AppModel) {
        self.model = model
        if UserDefaults.standard.bool(forKey: "showPanel") { show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if window == nil { window = makeWindow() }
        UserDefaults.standard.set(true, forKey: "showPanel")
        refresh()
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "showPanel")
    }

    /// Re-render from the model. Cheap; called on every model change.
    func refresh() {
        guard isVisible else { return }
        label.attributedStringValue = renderText()
    }

    // MARK: build

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 320),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true
        w.setFrameAutosaveName("PRPeekDesktopPanel")

        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
        ])
        w.contentView = bg
        return w
    }

    // MARK: content

    private func renderText() -> NSAttributedString {
        let p = model.theme.palette
        let text = p?.text ?? .labelColor
        let sub = p?.subtext ?? .secondaryLabelColor
        let accent = p?.red ?? .systemRed

        let out = NSMutableAttributedString()
        out.append(line("PRPeek", font: .boldSystemFont(ofSize: 14), color: text))

        guard model.status != .signedOut else {
            out.append(line("\nNot signed in", font: .systemFont(ofSize: 12), color: sub))
            return out
        }

        let need = model.needsMe
        out.append(line(need.isEmpty ? "\nAll clear" : "\n\(need.count) need you",
                        font: .systemFont(ofSize: 12, weight: .semibold),
                        color: need.isEmpty ? sub : accent))
        for pr in need.prefix(8) {
            out.append(line("\n• \(pr.repoFullName)#\(pr.number)  \(pr.title)",
                            font: .systemFont(ofSize: 11), color: text))
        }
        if need.count > 8 { out.append(line("\n  +\(need.count - 8) more", font: .systemFont(ofSize: 11), color: sub)) }

        out.append(line("\n\nMine \(model.mine.count) · Open \(model.all.count)",
                        font: .systemFont(ofSize: 11), color: sub))
        if let updated = model.lastUpdated {
            out.append(line("\nUpdated \(StatusController.shortTime.string(from: updated))",
                            font: .systemFont(ofSize: 10), color: sub))
        }
        return out
    }

    private func line(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }
}
