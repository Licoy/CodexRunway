import CodexRunwayCore
import Foundation
import SwiftUI

enum QuotaEstimatePresentation {
    static func unavailableText(_ reason: QuotaEstimateUnavailableReason, l10n: L10n) -> String {
        let key: L10nKey
        switch reason {
        case .missingCredits: key = .quotaEstimateMissingCredits
        case .zeroCreditsWithUsage: key = .quotaEstimateZeroCreditsWithUsage
        case .noUsage: key = .quotaEstimateNoUsage
        case .zeroPercent: key = .quotaEstimateZeroPercent
        case .unavailableWindow: key = .quotaEstimateUnavailableWindow
        }
        return l10n.text(key)
    }

    static func dataTimeText(_ snapshot: QuotaEstimateSnapshot, l10n: L10n) -> String {
        let stats = snapshot.statsThroughDate.map { String(format: l10n.text(.quotaEstimateStatsThrough), $0) }
        let updated = "\(l10n.text(.lastUpdated)) \(ResetCreditDateFormatter.updatedAt(snapshot.calculatedAt, language: l10n.language))"
        return [stats, updated].compactMap { $0 }.joined(separator: " · ")
    }

    static func refreshErrorText(_ error: String?, l10n: L10n) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return "\(l10n.text(.quotaEstimateShowingPreviousData))\n\(error)"
    }
}

struct QuotaEstimateDataStatusView: View {
    var snapshot: QuotaEstimateSnapshot
    var error: String?
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(QuotaEstimatePresentation.dataTimeText(snapshot, l10n: l10n))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText = QuotaEstimatePresentation.refreshErrorText(error, l10n: l10n) {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
