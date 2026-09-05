import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Reset credit expiry presentation")
struct ResetCreditExpiryPresentationTests {
    @Test("missing expiry is distinct from zero and uses minute precision")
    func durationText() {
        let l10n = L10n(language: .english)
        #expect(ResetCreditExpiryPresentation.duration(nil, l10n: l10n) == "--")
        #expect(ResetCreditExpiryPresentation.duration(0, l10n: l10n) == "0 seconds")
        #expect(ResetCreditExpiryPresentation.duration(3_661, l10n: l10n) == "1 hour 1 minute")
        #expect(ResetCreditExpiryPresentation.duration(25 * 86_400, l10n: l10n) == "25 days")
    }

    @Test("expiry help includes the absolute date, snapshot time and known-date scope", arguments: ResolvedLanguage.allCases)
    func expiryHelp(language: ResolvedLanguage) {
        let l10n = L10n(language: language)
        let updatedAt = Date(timeIntervalSince1970: 1_786_601_000)
        let date = updatedAt.addingTimeInterval(25 * 86_400)
        let known = ResetCreditExpiryPresentation.help(date: date, updatedAt: updatedAt, l10n: l10n)
        let unknown = ResetCreditExpiryPresentation.help(date: nil, updatedAt: updatedAt, l10n: l10n)
        #expect(known.hasPrefix(ResetCreditDateFormatter.expiresAt(date, language: language)))
        #expect(unknown.hasPrefix(l10n.text(.resetExpiryUnavailable)))
        #expect(!unknown.hasPrefix(l10n.text(.noExpiry)))
        for help in [known, unknown] {
            #expect(help.contains(ResetCreditDateFormatter.updatedAt(updatedAt, language: language)))
            #expect(help.contains(l10n.text(.resetExpirySummaryHelp)))
        }
    }
}
