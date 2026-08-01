import CodexRunwayCore
import Foundation

/// Picks the highest-priority window per provider for dual status-bar display.
enum StatusBarMeterSelection {
    /// Codex priority: 5h → weekly → first standard meter.
    static let codexPreferredWindowMinutes: [Int] = [300, 10_080]
    /// Grok priority: weekly → monthly → first included meter.
    static let grokPreferredWindowMinutes: [Int] = [10_080, 30 * 24 * 60]

    static func primaryStandardMeter(
        from meters: [QuotaMeter],
        preferredWindowMinutes: [Int])
        -> QuotaMeter?
    {
        let standard = meters.filter { $0.source == .standard }
        guard !standard.isEmpty else { return meters.first }
        for minutes in preferredWindowMinutes {
            if let match = standard.first(where: { $0.windowMinutes == minutes }) {
                return match
            }
        }
        return standard.first
    }

    /// Short window labels matching Codex menu-bar style (`5小时` / `每周` / `每月`).
    static func shortWindowTitle(windowMinutes: Int?, l10n: L10n) -> String {
        switch windowMinutes {
        case 300:
            return l10n.text(.fiveHourUsage)
        case 10_080:
            return l10n.text(.weeklyUsage)
        case 30 * 24 * 60:
            return l10n.text(.heatmapMonthly)
        default:
            return l10n.text(.quota)
        }
    }

    /// Rewrites a meter title to the short Codex-aligned window form for the menu bar.
    static func withShortStatusBarTitle(_ meter: QuotaMeter, l10n: L10n) -> QuotaMeter {
        var copy = meter
        copy.title = shortWindowTitle(windowMinutes: meter.windowMinutes, l10n: l10n)
        return copy
    }

    /// Codex on top, Grok below. Titles: `Codex · 每周` / `Grok · 每周` (short, readable).
    static func dualProviderMeters(
        codexMeters: [QuotaMeter],
        grokMeters: [QuotaMeter],
        codexLabel: String,
        grokLabel: String,
        l10n: L10n)
        -> [QuotaMeter]
    {
        var result: [QuotaMeter] = []
        if var codex = primaryStandardMeter(
            from: codexMeters,
            preferredWindowMinutes: codexPreferredWindowMinutes)
        {
            let window = shortWindowTitle(windowMinutes: codex.windowMinutes, l10n: l10n)
            codex.title = "\(codexLabel) · \(window)"
            result.append(codex)
        }
        // Grok status bar uses overall included quota only (first meter), not product bars.
        if var grok = primaryStandardMeter(
            from: Array(grokMeters.prefix(1)),
            preferredWindowMinutes: grokPreferredWindowMinutes)
            ?? grokMeters.first
        {
            let window = shortWindowTitle(windowMinutes: grok.windowMinutes, l10n: l10n)
            grok.title = "\(grokLabel) · \(window)"
            result.append(grok)
        }
        return result
    }
}
