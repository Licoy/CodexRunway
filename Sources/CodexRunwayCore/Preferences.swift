import Foundation

public enum L10nKey: String, CaseIterable, Sendable {
    case apiCost
    case apiCostSummaryRange
    case apiCostSource
    case apiEquivalent
    case apiTokenPricing
    case appearance
    case appearanceDark
    case appearanceLight
    case appearanceSystem
    case auto
    case about
    case advanced
    case account
    case accounts
    case accountsAdd
    case accountsAddAPIKey
    case accountsAddFile
    case accountsAddLocal
    case accountsAddOAuth
    case accountsAddPaste
    case accountsAPIKeyHint
    case accountsCurrent
    case accountsDelete
    case accountsDeleteConfirmMessage
    case accountsDeleteConfirmTitle
    case accountsEmpty
    case accountsImportFailed
    case accountsImportNoCredentials
    case accountsImportProgress
    case accountsImportSucceeded
    case accountsIsCurrentLogin
    case accountsMakeCurrent
    case accountsMoveDown
    case accountsMoveUp
    case accountsNeedsReauth
    case accountsNote
    case accountsOAuthCancelled
    case accountsOAuthFailed
    case accountsOAuthWaiting
    case accountsPasteFromClipboard
    case accountsPasteHint
    case accountsRefreshAll
    case accountsReauthRequired
    case accountsRestartCodexAfterSwitch
    case accountsRestartCodexFailed
    case accountsRestartCodexSucceeded
    case accountsSidebarTitle
    case accountsSwitchConfirmMessage
    case accountsSwitchConfirmTitle
    case accountsSwitchFailed
    case accountsSwitchInvalidCredential
    case accountsSwitchMissingRefresh
    case accountsSwitchSessionExpired
    case accountsSwitching
    case accountsSwitchRealHint
    case alias
    case automaticallyCheckForUpdates
    case available
    case availableResets
    case back
    case backup
    case cachedInputTokens
    case cachedInput
    case cancel
    case calculate
    case calculating
    case codexFolder
    case controlPanel
    case calculatedAt
    case costShare
    case costScanFailed
    case costScanPreparing
    case costScanIndexing
    case costScanAggregating
    case costScanFetchingOnline
    case costScanProgressFiles
    case credit
    case creditsBalance
    case creditsUsed
    case currentCycle
    case currentCycleAmount
    case customRange
    case customRangePrompt
    case cycleStarted
    case date
    case burnRate
    case duplicate
    case duplicateIndexIDs
    case display
    case endDate
    case estimatedAPICost
    case expiresRemaining
    case expiresAt
    case expiryRisk
    case expiringSoon
    case error
    case checkForUpdates
    case fiveHourUsage
    case general
    case hours
    case modelBreakdown
    case noModelCostData
    case nonCachedInput
    case inputShort
    case inputCachedOutput
    case inputTokens
    case invalidDateRange
    case exportStatusJSON
    case exhaustsIn
    case language
    case languageEnglish
    case languageSimplifiedChinese
    case lastReset
    case lastUpdated
    case later
    case left
    case minutes
    case missing
    case missingFromIndex
    case nextResetIn
    case nextExpiry
    case needsAttention
    case noExpiry
    case noAvailableResetCredits
    case notLoggedIn
    case authExpired
    case authFileInvalid
    case noPreviousIndex
    case notLoaded
    case notScanned
    case ok
    case openControlPanel
    case openDetailsWindow
    case orphan
    case orphanIndexRows
    case outputTokens
    case outputShort
    case openGithub
    case tokenComposition
    case feedbackIssue
    case failed
    case historicalUsage
    case privacy
    case plan
    case planAPI
    case planBusiness
    case planEdu
    case planEnterprise
    case planFree
    case planPlus
    case planPro5x
    case planPro20x
    case planTeam
    case planUnknown
    case plannedEntries
    case pricingVersion
    case projectBreakdown
    case projectedAtReset
    case projectedWeeklyTotal
    case previousCycle
    case quota
    case quotaAlertBody
    case quotaAlertTitle
    case quotaAlertsDescription
    case quotaAlerts
    case quit
    case rawAnalyticsCredits
    case rateLimitResetToday
    case rateLimitResetTodayAwaiting
    case rateLimitResetTodayCheckCost
    case rateLimitResetTodayConfidence
    case rateLimitResetTodayDescription
    case rateLimitResetTodayEvidenceBankedReset
    case rateLimitResetTodayEvidenceLimitIncrease
    case rateLimitResetTodayEvidenceResetCompleted
    case rateLimitResetTodayEvidenceResetScheduled
    case rateLimitResetTodayEvidenceUncertain
    case rateLimitResetTodayLastCheck
    case rateLimitResetTodayLastFetched
    case rateLimitResetTodayLocalDayHint
    case rateLimitResetTodayLatestEvidence
    case rateLimitResetTodayNextScheduled
    case rateLimitResetTodayNo
    case rateLimitResetTodayNoHint
    case rateLimitResetTodayNoHintWithNext
    case rateLimitResetTodayOpenSource
    case rateLimitResetTodayOpenEvidence
    case rateLimitResetTodayPlanAll
    case rateLimitResetTodayPlanBusiness
    case rateLimitResetTodayPlanEnterprise
    case rateLimitResetTodayPlanFree
    case rateLimitResetTodayPlanPlus
    case rateLimitResetTodayPlanPro
    case rateLimitResetTodayPlanTeam
    case rateLimitResetTodayPlanUnknown
    case rateLimitResetTodayPlans
    case rateLimitResetTodayRefreshInterval
    case rateLimitResetTodaySeen
    case rateLimitResetTodaySource
    case rateLimitResetTodaySourceInfo
    case rateLimitResetTodaySourceTitle
    case rateLimitResetTodayUnknown
    case rateLimitResetTodayUnknownHint
    case rateLimitResetTodayVerdict
    case rateLimitResetTodayWindowFiveHour
    case rateLimitResetTodayWindowUnknown
    case rateLimitResetTodayWindowWeekly
    case rateLimitResetTodayWindows
    case rateLimitResetTodayYes
    case rateLimitResetTodayYesHint
    case rateLimitResetTodayYesHintWithTime
    case recent
    case recentSessionsDescription
    case refresh
    case refreshInterval
    case rebuilt
    case repair
    case repairConfirmMessage
    case repairConfirmTitle
    case repairFailed
    case repairIndex
    case resetsIn
    case resetCredits
    case resetCreditAlertBody
    case resetCreditAlertTitle
    case resetCreditAlertsDescription
    case resetCreditAlerts
    case resetCreditDetails
    case runway
    case seconds
    case sessionRepair
    case sessionScanFailed
    case recentSessions
    case settings
    case selfCheck
    case showDetails
    case showCostSummary
    case showRateLimitResetToday
    case showRecentSessions
    case showSessionRepairSummary
    case showTokenUsageHeatmap
    case tokenUsageHeatmap
    case tokenUsageHeatmapDescription
    case tokenUsageHeatmapUnavailable
    case tokenUsageChartStyle
    case tokenUsageChartHeatmap
    case tokenUsageChartLine
    case tokenUsageChartBar
    case heatmapDaily
    case heatmapWeekly
    case heatmapCumulative
    case heatmapMonthly
    case heatmapEmpty
    case heatmapAllDevices
    case heatmapLocalDevice
    case heatmapOfficialAsOf
    case heatmapSourceDisclosure
    case heatmapSourceMismatch
    case sourceLocalSessions
    case sourceOnlineSupplement
    case staleTitles
    case status
    case subscriptionExpired
    case subscriptionExpires
    case subscriptionExpiringSoon
    case statusAvailable
    case statusError
    case statusLogin
    case statusBarBattery
    case statusBarBatteryDetailCountdown
    case statusBarBatteryDetailRemainingPercent
    case statusBarBatteryDetailStyle
    case statusBarBatteryScope
    case statusBarBatteryScopeBoth
    case statusBarBatteryScopeFiveHour
    case statusBarBatteryScopeWeekly
    case statusBarCountdown
    case statusBarMetersDetailResetTime
    case statusBarMetersDetailRemainingPercent
    case statusBarMetersDetailBoth
    case statusBarMetersDetailStyle
    case statusBarMeters
    case statusBarRings
    case statusBarStyle
    case statusUsed
    case statusWait
    case statusUnknown
    case startDate
    case updateAvailable
    case updateCheckFailed
    case updateChecking
    case updateDownloadAndInstall
    case updateDownloadedReady
    case updateDownloading
    case updateExtracting
    case updateInstallAndRelaunch
    case updateInstallLater
    case updateInstalled
    case updateInstalledMessage
    case updateInstalling
    case updateLearnMore
    case updateNetworkProxyHint
    case updateReadyToInstall
    case updateSigningKeyMissing
    case updateSkipVersion
    case updateUnavailableInDevelopment
    case updateVersionAvailable
    case upToDate
    case total
    case totalRemaining
    case tokens
    case tokensOnly
    case testNotification
    case testNotificationBody
    case testNotificationDevelopmentMode
    case testNotificationSubtitle
    case testNotificationTitle
    case threads
    case today
    case thisMonth
    case turns
    case unknown
    case unknownAccount
    case unknownModels
    case unavailableCredits
    case usageAnalyticsUnavailable
    case usageAnalyticsEmpty
    case used
    case usdPerCredit
    case version
    case weeklyValueEstimate
    case weeklyUsage
}

