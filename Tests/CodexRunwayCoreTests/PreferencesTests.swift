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
        #expect(L10n.resolve(.system, localeIdentifier: "zh-Hant-TW") == .traditionalChinese)
        #expect(L10n.resolve(.system, localeIdentifier: "zh-TW") == .traditionalChinese)
        #expect(L10n.resolve(.system, localeIdentifier: "zh-HK") == .traditionalChinese)
        #expect(L10n.resolve(.system, localeIdentifier: "ko-KR") == .korean)
        #expect(L10n.resolve(.system, localeIdentifier: "ja-JP") == .japanese)
        #expect(L10n.resolve(.system, localeIdentifier: "ru-RU") == .russian)
        #expect(L10n.resolve(.system, localeIdentifier: "fr-FR") == .french)
        #expect(L10n.resolve(.system, localeIdentifier: "en-US") == .english)
        #expect(L10n.resolve(.system, localeIdentifier: "de-DE") == .english)
    }

    @Test("system language resolves from preferred languages")
    func resolvesSystemLanguageFromPreferredLanguages() {
        #expect(L10n.resolve(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(L10n.resolve(.system, preferredLanguages: ["en-US", "zh-Hans-CN"]) == .english)
        #expect(L10n.resolve(.system, preferredLanguages: ["zh-Hant-TW"]) == .traditionalChinese)
        #expect(L10n.resolve(.system, preferredLanguages: ["ko-KR"]) == .korean)
        #expect(L10n.resolve(.system, preferredLanguages: ["ja-JP"]) == .japanese)
        #expect(L10n.resolve(.system, preferredLanguages: ["ru-RU"]) == .russian)
        #expect(L10n.resolve(.system, preferredLanguages: ["fr-FR"]) == .french)
        #expect(L10n.resolve(.system, preferredLanguages: []) == .english)
        #expect(L10n.resolve(.system, preferredLanguages: ["de-DE"]) == .english)
        #expect(L10n.resolve(.english, preferredLanguages: ["zh-Hans-CN"]) == .english)
        #expect(L10n.resolve(.simplifiedChinese, preferredLanguages: ["en-US"]) == .simplifiedChinese)
        #expect(L10n.resolve(.korean, preferredLanguages: ["en-US"]) == .korean)
        #expect(L10n.resolve(.french, preferredLanguages: ["ja-JP"]) == .french)
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
        #expect(english.text(.accountsForceCurrent) == "Force this account as the current login")
        #expect(chinese.text(.accountsForceCurrent) == "强制设为环境当前账号")
        #expect(L10n(language: .traditionalChinese).text(.settings) == "設定")
        #expect(L10n(language: .korean).text(.settings) == "설정")
        #expect(L10n(language: .japanese).text(.settings) == "設定")
        #expect(L10n(language: .russian).text(.settings) == "Настройки")
        #expect(L10n(language: .french).text(.settings) == "Réglages")
    }

    @Test("all localization keys have translations for every resolved language")
    func localizationCompleteness() {
        for language in ResolvedLanguage.allCases {
            #expect(
                L10n.missingTranslations(for: language).isEmpty,
                "missing keys for \(language.rawValue)")
        }
    }

    @Test("language menu titles keep native scripts except Auto")
    func languageMenuTitlesStayNative() {
        let expectedExplicit = [
            LanguagePreference.nativeTitleEnglish,
            LanguagePreference.nativeTitleSimplifiedChinese,
            LanguagePreference.nativeTitleTraditionalChinese,
            LanguagePreference.nativeTitleKorean,
            LanguagePreference.nativeTitleJapanese,
            LanguagePreference.nativeTitleRussian,
            LanguagePreference.nativeTitleFrench,
        ]
        for ui in ResolvedLanguage.allCases {
            #expect(LanguagePreference.system.menuTitle(uiLanguage: ui) == L10n(language: ui).text(.auto))
            let titles = LanguagePreference.explicitCases.map { $0.menuTitle(uiLanguage: ui) }
            #expect(titles == expectedExplicit)
        }
    }

    @Test("new language preference raw values persist and decode")
    func newLanguagePreferenceRoundTrips() throws {
        let suiteName = "CodexRunwayLanguageRoundTrip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        for language in LanguagePreference.explicitCases {
            store.save(RunwayPreferences(language: language))
            #expect(store.load().language == language)
        }

        let data = """
        { "language": "traditionalChinese" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RunwayPreferences.self, from: data)
        #expect(decoded.language == .traditionalChinese)
    }

    @Test("quota bars are the default and first status-bar style")
    func statusBarStyleOrdering() {
        #expect(StatusBarDisplayStyle.allCases.first == .meters)
        #expect(StatusBarDisplayStyle.allCases.last == .text)
        #expect(RunwayPreferences().statusBarDisplayStyle == .meters)
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
            mainPanelHeight: 712.5,
            mainPanelModuleOrder: [.apiCost, .quota, .tokenUsage],
            showsQuotaSummary: false,
            showsResetCreditsSummary: false,
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
        #expect(store.load().mainPanelHeight == 712.5)
        #expect(store.load().mainPanelModuleOrder == [
            .rateLimitResetToday,
            .quotaEstimate,
            .resetCredits,
            .apiCost,
            .quota,
            .tokenUsage,
            .sessionRepair,
            .recentSessions,
        ])
        #expect(store.load().showsQuotaEstimateSummary)
        #expect(store.load().quotaEstimateWindowMode == .auto)
        #expect(store.load().showsQuotaSummary == false)
        #expect(store.load().showsResetCreditsSummary == false)
        #expect(store.load().showsCostSummary == false)
        #expect(store.load().showsRecentSessions)
        #expect(store.load().showsSessionRepairSummary == false)
        #expect(store.load().showsRateLimitResetToday)
        #expect(store.load().showsTokenUsageHeatmap)
        #expect(store.load().tokenUsageChartStyle == .heatmap)
        #expect(store.load().rateLimitResetTodayRefreshIntervalSeconds == 300)
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
        #expect(preferences.mainPanelHeight == RunwayPreferences.defaultMainPanelHeight)
        #expect(preferences.mainPanelModuleOrder == RunwayPreferences.defaultMainPanelModuleOrder)
        #expect(preferences.showsQuotaSummary)
        #expect(preferences.showsResetCreditsSummary)
        #expect(preferences.showsQuotaEstimateSummary)
        #expect(preferences.mainPanelModuleOrder.contains(.quotaEstimate))
    }

    @Test("main panel height is clamped when initialized or decoded")
    func mainPanelHeightBounds() throws {
        #expect(RunwayPreferences(mainPanelHeight: 100).mainPanelHeight
            == RunwayPreferences.minimumMainPanelHeight)
        #expect(RunwayPreferences(mainPanelHeight: 2_000).mainPanelHeight
            == RunwayPreferences.maximumMainPanelHeight)
        #expect(RunwayPreferences(mainPanelHeight: .infinity).mainPanelHeight
            == RunwayPreferences.defaultMainPanelHeight)

        let data = """
        { "mainPanelHeight": 1200 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RunwayPreferences.self, from: data)
        #expect(decoded.mainPanelHeight == RunwayPreferences.maximumMainPanelHeight)
    }

    @Test("main panel order repairs duplicates, unknown values, and new modules")
    func mainPanelOrderNormalization() throws {
        let data = """
        {
          "mainPanelModuleOrder": ["apiCost", "unknown-future-module", "quota", "apiCost"]
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(RunwayPreferences.self, from: data)

        #expect(preferences.mainPanelModuleOrder == [
            .tokenUsage,
            .rateLimitResetToday,
            .quotaEstimate,
            .resetCredits,
            .apiCost,
            .quota,
            .sessionRepair,
            .recentSessions,
        ])
    }

    @Test("main panel modules move one position and restore defaults")
    func mainPanelOrderMovement() {
        var preferences = RunwayPreferences()

        preferences.moveMainPanelModule(.apiCost, by: -1)
        #expect(preferences.mainPanelModuleOrder == [
            .quota,
            .tokenUsage,
            .rateLimitResetToday,
            .quotaEstimate,
            .apiCost,
            .resetCredits,
            .sessionRepair,
            .recentSessions,
        ])

        preferences.moveMainPanelModule(.quota, by: -1)
        #expect(preferences.mainPanelModuleOrder.first == .quota)

        preferences.resetMainPanelModuleOrder()
        #expect(preferences.mainPanelModuleOrder == RunwayPreferences.defaultMainPanelModuleOrder)
    }

    @Test("old preferences default rate-limit-reset-today section on with 5m refresh")
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
        #expect(preferences.rateLimitResetTodayRefreshIntervalSeconds == 300)
        #expect(preferences.showsTokenUsageHeatmap)
        #expect(preferences.showsQuotaEstimateSummary)
        #expect(preferences.quotaEstimateWindowMode == .auto)
        #expect(preferences.mainPanelModuleOrder.firstIndex(of: .quotaEstimate)
            == preferences.mainPanelModuleOrder.firstIndex(of: .resetCredits).map { $0 - 1 })

        let legacy = """
        { "quotaEstimateWindowMode": "officialWeek" }
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RunwayPreferences.self, from: legacy).quotaEstimateWindowMode == .auto)
    }

    @Test("rate-limit-reset-today refresh offers 5 and 10 minutes and keeps saved values")
    func rateLimitResetTodayRefreshIntervalOptions() throws {
        #expect(RunwayPreferences.defaultRateLimitResetTodayRefreshIntervalSeconds == 300)
        #expect(RunwayPreferences.rateLimitResetTodayRefreshIntervalOptions == [
            300, 600, 900, 1_800, 3_600, 7_200, 21_600,
        ])
        #expect(RunwayPreferences().rateLimitResetTodayRefreshIntervalSeconds == 300)
        #expect(RunwayPreferences.clampRateLimitResetTodayRefreshInterval(60) == 300)
        #expect(RunwayPreferences.clampRateLimitResetTodayRefreshInterval(300) == 300)
        #expect(RunwayPreferences.clampRateLimitResetTodayRefreshInterval(600) == 600)
        #expect(RunwayPreferences.clampRateLimitResetTodayRefreshInterval(50_000) == 21_600)

        let savedHour = """
        { "rateLimitResetTodayRefreshIntervalSeconds": 3600 }
        """.data(using: .utf8)!
        #expect(
            try JSONDecoder().decode(RunwayPreferences.self, from: savedHour)
                .rateLimitResetTodayRefreshIntervalSeconds == 3_600)

        let tooFrequent = """
        { "rateLimitResetTodayRefreshIntervalSeconds": 60 }
        """.data(using: .utf8)!
        #expect(
            try JSONDecoder().decode(RunwayPreferences.self, from: tooFrequent)
                .rateLimitResetTodayRefreshIntervalSeconds == 300)
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
        #expect(DurationFormatter.localized(seconds, language: .traditionalChinese) == "1小時1分鐘1秒")
        #expect(DurationFormatter.localized(seconds, language: .japanese) == "1時間1分1秒")
        #expect(DurationFormatter.localized(seconds, language: .japanese) != DurationFormatter.localized(seconds, language: .english))
        #expect(DurationFormatter.localized(seconds, language: .french) == "1 heure 1 minute 1 seconde")
        #expect(DurationFormatter.localized(seconds, language: .russian) == "1 час 1 минута 1 секунда")
        #expect(!DurationFormatter.localized(seconds, language: .russian).contains("hour"))
        #expect(!DurationFormatter.localized(seconds, language: .french).contains("hour"))
    }

    @Test("relative past durations mention ago")
    func relativePastDurationsMentionAgo() {
        let calculatedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_030)

        #expect(DurationFormatter.relativePast(since: calculatedAt, now: now, language: .simplifiedChinese) == "30秒之前")
        #expect(DurationFormatter.relativePast(since: calculatedAt, now: now, language: .english) == "30 seconds ago")
    }

    @Test("single-unit past duration matches the hosted reset-today copy")
    func relativePastSingleUnitMatchesHostedCopy() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(
            DurationFormatter.relativePastSingleUnit(
                since: now.addingTimeInterval(-40 * 60),
                now: now,
                language: .simplifiedChinese)
                == "40分钟")
        #expect(
            DurationFormatter.relativePastSingleUnit(
                since: now.addingTimeInterval(-3 * 3_600),
                now: now,
                language: .english)
                == "3 hours")
        #expect(
            DurationFormatter.relativePastSingleUnit(
                since: now.addingTimeInterval(-3_600),
                now: now,
                language: .simplifiedChinese)
                == "1小时")
        #expect(
            DurationFormatter.relativePastSingleUnit(
                since: now.addingTimeInterval(-2 * 86_400),
                now: now,
                language: .simplifiedChinese)
                == "2天")
        #expect(
            DurationFormatter.relativePastSingleUnit(
                since: now.addingTimeInterval(60),
                now: now,
                language: .english)
                == nil)
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

    @Test("instance lock lives in the app-owned runway directory")
    func defaultLockURLUsesRunwayDirectory() {
        let shipped = SingleInstanceGuard.defaultLockURL()
        #expect(shipped.lastPathComponent == SingleInstanceGuard.lockFileName)
        #expect(shipped.deletingLastPathComponent().lastPathComponent
            == RunwayWidgetSnapshotStore.localDirectoryName)
        #expect(!shipped.pathComponents.contains("Application Support"))
        #expect(!shipped.pathComponents.contains("Group Containers"))
        #expect(!shipped.pathComponents.contains("Containers"))

        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let isolated = SingleInstanceGuard.defaultLockURL(homeDirectory: home)
        #expect(isolated.path.hasPrefix(home.path))
        #expect(Array(isolated.pathComponents.suffix(2))
            == [RunwayWidgetSnapshotStore.localDirectoryName, SingleInstanceGuard.lockFileName])
    }
}
