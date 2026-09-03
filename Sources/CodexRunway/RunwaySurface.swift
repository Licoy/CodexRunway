import AppKit
import SwiftUI

/// Design tokens for the popover panel. One radius scale, two surface levels,
/// hairline strokes and monochrome hover fills — every view must draw from here
/// instead of ad-hoc grays so light and dark stay tuned in one place.
enum RunwaySurface {
    // MARK: Radii (all continuous corners)

    /// Icon-button hover pills, segmented-tab thumb.
    static let radiusControl: CGFloat = 5
    /// Disclosure rows, date fields, buttons, row hover pills.
    static let radiusRow: CGFloat = 6
    /// Stat cards, table containers, hero card, account cards.
    static let radiusCard: CGFloat = 10
    /// Tier badge / expiry chip plates.
    static let radiusPlate: CGFloat = 5

    /// Legacy alias while non-panel views migrate.
    static let cornerRadius: CGFloat = 8

    // MARK: Surfaces

    /// Keep panel contrast independent of windows behind the native popover.
    static let panel = Color(nsColor: .windowBackgroundColor)

    /// Cards and interactive rows sitting on the panel.
    static let raised = dynamic(
        light: NSColor.black.withAlphaComponent(0.045),
        dark: NSColor.white.withAlphaComponent(0.065))
    /// Table containers, progress-bar tracks, segmented-tab well.
    static let sunken = dynamic(
        light: NSColor.black.withAlphaComponent(0.03),
        dark: NSColor.white.withAlphaComponent(0.045))
    /// Contrast band behind table column headers.
    static let tableHead = dynamic(
        light: NSColor.black.withAlphaComponent(0.04),
        dark: NSColor.white.withAlphaComponent(0.05))

    /// Legacy aliases (settings panes still use these).
    static let fill = raised
    static let subtleFill = sunken

    // MARK: Strokes

    /// Section separators, card strokes. `separatorColor` already carries its own
    /// low alpha — multiply it, never replace it (`withAlphaComponent` would paint
    /// a 60% black bar).
    static let hairline = Color(nsColor: .separatorColor)
    /// Table row separators.
    static let hairlineFaint = Color(nsColor: .separatorColor).opacity(0.55)

    // MARK: Hover fills (monochrome; accent hover is reserved for CTAs)

    static let hoverNeutral = dynamic(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.09))
    static let hoverAccent = Color.accentColor.opacity(0.12)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

/// Card chrome per scheme: light gets a translucent gray wash that blends into
/// the panel background — no outline, no shadow (both read as clutter there);
/// dark keeps translucent fills with a hairline stroke carrying the elevation.
struct RunwayCardSurface: ViewModifier {
    enum Kind {
        case raised
        case sunken
    }

    var kind: Kind
    var cornerRadius: CGFloat = RunwaySurface.radiusCard

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(kind == .raised ? RunwaySurface.raised : RunwaySurface.sunken)
            }
            .overlay {
                if colorScheme == .dark {
                    shape.strokeBorder(RunwaySurface.hairline, lineWidth: 1)
                }
            }
    }
}

extension View {
    func runwayCard(
        _ kind: RunwayCardSurface.Kind = .raised,
        cornerRadius: CGFloat = RunwaySurface.radiusCard) -> some View
    {
        modifier(RunwayCardSurface(kind: kind, cornerRadius: cornerRadius))
    }
}
