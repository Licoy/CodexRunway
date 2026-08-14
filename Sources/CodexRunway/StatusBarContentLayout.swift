import AppKit
import CodexRunwayCore

struct StatusBarContentState: Equatable {
    struct Configuration: Equatable {
        let style: StatusBarDisplayStyle
        let metersDetailStyle: StatusBarMetersDetailStyle
        let batteryScope: StatusBarBatteryScope
        let batteryDetailStyle: StatusBarBatteryDetailStyle
        let language: ResolvedLanguage

        init(preferences: RunwayPreferences, language: ResolvedLanguage) {
            style = preferences.statusBarDisplayStyle
            metersDetailStyle = preferences.statusBarMetersDetailStyle
            batteryScope = preferences.statusBarBatteryScope
            batteryDetailStyle = preferences.statusBarBatteryDetailStyle
            self.language = language
        }
    }

    struct Content: Equatable {
        let text: String
        let meters: [QuotaMeter]
        let displayMinute: Int

        var now: Date {
            Date(timeIntervalSince1970: TimeInterval(displayMinute * 60))
        }
    }

    let configuration: Configuration
    let content: Content

    static let placeholder = StatusBarContentState(
        configuration: Configuration(
            preferences: RunwayPreferences(statusBarDisplayStyle: .countdown),
            language: .english),
        content: Content(text: "", meters: [], displayMinute: 0))
}

struct StatusBarContentLayout {
    let style: StatusBarDisplayStyle
    let metersDetailStyle: StatusBarMetersDetailStyle
    let batteryScope: StatusBarBatteryScope
    let batteryDetailStyle: StatusBarBatteryDetailStyle
    let language: ResolvedLanguage
    let text: String
    let meters: [QuotaMeter]
    let now: Date

    init(state: StatusBarContentState) {
        style = state.configuration.style
        metersDetailStyle = state.configuration.metersDetailStyle
        batteryScope = state.configuration.batteryScope
        batteryDetailStyle = state.configuration.batteryDetailStyle
        language = state.configuration.language
        text = state.content.text
        meters = state.content.meters
        now = state.content.now
    }

    var renderPlan: StatusBarRenderPlan {
        StatusBarRenderPlan.make(style: style, batteryScope: batteryScope, meters: meters)
    }

    var preferredWidth: CGFloat {
        switch style {
        case .text:
            return totalWidth(textColumnWidths, gap: 4)
        case .countdown:
            guard renderPlan.meters.count > 1 else {
                return min(180, max(42, textWidth(text, font: countdownFont) + 14))
            }
            return totalWidth(countdownColumnWidths, gap: 2)
        case .battery:
            guard let onlyMeter = renderPlan.meters.count == 1 ? renderPlan.meters.first : nil else {
                return renderPlan.meters.isEmpty ? 72 : totalWidth(batteryColumnWidths, gap: 5)
            }
            // Elongated iOS-style body + terminal + padding around the center label.
            return min(150, max(72, textWidth(batteryDetail(for: onlyMeter), font: batteryFont) + 32))
        case .meters:
            return renderPlan.meters.isEmpty ? 70 : contentWidth(meterColumnWidths, gap: 6)
        case .rings:
            return CGFloat(max(1, renderPlan.meters.count) * 24 + 4)
        }
    }

    var countdownFont: NSFont {
        .systemFont(ofSize: 14, weight: .semibold)
    }

    var textFont: NSFont {
        .systemFont(ofSize: 14, weight: .semibold)
    }

    var countdownItemFont: NSFont {
        .systemFont(ofSize: 10, weight: .semibold)
    }

