import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Grok quota presentation")
struct GrokQuotaPresentationTests {
    @Test("projects precise billing data into the existing meter surface")
    func projectsBillingData() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_785_139_420)
        let resetsAt = updatedAt.addingTimeInterval(4 * 24 * 3_600)
        let snapshot = GrokQuotaSnapshot(
            plan: "SuperGrok",
            includedUsagePercent: 33.4,
            period: GrokQuotaPeriod(kind: .weekly, startsAt: updatedAt, resetsAt: resetsAt),
            prepaidBalanceCents: 1_234,
            onDemandEnabled: true,
            onDemandUsedCents: 125,
            onDemandLimitCents: 2_500,
            source: .current,
            updatedAt: updatedAt)

        let presentation = GrokQuotaPresentation.make(
            snapshot: snapshot,
            l10n: L10n(language: .english))

        let meter = try #require(presentation.meters.first)
        #expect(meter.usedPercent == 33)
        #expect(meter.remainingPercent == 67)
        #expect(meter.resetsAt == resetsAt)
        #expect(presentation.plan == "SuperGrok")
        #expect(presentation.prepaidBalance == "$12.34")
        #expect(presentation.onDemandUsage == "$1.25 / $25.00")
        #expect(presentation.source == "Grok CLI")
    }

    @Test("monthly quota receives a monthly meter title")
    func monthlyMeterTitle() throws {
        let snapshot = GrokQuotaSnapshot(
            plan: nil,
            includedUsagePercent: 0.5,
            period: GrokQuotaPeriod(kind: .monthly, startsAt: nil, resetsAt: nil),
            prepaidBalanceCents: 0,
            onDemandEnabled: false,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            source: .deprecated,
            updatedAt: Date(timeIntervalSince1970: 1_785_139_420))

        let presentation = GrokQuotaPresentation.make(
            snapshot: snapshot,
            l10n: L10n(language: .english))

        #expect(presentation.meters.first?.title == "Monthly included quota")
        #expect(presentation.prepaidBalance == "$0.00")
        #expect(presentation.onDemandUsage == nil)
    }
}
