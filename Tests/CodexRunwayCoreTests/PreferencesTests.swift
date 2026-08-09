import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Runway preferences")
struct PreferencesTests {
    @Test("desktop widgets default to a 60-second app-driven refresh")
    func widgetRefreshDefaults() throws {
        #expect(RunwayPreferences().widgetRefreshIntervalSeconds == 60)

        let oldData = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300
        }
        """.data(using: .utf8)!

        let oldPreferences = try JSONDecoder().decode(RunwayPreferences.self, from: oldData)
        #expect(oldPreferences.widgetRefreshIntervalSeconds == 60)
    }

    @Test("desktop widget refresh accepts custom values within safe bounds")
    func widgetRefreshBounds() throws {
        let tooFrequent = """
        { "widgetRefreshIntervalSeconds": 1 }
        """.data(using: .utf8)!
        let tooSlow = """
        { "widgetRefreshIntervalSeconds": 3600 }
        """.data(using: .utf8)!

        #expect(
            try JSONDecoder().decode(RunwayPreferences.self, from: tooFrequent)
                .widgetRefreshIntervalSeconds == 60)
        #expect(
            try JSONDecoder().decode(RunwayPreferences.self, from: tooSlow)
                .widgetRefreshIntervalSeconds == 1_800)
        #expect(RunwayPreferences(widgetRefreshIntervalSeconds: 120).widgetRefreshIntervalSeconds == 120)
    }

    @Test("system language resolves from device locale")
    func resolvesSystemLanguage() {
        #expect(L10n.resolve(.system, localeIdentifier: "zh-Hans-CN") == .simplifiedChinese)
        #expect(L10n.resolve(.system, localeIdentifier: "en-US") == .english)
        #expect(L10n.resolve(.system, localeIdentifier: "fr-FR") == .english)
    }

    @Test("system language resolves from preferred languages")
    func resolvesSystemLanguageFromPreferredLanguages() {
        #expect(L10n.resolve(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(L10n.resolve(.system, preferredLanguages: ["en-US", "zh-Hans-CN"]) == .simplifiedChinese)
        #expect(L10n.resolve(.system, preferredLanguages: []) == .english)
        #expect(L10n.resolve(.system, preferredLanguages: ["fr-FR"]) == .english)
        #expect(L10n.resolve(.english, preferredLanguages: ["zh-Hans-CN"]) == .english)
        #expect(L10n.resolve(.simplifiedChinese, preferredLanguages: ["en-US"]) == .simplifiedChinese)
    }

    @Test("translations fall back to English")
    func translationsFallbackToEnglish() {
        let english = L10n(language: .english)
        let chinese = L10n(language: .simplifiedChinese)

        #expect(english.text(.settings) == "Settings")
        #expect(chinese.text(.settings) == "设置")
        #expect(english.text(.updateReadyToInstall) == "Ready to Install")
        #expect(chinese.text(.updateInstallAndRelaunch) == "安装并重启")
        #expect(english.text(.statusBarMetersDetailBoth) == "Both")
        #expect(chinese.text(.statusBarMetersDetailBoth) == "两者都显示")
        #expect(english.text(.updateNetworkProxyHint).contains("system proxy bypass"))
        #expect(chinese.text(.updateNetworkProxyHint).contains("系统代理绕过"))
    }

    @Test("all localization keys have English and Chinese translations")
    func localizationCompleteness() {
        #expect(L10n.missingTranslations(for: .english).isEmpty)
        #expect(L10n.missingTranslations(for: .simplifiedChinese).isEmpty)
    }

    @Test("preferences persist to user defaults")
    func preferencesPersist() {
        let suiteName = "CodexRunwayPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.save(RunwayPreferences(
            selectedProvider: .grok,
            language: .english,
            appearance: .dark,
            statusBarDisplayStyle: .rings,
            statusBarMetersDetailStyle: .both,
            statusBarBatteryScope: .both,
            statusBarBatteryDetailStyle: .remainingPercent,
            statusBarProviderScope: .both,
            refreshIntervalSeconds: 120,
            widgetRefreshIntervalSeconds: 300,
            apiCostSummaryRange: .thisMonth,
            showsCostSummary: false,
            showsRecentSessions: true,
            showsSessionRepairSummary: false,
            automaticallyChecksForUpdates: false,
            quotaAlertsEnabled: true,
            resetCreditAlertsEnabled: true,
            rateLimitResetTodayAlertsEnabled: false,
            exportsStatusJSON: true))

        #expect(store.load().selectedProvider == .grok)
        #expect(store.load().language == .english)
        #expect(store.load().appearance == .dark)
        #expect(store.load().statusBarDisplayStyle == .rings)
        #expect(store.load().statusBarMetersDetailStyle == .both)
        #expect(store.load().statusBarBatteryScope == .both)
        #expect(store.load().statusBarBatteryDetailStyle == .remainingPercent)
        #expect(store.load().statusBarProviderScope == .both)
        #expect(store.load().refreshIntervalSeconds == 120)
        #expect(store.load().widgetRefreshIntervalSeconds == 300)
        #expect(store.load().apiCostSummaryRange == .thisMonth)
        #expect(store.load().showsCostSummary == false)
        #expect(store.load().showsRecentSessions)
        #expect(store.load().showsSessionRepairSummary == false)
        #expect(store.load().showsRateLimitResetToday)
        #expect(store.load().showsTokenUsageHeatmap)
        #expect(store.load().tokenUsageChartStyle == .heatmap)
        #expect(store.load().rateLimitResetTodayRefreshIntervalSeconds == 3_600)
        #expect(store.load().automaticallyChecksForUpdates == false)
        #expect(store.load().quotaAlertsEnabled)
        #expect(store.load().resetCreditAlertsEnabled)
        #expect(store.load().rateLimitResetTodayAlertsEnabled == false)
        #expect(store.load().exportsStatusJSON)
    }

    @Test("old preferences default to the Codex provider")
    func oldPreferencesDefaultProvider() throws {
        let data = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(RunwayPreferences.self, from: data)

        #expect(preferences.selectedProvider == .codex)
        #expect(RunwayProvider.allCases == [.codex, .grok])
    }

    @Test("old preferences default rate-limit-reset-today section on with 1h refresh")
    func oldPreferencesDefaultRateLimitResetToday() throws {
        let data = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300,
          "showsCostSummary": true,
          "showsSessionRepairSummary": true
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(RunwayPreferences.self, from: data)

        #expect(preferences.showsRateLimitResetToday)
        #expect(preferences.rateLimitResetTodayRefreshIntervalSeconds == 3_600)
        #expect(preferences.showsTokenUsageHeatmap)
    }

    @Test("model-specific quota usage defaults off and persists opt-in")
    func modelSpecificQuotaUsagePreference() throws {
        #expect(RunwayPreferences().showsModelSpecificQuotaUsage == false)

        let oldData = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300
        }
        """.data(using: .utf8)!
        let oldPreferences = try JSONDecoder().decode(RunwayPreferences.self, from: oldData)
        #expect(oldPreferences.showsModelSpecificQuotaUsage == false)

        let suiteName = "CodexRunwayModelQuotaPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        var optedIn = RunwayPreferences()
        optedIn.showsModelSpecificQuotaUsage = true

        store.save(optedIn)

        #expect(store.load().showsModelSpecificQuotaUsage)
    }

    @Test("old preferences default token usage heatmap on")
    func oldPreferencesDefaultTokenUsageHeatmap() throws {
        let data = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300,
          "showsCostSummary": true
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(RunwayPreferences.self, from: data)
        #expect(preferences.showsTokenUsageHeatmap)
        #expect(preferences.tokenUsageChartStyle == .heatmap)
    }

    @Test("token usage chart style persists")
    func tokenUsageChartStylePersists() {
        let suiteName = "CodexRunwayPreferencesChartStyle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        var preferences = RunwayPreferences()
        preferences.tokenUsageChartStyle = .line
        store.save(preferences)
        #expect(store.load().tokenUsageChartStyle == .line)

        preferences.tokenUsageChartStyle = .bar
        store.save(preferences)
        #expect(store.load().tokenUsageChartStyle == .bar)
    }

    @Test("old preferences use new status bar defaults")
    func oldPreferencesDefaultMetersDetail() throws {
        let data = """
        {
          "language": "english",
          "appearance": "dark",
          "refreshIntervalSeconds": 300,
          "showsCostSummary": true,
          "showsSessionRepairSummary": true
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(RunwayPreferences.self, from: data)

        #expect(preferences.statusBarDisplayStyle == .meters)
        #expect(preferences.statusBarMetersDetailStyle == .remainingPercent)
        #expect(preferences.statusBarBatteryScope == .fiveHour)
        #expect(preferences.statusBarBatteryDetailStyle == .countdown)
        #expect(preferences.statusBarProviderScope == .selected)
        #expect(preferences.apiCostSummaryRange == .today)
        #expect(preferences.showsCostSummary)
        #expect(preferences.showsRecentSessions == false)
        #expect(preferences.automaticallyChecksForUpdates)
        #expect(preferences.quotaAlertsEnabled == false)
        #expect(preferences.resetCreditAlertsEnabled == false)
        #expect(preferences.rateLimitResetTodayAlertsEnabled)
        #expect(preferences.exportsStatusJSON == false)
    }

    @Test("reset short label uses time today and date otherwise")
    func resetShortLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 9)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 18, minute: 30)))
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 8)))

        #expect(ResetLabelFormatter.shortLabel(for: today, now: now, language: .simplifiedChinese, calendar: calendar) == "18:30")
        #expect(ResetLabelFormatter.shortLabel(for: later, now: now, language: .simplifiedChinese, calendar: calendar) == "7/3")
    }

    @Test("reset credit dates follow app language and omit expiry comma")
    func resetCreditDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let updated = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 16, minute: 26)))
        let expires = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 9, minute: 50)))

        #expect(ResetCreditDateFormatter.updatedAt(updated, language: .simplifiedChinese) == "2026年6月30日 16:26")
        #expect(ResetCreditDateFormatter.expiresAt(expires, language: .simplifiedChinese) == "2026/7/12 09:50")
        #expect(!ResetCreditDateFormatter.expiresAt(expires, language: .english).contains(","))
    }

    @Test("localized durations use readable units")
    func localizedDurationsUseReadableUnits() {
        let seconds: TimeInterval = 3_661

        #expect(DurationFormatter.localized(seconds, language: .simplifiedChinese) == "1小时1分钟1秒")
        #expect(DurationFormatter.localized(seconds, language: .english) == "1 hour 1 minute 1 second")
        #expect(DurationFormatter.localized(seconds, language: .simplifiedChinese, includeSeconds: false) == "1小时1分钟")
        #expect(DurationFormatter.localized(305 * 3_600 + 54 * 60, language: .simplifiedChinese) == "12天17小时")
        #expect(DurationFormatter.localized(305 * 3_600 + 54 * 60, language: .english) == "12 days 17 hours")
    }

    @Test("relative past durations mention ago")
    func relativePastDurationsMentionAgo() {
        let calculatedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_030)

        #expect(DurationFormatter.relativePast(since: calculatedAt, now: now, language: .simplifiedChinese) == "30秒之前")
        #expect(DurationFormatter.relativePast(since: calculatedAt, now: now, language: .english) == "30 seconds ago")
    }

    @Test("single instance guard rejects a second holder")
    func singleInstanceGuardRejectsSecondHolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appending(path: "app.lock")

        let first = try #require(try SingleInstanceGuard.acquire(lockURL: lock))
        #expect(try SingleInstanceGuard.acquire(lockURL: lock) == nil)
        _ = first
    }
}
