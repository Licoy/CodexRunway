import CodexRunwayCore
import Foundation

struct GrokQuotaPresentation: Sendable, Equatable {
    struct Line: Sendable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
    }

    var plan: String
    var meters: [QuotaMeter]
    var prepaidBalance: String?
    var onDemandUsage: String?
    var source: String
    var updatedAt: Date
    var lines: [Line]

    static func make(snapshot: GrokQuotaSnapshot, l10n: L10n) -> Self {
        let usedPercent = max(0, min(100, Int(snapshot.includedUsagePercent.rounded())))
        let periodTitle = snapshot.period.map { Self.periodTitle($0.kind, l10n: l10n) }
            ?? l10n.text(.grokIncludedQuota)
        let window = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: snapshot.period.map(windowMinutes),
            resetsAt: snapshot.period?.resetsAt)
        let prepaid = snapshot.prepaidBalanceCents.map(money)
        let onDemand = onDemandText(snapshot)
        let source = l10n.text(.grokSourceCLI)
        let plan = nonEmpty(snapshot.plan) ?? l10n.text(.unknown)
        var lines = [
            Line(title: l10n.text(.grokPlan), value: plan),
            Line(title: periodTitle, value: "\(usedPercent)% \(l10n.text(.used))"),
        ]
        if let resetsAt = snapshot.period?.resetsAt {
            lines.append(Line(title: l10n.text(.grokResetAt), value: resetsAt.formatted()))
        }
        if let prepaid {
            lines.append(Line(title: l10n.text(.grokPrepaidBalance), value: prepaid))
        }
        if let onDemand {
            lines.append(Line(title: l10n.text(.grokOnDemandUsage), value: onDemand))
        }
        lines.append(Line(title: l10n.text(.grokDataSource), value: source))

        return Self(
            plan: plan,
            meters: [QuotaMeter(title: periodTitle, window: window, now: snapshot.updatedAt)],
            prepaidBalance: prepaid,
            onDemandUsage: onDemand,
            source: source,
            updatedAt: snapshot.updatedAt,
            lines: lines)
    }

    private static func periodTitle(_ kind: GrokQuotaPeriodKind, l10n: L10n) -> String {
        switch kind {
        case .weekly:
            return l10n.text(.grokBillingPeriodWeekly)
        case .monthly:
            return l10n.text(.grokBillingPeriodMonthly)
        }
    }

    private static func windowMinutes(_ period: GrokQuotaPeriod) -> Int {
        switch period.kind {
        case .weekly:
            return 7 * 24 * 60
        case .monthly:
            return 30 * 24 * 60
        }
    }

    private static func onDemandText(_ snapshot: GrokQuotaSnapshot) -> String? {
        guard snapshot.onDemandEnabled == true else { return nil }
        switch (snapshot.onDemandUsedCents, snapshot.onDemandLimitCents) {
        case let (used?, limit?):
            return "\(money(used)) / \(money(limit))"
        case let (used?, nil):
            return money(used)
        case (nil, _):
            return nil
        }
    }

    private static func money(_ cents: Int64) -> String {
        let value = Decimal(cents) / 100
        return "$\(NSDecimalNumber(decimal: value).stringValue.padFractionDigits(2))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    func padFractionDigits(_ count: Int) -> String {
        let parts = split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard count > 0 else { return String(parts[0]) }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let padded = fraction + String(repeating: "0", count: max(0, count - fraction.count))
        return "\(parts[0]).\(padded.prefix(count))"
    }
}
