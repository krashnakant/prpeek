import AppKit
import PRPeekCore

/// A colored SF Symbol image that keeps its color in menus and buttons
/// (isTemplate=false, so AppKit doesn't mask it to the label color).
func coloredSymbol(_ name: String, _ color: NSColor) -> NSImage {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    let img = base.withSymbolConfiguration(.init(paletteColors: [color])) ?? base
    img.isTemplate = false
    return img
}

/// CI rollup color. Palette tints for Catppuccin themes; nil falls back to
/// system colors. Shared so the chip tint and the glyph stay in sync.
func ciColor(_ s: CIState, palette: Palette?) -> NSColor {
    switch s {
    case .passing: return palette?.green ?? .systemGreen
    case .failing: return palette?.red ?? .systemRed
    case .pending: return palette?.yellow ?? .systemYellow
    case .none:    return palette?.subtext ?? .tertiaryLabelColor
    }
}

/// CI rollup as a color SF Symbol (shape + color, never color-only).
func ciImage(_ s: CIState, palette: Palette?) -> NSImage {
    let name: String
    switch s {
    case .passing: name = "checkmark.circle.fill"
    case .failing: name = "xmark.octagon.fill"
    case .pending: name = "clock.fill"
    case .none:    name = "minus.circle"
    }
    return coloredSymbol(name, ciColor(s, palette: palette))
}
