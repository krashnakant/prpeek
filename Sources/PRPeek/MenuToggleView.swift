import AppKit

/// A custom menu-item view that does NOT dismiss the menu when clicked — the
/// trick for "sticky" toggles (theme, repo filters) you flip several times
/// without the menu closing. Standard NSMenuItems can't do this.
/// Draws its own checkmark + hover highlight; `isOn` is re-read on each redraw so
/// siblings update in place via `refresh()` (no full menu rebuild).
final class MenuToggleView: NSView {
    private let title: String
    private let tint: NSColor?      // Catppuccin text color; nil = system label color
    private let isOn: () -> Bool
    private let action: () -> Void
    private var hovered = false

    init(title: String, tint: NSColor? = nil, isOn: @escaping () -> Bool, action: @escaping () -> Void) {
        self.title = title; self.tint = tint; self.isOn = isOn; self.action = action
        let font = NSFont.menuFont(ofSize: 0)
        let w = (title as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(w) + 46, height: 22))
        setAccessibilityRole(.checkBox)        // custom views lose VoiceOver labels otherwise
        setAccessibilityLabel(title)
    }

    override func accessibilityValue() -> Any? { isOn() }
    override func isAccessibilityElement() -> Bool { true }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Re-derive checked state and repaint (called on sibling toggles after a tap).
    func refresh() { needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = hovered ? .selectedMenuItemTextColor : (tint ?? .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: color]
        if isOn() { ("✓" as NSString).draw(at: NSPoint(x: 14, y: 3), withAttributes: attrs) }
        (title as NSString).draw(at: NSPoint(x: 30, y: 3), withAttributes: attrs)
    }

    override func mouseUp(with event: NSEvent) { action() }   // menu stays open

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovered = false; needsDisplay = true }
}