public struct L10n: Sendable {
    public var language: ResolvedLanguage

    public init(language: ResolvedLanguage) {
        self.language = language
    }

    public init(preference: LanguagePreference, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = Self.resolve(preference, preferredLanguages: preferredLanguages)
    }

    public init(preference: LanguagePreference, localeIdentifier: String) {
        self.language = Self.resolve(preference, localeIdentifier: localeIdentifier)
    }

    public static func resolve(_ preference: LanguagePreference, localeIdentifier: String) -> ResolvedLanguage {
        resolve(preference, preferredLanguages: [localeIdentifier])
    }

    public static func resolve(_ preference: LanguagePreference, preferredLanguages: [String]) -> ResolvedLanguage {
        switch preference {
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .system:
            return preferredLanguages.contains { $0.lowercased().hasPrefix("zh") } ? .simplifiedChinese : .english
        }
    }

    public func text(_ key: L10nKey) -> String {
        let table = language == .simplifiedChinese ? Self.zhHans : Self.en
        return table[key] ?? Self.en[key] ?? key.rawValue
    }

    public static func missingTranslations(for language: ResolvedLanguage) -> [L10nKey] {
        let table = language == .simplifiedChinese ? zhHans : en
        return L10nKey.allCases.filter { table[$0] == nil }
    }
}
