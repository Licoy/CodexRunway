import CodexRunwayCore
import Foundation

struct GrokQuotaPresentation: Sendable, Equatable {
    struct Line: Sendable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
    }

    var plan: String
    /// Overall included quota meter first, then product breakdown meters.
    var meters: [QuotaMeter]
    /// Account included allowance as USD, e.g. `$147.23 / $150.00`.
    var includedUSDAllowance: String?
    var prepaidBalance: String?
    var onDemandUsage: String?
    var source: String
    var updatedAt: Date
    var lines: [Line]
    var productLines: [Line]

    static func make(snapshot: GrokQuotaSnapshot, l10n: L10n) -> Self {
        let usedPercent = max(0, min(100, Int(snapshot.includedUsagePercent.rounded())))
        let periodTitle = snapshot.period.map { Self.periodTitle($0.kind, l10n: l10n) }
            ?? l10n.text(.grokIncludedQuota)
        let window = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: snapshot.period.map(windowMinutes),
            resetsAt: snapshot.period?.resetsAt)
        let includedUSD = includedUSDText(snapshot)
        let prepaid = snapshot.prepaidBalanceCents.map(money)
        let onDemand = onDemandText(snapshot)
        let source = l10n.text(.grokSourceCLI)
        let plan = GrokSubscriptionTier.displayName(from: snapshot.plan)
            ?? nonEmpty(snapshot.plan)
            ?? l10n.text(.unknown)
        var lines = [
            Line(title: l10n.text(.grokPlan), value: plan),
            Line(title: periodTitle, value: "\(usedPercent)% \(l10n.text(.used))"),
        ]
        if let includedUSD {
            lines.append(Line(title: l10n.text(.grokIncludedUSD), value: includedUSD))
        }
        if let resetsAt = snapshot.period?.resetsAt {
            lines.append(Line(title: l10n.text(.grokResetAt), value: resetsAt.formatted()))
        }
        if let prepaid {
            lines.append(Line(title: l10n.text(.grokPrepaidBalance), value: prepaid))
        }
        if let onDemand {
            lines.append(Line(title: l10n.text(.grokOnDemandUsage), value: onDemand))
        }
        if snapshot.isUnifiedBillingUser == true {
            lines.append(Line(title: l10n.text(.grokUnifiedBilling), value: l10n.text(.available)))
        }
        lines.append(Line(title: l10n.text(.grokDataSource), value: source))

        var meters = [QuotaMeter(title: periodTitle, window: window, now: snapshot.updatedAt)]
        var productLines: [Line] = []
        for product in snapshot.productUsage {
            let productUsed = max(0, min(100, Int(product.usagePercent.rounded())))
            let title = productTitle(product.product, l10n: l10n)
            let productWindow = RateWindow(
                usedPercent: productUsed,
                windowMinutes: snapshot.period.map(windowMinutes),
                resetsAt: snapshot.period?.resetsAt)
            meters.append(QuotaMeter(
                title: title,
                window: productWindow,
                now: snapshot.updatedAt,
                source: .modelSpecific))
            productLines.append(
                Line(title: title, value: "\(productUsed)% \(l10n.text(.used))"))
        }

        return Self(
            plan: plan,
            meters: meters,
            includedUSDAllowance: includedUSD,
            prepaidBalance: prepaid,
            onDemandUsage: onDemand,
            source: source,
            updatedAt: snapshot.updatedAt,
            lines: lines,
            productLines: productLines)
    }

    /// Compact account-row summary: `$2.77 / $150.00 · 94% left` when USD is known.
    static func accountSummary(snapshot: GrokQuotaSnapshot, l10n: L10n) -> String {
        let remainingPercent = max(0, min(100, 100 - Int(snapshot.includedUsagePercent.rounded())))
        let percentPart = "\(remainingPercent)% \(l10n.text(.left))"
        if let included = includedUSDText(snapshot) {
            return "\(included) · \(percentPart)"
        }
        return "\(percentPart) · \(l10n.text(.lastUpdated)) \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    static func includedUSDText(_ snapshot: GrokQuotaSnapshot) -> String? {
        guard let limit = snapshot.includedLimitCents, limit > 0 else { return nil }
        let used = max(0, snapshot.includedUsedCents ?? 0)
        return "\(money(used)) / \(money(limit))"
    }

    static func productTitle(_ product: String, l10n: L10n) -> String {
        switch product.lowercased() {
        case "grokbuild":
            return l10n.text(.grokProductBuild)
        case "grokimagine":
            return l10n.text(.grokProductImagine)
        case "grokchat":
            return l10n.text(.grokProductChat)
        default:
            return product
        }
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

enum GrokResetCreditsPresentation {
    static func summary(_ snapshot: GrokResetCreditsSnapshot) -> ResetCreditSummary {
        ResetCreditSummary(snapshot: snapshot.asResetCreditsSnapshot())
    }

    static func details(_ snapshot: GrokResetCreditsSnapshot, l10n: L10n) -> [ResetCreditDetail] {
        let credits = ResetCreditSummary.sortedByExpiry(snapshot.asResetCreditsSnapshot().credits)
        return credits.enumerated().map { index, credit in
            let remaining = max(0, credit.remainingSeconds)
            return ResetCreditDetail(
                id: credit.id ?? "\(index)",
                title: "\(l10n.text(.credit)) \(index + 1)",
                statusText: statusText(credit.status, l10n: l10n),
                state: state(credit),
                expiresAt: credit.expiresAt,
                remainingDuration: remaining,
                remainingProgress: credit.expiresAt == nil ? 1 : min(1, remaining / (30 * 24 * 3_600)))
        }
    }

    private static func statusText(_ status: String, l10n: L10n) -> String {
        switch status {
        case "available":
            return l10n.text(.statusAvailable)
        case "used":
            return l10n.text(.statusUsed)
        default:
            return l10n.text(.statusUnknown)
        }
    }

    private static func state(_ credit: ResetCredit) -> ResetCreditState {
        guard credit.status == "available" else { return .unavailable }
        guard credit.expiresAt != nil else { return .available }
        return credit.remainingSeconds <= ResetCreditSummary.expiringThreshold ? .expiring : .available
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
