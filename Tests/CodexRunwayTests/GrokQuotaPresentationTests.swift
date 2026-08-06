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
        #expect(presentation.source == "Grok CLI billing API")
        #expect(presentation.meters.count == 1)
    }

    @Test("product usage becomes secondary meters")
    func productUsageMeters() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_785_139_420)
        let snapshot = GrokQuotaSnapshot(
            plan: "SuperGrok",
            includedUsagePercent: 50,
            period: GrokQuotaPeriod(kind: .weekly, startsAt: updatedAt, resetsAt: updatedAt.addingTimeInterval(86_400)),
            prepaidBalanceCents: 0,
            onDemandEnabled: false,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            productUsage: [
                GrokProductUsage(product: "GrokBuild", usagePercent: 42),
                GrokProductUsage(product: "GrokImagine", usagePercent: 5),
                GrokProductUsage(product: "GrokChat", usagePercent: 3),
            ],
            isUnifiedBillingUser: true,
            source: .current,
            updatedAt: updatedAt)

        let presentation = GrokQuotaPresentation.make(
            snapshot: snapshot,
            l10n: L10n(language: .english))

        #expect(presentation.meters.count == 4)
        #expect(presentation.meters.first?.source == .standard)
        #expect(presentation.meters.dropFirst().allSatisfy { $0.source == .modelSpecific })
        #expect(presentation.meters[1].title == "Grok Build")
        #expect(presentation.meters[1].usedPercent == 42)
        #expect(presentation.productLines.count == 3)
        #expect(presentation.lines.contains { $0.title == "Unified billing" })
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

    @Test("included USD allowance appears in details and account summary")
    func includedUSDAllowance() throws {
        let snapshot = GrokQuotaSnapshot(
            plan: "supergrok",
            includedUsagePercent: 6.0,
            period: GrokQuotaPeriod(kind: .weekly, startsAt: nil, resetsAt: nil),
            includedLimitCents: 15_000,
            includedUsedCents: 277,
            prepaidBalanceCents: 0,
            onDemandEnabled: false,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            source: .current,
            updatedAt: Date(timeIntervalSince1970: 1_785_139_420))

        let l10n = L10n(language: .english)
        let presentation = GrokQuotaPresentation.make(snapshot: snapshot, l10n: l10n)
        #expect(presentation.plan == "SuperGrok")
        #expect(presentation.includedUSDAllowance == "$2.77 / $150.00")
        #expect(presentation.lines.contains {
            $0.title == "Included USD credit" && $0.value == "$2.77 / $150.00"
        })

        let summary = GrokQuotaPresentation.accountSummary(snapshot: snapshot, l10n: l10n)
        #expect(summary.contains("$2.77 / $150.00"))
        #expect(summary.contains("94% left"))
    }
}
