import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status bar meter selection")
struct StatusBarMeterSelectionTests {
    @Test("Codex prefers 5-hour over weekly")
    func codexPrefersFiveHour() {
        let fiveHour = meter(title: "5h", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "weekly", usedPercent: 40, windowMinutes: 10_080)
        let pick = StatusBarMeterSelection.primaryStandardMeter(
            from: [weekly, fiveHour],
            preferredWindowMinutes: StatusBarMeterSelection.codexPreferredWindowMinutes)
        #expect(pick?.title == "5h")
    }

    @Test("Codex falls back to weekly when 5-hour is missing")
    func codexFallsBackToWeekly() {
        let weekly = meter(title: "weekly", usedPercent: 40, windowMinutes: 10_080)
        let model = meter(title: "gpt", usedPercent: 10, windowMinutes: 10_080, source: .modelSpecific)
        let pick = StatusBarMeterSelection.primaryStandardMeter(
            from: [model, weekly],
            preferredWindowMinutes: StatusBarMeterSelection.codexPreferredWindowMinutes)
        #expect(pick?.title == "weekly")
        #expect(pick?.source == .standard)
    }

    @Test("Grok prefers weekly over monthly")
    func grokPrefersWeekly() {
        let weekly = meter(title: "week", usedPercent: 18, windowMinutes: 10_080)
        let monthly = meter(title: "month", usedPercent: 30, windowMinutes: 30 * 24 * 60)
        let pick = StatusBarMeterSelection.primaryStandardMeter(
            from: [monthly, weekly],
            preferredWindowMinutes: StatusBarMeterSelection.grokPreferredWindowMinutes)
        #expect(pick?.title == "week")
    }

    @Test("dual stack is Codex then Grok with short window titles")
    func dualStackOrderAndPrefix() {
        let fiveHour = meter(title: "5-hour", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "Weekly", usedPercent: 11, windowMinutes: 10_080)
        // Long panel title must be rewritten to short status-bar form.
        let grokWeek = meter(title: "周度包含额度", usedPercent: 42, windowMinutes: 10_080)
        let grokProduct = meter(title: "Build", usedPercent: 10, windowMinutes: 10_080)
        let l10n = L10n(language: .simplifiedChinese)

        let meters = StatusBarMeterSelection.dualProviderMeters(
            codexMeters: [fiveHour, weekly],
            grokMeters: [grokWeek, grokProduct],
            codexLabel: "Codex",
            grokLabel: "Grok",
            l10n: l10n)

        #expect(meters.count == 2)
        #expect(meters[0].title == "Codex · 5小时")
        #expect(meters[0].windowMinutes == 300)
        #expect(meters[1].title == "Grok · 每周")
        #expect(meters[1].windowMinutes == 10_080)
    }

    @Test("dual stack omits a missing platform")
    func dualOmitsMissingPlatform() {
        let grokWeek = meter(title: "周度包含额度", usedPercent: 42, windowMinutes: 10_080)
        let meters = StatusBarMeterSelection.dualProviderMeters(
            codexMeters: [],
            grokMeters: [grokWeek],
            codexLabel: "Codex",
            grokLabel: "Grok",
            l10n: L10n(language: .simplifiedChinese))
        #expect(meters.count == 1)
        #expect(meters[0].title == "Grok · 每周")
    }

    @Test("short window titles match Codex menu-bar wording")
    func shortWindowTitlesMatchCodex() {
        let l10n = L10n(language: .simplifiedChinese)
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 300, l10n: l10n) == "5小时")
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 10_080, l10n: l10n) == "每周")
        #expect(StatusBarMeterSelection.shortWindowTitle(windowMinutes: 30 * 24 * 60, l10n: l10n) == "每月")

        let long = meter(title: "周度包含额度", usedPercent: 27, windowMinutes: 10_080)
        #expect(StatusBarMeterSelection.withShortStatusBarTitle(long, l10n: l10n).title == "每周")
    }

    private func meter(
        title: String,
        usedPercent: Int,
        windowMinutes: Int,
        source: QuotaMeterSource = .standard)
        -> QuotaMeter
    {
        QuotaMeter(
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: Date().addingTimeInterval(TimeInterval(windowMinutes * 60))),
            source: source)
    }
}
