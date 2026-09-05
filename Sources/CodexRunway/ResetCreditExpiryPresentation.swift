import CodexRunwayCore
import Foundation

enum ResetCreditExpiryPresentation {
    static func duration(_ remaining: TimeInterval?, l10n: L10n) -> String {
        remaining.map {
            DurationFormatter.localized($0, language: l10n.language, includeSeconds: false)
        } ?? "--"
    }

    static func help(date: Date?, updatedAt: Date, l10n: L10n) -> String {
        let expiry = date.map {
            ResetCreditDateFormatter.expiresAt($0, language: l10n.language)
        } ?? l10n.text(.resetExpiryUnavailable)
        let updated = ResetCreditDateFormatter.updatedAt(updatedAt, language: l10n.language)
        return "\(expiry)\n\(l10n.text(.lastUpdated)): \(updated)\n\(l10n.text(.resetExpirySummaryHelp))"
    }
}
