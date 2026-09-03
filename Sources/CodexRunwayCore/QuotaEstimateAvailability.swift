import Foundation

public enum QuotaEstimateUnavailableReason: Sendable, Equatable {
    case missingCredits
    case zeroCreditsWithUsage
    case noUsage
    case zeroPercent
    case unavailableWindow

    static func evaluate(meter: RateWindow?, rows: [QuotaEstimateDailyRow]) -> Self? {
        guard let meter, (meter.windowMinutes ?? 0) > 0, meter.resetsAt != nil else {
            return .unavailableWindow
        }
        guard rows.allSatisfy(\.totalsReported) else { return .missingCredits }
        let usedRows = rows.filter(\.hasUsage)
        guard !usedRows.isEmpty else { return .noUsage }
        guard usedRows.allSatisfy(\.creditsReported) else { return .missingCredits }
        guard meter.usedPercentExact > 0 else { return .zeroPercent }
        guard usedRows.contains(where: { $0.credits > 0 }) else { return .zeroCreditsWithUsage }
        return nil
    }
}

extension QuotaEstimateDailyRow {
    var hasUsage: Bool { tokens > 0 || turns > 0 || credits > 0 }
}

public extension QuotaEstimateSnapshot {
    var creditsComplete: Bool {
        currentRows.contains(where: \.creditsReported)
            && currentRows.allSatisfy(\.totalsReported)
            && currentRows.allSatisfy { !$0.hasUsage || $0.creditsReported }
    }

    /// API-equivalent token cost is separate from the Credits-to-USD reference conversion.
    var apiEquivalentUSD: Double? {
        guard !currentRows.isEmpty,
              currentRows.allSatisfy(\.totalsReported),
              currentRows.allSatisfy({ !$0.hasUsage || $0.usd != nil })
        else { return nil }
        return currentRows.compactMap(\.usd).reduce(0, +)
    }

    var statsThroughDate: String? { currentRows.map(\.date).max() }
}
