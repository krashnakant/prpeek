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

/// "Why it waits" color. Shared so the panel pill and the search row agree.
func reasonColor(_ r: WaitReason, palette: Palette?) -> NSColor {
    switch r {
    case .reviewRequested: return palette?.mauve ?? .systemPurple
    case .teamReview:      return palette?.blue ?? .systemBlue
    case .ciFailing:       return palette?.red ?? .systemRed
    }
}

extension WaitReason {
    /// Compact label for the panel pill and the search row.
    var panelLabel: String {
        switch self {
        case .reviewRequested: return "review"
        case .teamReview: return "team"
        case .ciFailing: return "CI"
        }
    }
}

/// Freshness color. `.seen` never renders a pill, so it has no color of its own.
func freshnessColor(_ f: PRFreshness, palette: Palette?) -> NSColor {
    switch f {
    case .new:      return palette?.blue ?? .systemBlue
    case .reReview: return palette?.mauve ?? .systemPurple
    case .stale:    return palette?.yellow ?? .systemOrange
    case .seen:     return palette?.subtext ?? .secondaryLabelColor
    }
}

extension PRFreshness {
    /// Compact pill text. `.seen` is empty on purpose: only the things you have
    /// not dealt with earn a marker, so a reviewed-and-waiting PR stays quiet.
    var pillLabel: String? {
        switch self {
        case .new:      return "new"
        case .reReview: return "re-review"
        case .stale:    return "stale"
        case .seen:     return nil
        }
    }

    /// Hover text. Nil wherever `pillLabel` is nil — nothing shown, nothing to explain.
    var long: String? {
        switch self {
        case .new:      return "You haven't opened this one yet"
        case .seen:     return nil
        case .stale:    return "Waiting on you for more than 3 days"
        case .reReview: return "You reviewed this; the author has asked again"
        }
    }
}

/// The one spelling of an account tag, so the menu and the search row can't
/// drift apart. Empty with a single account (nil label).
func accountTag(_ label: String?) -> String {
    label.map { "[\($0)] " } ?? ""
}
