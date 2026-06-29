import AppKit

/// Renders the menubar icon. Color path uses isTemplate=false (T7 spike proved
/// color survives only that way). Counts are baked into a pre-rendered NSImage.
enum BadgeRenderer {
    static func icon(needsMe: Int, total: Int, signedOut: Bool, offline: Bool,
                     accent: NSColor = .systemRed) -> NSImage {
        if signedOut { return symbol("person.crop.circle.badge.questionmark", template: true) }
        if offline { return symbol("wifi.slash", template: true) }
        if needsMe > 0 {
            return pill(text: "\(needsMe)", fill: accent)   // attention: color survives (theme accent)
        }
        if total > 0 {
            return numberTemplate("\(total)")  // calm: monochrome digits (readable, HIG menubar color)
        }
        return symbol("checkmark.circle", template: true)       // inbox zero
    }

    /// Calm-state count: digits only (transparent background), template so macOS
    /// tints them with the menu-bar color. A FILLED pill as a template would mask
    /// to a solid blob and hide the number — F1.
    static func numberTemplate(_ text: String) -> NSImage {
        let h = NSStatusBar.system.thickness - 4
        let font = NSFont.monospacedDigitSystemFont(ofSize: h * 0.74, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let image = NSImage(size: NSSize(width: ceil(size.width) + 2, height: h))
        image.lockFocus()
        (text as NSString).draw(at: NSPoint(x: 1, y: (h - size.height) / 2),
                                withAttributes: [.font: font, .foregroundColor: NSColor.black])
        image.unlockFocus()
        image.isTemplate = true   // opaque digit shapes -> rendered in the system menu-bar color
        return image
    }

    /// Colored rounded-rect badge (the headline). template=false keeps the fill.
    static func pill(text: String, fill: NSColor, template: Bool = false) -> NSImage {
        let thickness = NSStatusBar.system.thickness
        let height = thickness - 5
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = max(height, textSize.width + height * 0.7)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).addClip()
        fill.setFill()
        rect.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        (text as NSString).draw(at: NSPoint(x: (width - textSize.width) / 2,
                                            y: (height - textSize.height) / 2), withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = template
        return image
    }

    static func symbol(_ name: String, template: Bool) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: name)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        img.isTemplate = template
        return img
    }
}