    var batteryFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    }

    var smallBatteryFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 7, weight: .semibold)
    }

    var meterTextFont: NSFont {
        .systemFont(ofSize: 8.5, weight: .semibold)
    }

    var meterBarWidth: CGFloat {
        40
    }

    var meterTextGap: CGFloat {
        4
    }

    var ringFont: NSFont {
        .systemFont(ofSize: 6, weight: .bold)
    }

    var countdownColumnWidths: [CGFloat] {
        renderPlan.meters.map {
            min(112, max(42, textWidth(countdownCaption(for: $0), font: countdownItemFont) + 10))
        }
    }

    var textCaptions: [String] {
        let meters = renderPlan.meters
        return meters.isEmpty
            ? [ringText(for: nil)]
            : meters.map { "\(ringText(for: $0))%" }
    }

    var textColumnWidths: [CGFloat] {
        textCaptions.map { max(24, textWidth($0, font: textFont) + 8) }
    }

    var batteryColumnWidths: [CGFloat] {
        renderPlan.columns.map { column in
            let maximumTextWidth = column.map {
                textWidth(batteryCaption(for: $0), font: smallBatteryFont)
            }.max() ?? 0
            // Extra room for terminal nub and shell insets.
            return min(156, max(92, maximumTextWidth + 18))
        }
    }

    var meterColumnWidths: [CGFloat] {
        renderPlan.columns.map { column in
            let maximumContentWidth = column.map { meterContentWidth(for: $0) }.max() ?? 0
            return min(166, max(64, maximumContentWidth))
        }
    }

    func meterContentWidth(for meter: QuotaMeter) -> CGFloat {
        meterBarWidth
            + meterTextGap
            + textWidth(meterCaption(for: meter), font: meterTextFont)
    }

    func countdownCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(resetCountdown(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(resetCountdown(for: meter))"
    }

    func batteryCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(batteryDetail(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(batteryDetail(for: meter))"
    }

    func meterCaption(for meter: QuotaMeter) -> String {
        if meter.source == .modelSpecific {
            return "\(meterDetail(for: meter)) \(meter.title)"
        }
        return "\(meter.title) \(meterDetail(for: meter))"
    }

    func ringText(for meter: QuotaMeter?) -> String {
        meter.map { "\($0.remainingPercent)" } ?? "--"
    }

    func batteryDetail(for meter: QuotaMeter) -> String {
        switch batteryDetailStyle {
        case .countdown:
            return resetCountdown(for: meter)
        case .remainingPercent:
            return "\(meter.remainingPercent)%"
        }
    }

    func columnFrames(widths: [CGFloat], gap: CGFloat, in bounds: NSRect) -> [NSRect] {
        let contentWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
        var x = bounds.midX - contentWidth / 2
        return widths.map { width in
            defer { x += width + gap }
            return NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    func rowFrames(
        count: Int,
        in rect: NSRect,
        height: CGFloat,
        gap: CGFloat = 0)
        -> [NSRect]
    {
        let totalHeight = CGFloat(count) * height + CGFloat(max(0, count - 1)) * gap
        let bottom = rect.midY - totalHeight / 2
        return (0..<count).map { index in
            let reverseIndex = count - index - 1
            let y = bottom + CGFloat(reverseIndex) * (height + gap)
            return NSRect(x: rect.minX, y: y, width: rect.width, height: height)
        }
    }

    private func meterDetail(for meter: QuotaMeter) -> String {
        switch metersDetailStyle {
        case .remainingPercent:
            return "\(meter.remainingPercent)%"
        case .resetTime:
            return meter.resetsAt.map { ResetLabelFormatter.shortLabel(for: $0, language: language) } ?? "--"
        case .both:
            let reset = meter.resetsAt.map { ResetLabelFormatter.shortLabel(for: $0, language: language) } ?? "--"
            return "\(meter.remainingPercent)% · \(reset)"
        }
    }

    private func resetCountdown(for meter: QuotaMeter) -> String {
        meter.resetsAt.map {
            DurationFormatter.localized($0.timeIntervalSince(now), language: language, includeSeconds: false)
        } ?? "--"
    }

    private func totalWidth(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        contentWidth(widths, gap: gap) + 8
    }

    private func contentWidth(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        text.size(withAttributes: [.font: font]).width
    }
}
