import AppKit

/// App theme. System/Light/Dark just drive `NSApp.appearance`. The four
/// Catppuccin flavors additionally recolor the parts of the menu we draw
/// ourselves (text, CI/verdict symbols, section headers, badge) — the menu's
/// background stays system-vibrant, which AppKit's NSMenu won't let us repaint.
enum Theme: String, CaseIterable {
    case system, light, dark, latte, frappe, macchiato, mocha

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .latte: return "Catppuccin Latte"
        case .frappe: return "Catppuccin Frappé"
        case .macchiato: return "Catppuccin Macchiato"
        case .mocha: return "Catppuccin Mocha"
        }
    }

    /// Light flavors get .aqua, dark flavors .darkAqua, System follows the OS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light, .latte: return .aqua
        case .dark, .frappe, .macchiato, .mocha: return .darkAqua
        }
    }

    /// nil = use system colors (labelColor, systemGreen, …). Non-nil = Catppuccin.
    var palette: Palette? {
        switch self {
        case .system, .light, .dark: return nil
        case .latte:     return Palette(text: "#4c4f69", subtext: "#6c6f85", green: "#40a02b", red: "#d20f39", yellow: "#df8e1d")
        case .frappe:    return Palette(text: "#c6d0f5", subtext: "#a5adce", green: "#a6d189", red: "#e78284", yellow: "#e5c890")
        case .macchiato: return Palette(text: "#cad3f5", subtext: "#a5adcb", green: "#a6da95", red: "#ed8796", yellow: "#eed49f")
        case .mocha:     return Palette(text: "#cdd6f4", subtext: "#a6adc8", green: "#a6e3a1", red: "#f38ba8", yellow: "#f9e2af")
        }
    }

    var nsAppearance: NSAppearance? { appearanceName.flatMap(NSAppearance.init(named:)) }

    static func apply(_ t: Theme) { NSApp.appearance = t.nsAppearance }
}

struct Palette {
    let text, subtext, green, red, yellow: NSColor
    init(text: String, subtext: String, green: String, red: String, yellow: String) {
        self.text = NSColor(hex: text); self.subtext = NSColor(hex: subtext)
        self.green = NSColor(hex: green); self.red = NSColor(hex: red)
        self.yellow = NSColor(hex: yellow)
    }
}

extension NSColor {
    /// "#rrggbb" -> sRGB color.
    convenience init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
