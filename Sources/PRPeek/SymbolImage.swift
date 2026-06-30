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

/// CI rollup as a color SF Symbol (shape + color, never color-only). Palette
/// tints for Catppuccin themes; nil falls back to system colors.
func ciImage(_ s: CIState, palette: Palette?) -> NSImage {
    switch s {
    case .passing: return coloredSymbol("checkmark.circle.fill", palette?.green ?? .systemGreen)
    case .failing: return coloredSymbol("xmark.octagon.fill", palette?.red ?? .systemRed)
    case .pending: return coloredSymbol("clock.fill", palette?.yellow ?? .systemYellow)
    case .none:    return coloredSymbol("minus.circle", palette?.subtext ?? .tertiaryLabelColor)
    }
}
