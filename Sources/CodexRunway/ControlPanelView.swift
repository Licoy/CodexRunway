import AppKit
import CodexRunwayCore
import SwiftUI

enum ControlPanelTab: String, Hashable, CaseIterable {
    case general
    case accounts
    case display
    case advanced
    case about

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .accounts:
            return "person.2"
        case .display:
            return "eye"
        case .advanced:
            return "slider.horizontal.3"
        case .about:
            return "info.circle"
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .general:
            return .general
        case .accounts:
            return .accounts
        case .display:
            return .display
        case .advanced:
            return .advanced
        case .about:
            return .about
        }
    }

    func title(_ l10n: L10n) -> String {
        l10n.text(titleKey)
    }
}

struct ControlPanelView: View {
    static let githubURL = URL(string: "https://github.com/Licoy/codex-runway")!
    nonisolated static let panelHeight: CGFloat = ControlPanelLayout.panelHeight
    private static let feedbackURL = URL(string: "https://github.com/Licoy/codex-runway/issues/new")!

    @ObservedObject var settings: RunwaySettings
    @ObservedObject var model: RunwayModel
    var checkForUpdates: () -> Void
    var initialTab: ControlPanelTab = .general

    @State private var selectedTab: ControlPanelTab
    @State private var confirmRepair = false
    @State private var notificationMessage: String?
    private var l10n: L10n { settings.l10n }
    private var tabTitles: [String] {
        ControlPanelTab.allCases.map { $0.title(l10n) }
    }
    private var panelWidth: CGFloat {
        ControlPanelLayout.panelWidth(titles: tabTitles)
    }

    init(
        settings: RunwaySettings,
        model: RunwayModel,
        checkForUpdates: @escaping () -> Void,
        initialTab: ControlPanelTab = .general)
    {
        self.settings = settings
        self.model = model
        self.checkForUpdates = checkForUpdates
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalPane
                .tabItem { Label(l10n.text(.general), systemImage: "gearshape") }
                .tag(ControlPanelTab.general)
            AccountsSettingsPane(model: model, l10n: l10n)
                .tabItem { Label(l10n.text(.accounts), systemImage: "person.2") }
                .tag(ControlPanelTab.accounts)
            displayPane
                .tabItem { Label(l10n.text(.display), systemImage: "eye") }
                .tag(ControlPanelTab.display)
            advancedPane
                .tabItem { Label(l10n.text(.advanced), systemImage: "slider.horizontal.3") }
                .tag(ControlPanelTab.advanced)
            aboutPane
                .tabItem { Label(l10n.text(.about), systemImage: "info.circle") }
                .tag(ControlPanelTab.about)
        }
        // Rebuild SwiftUI's native toolbar item so it cannot retain the
        // previous language's wider frame after the window contracts.
        .id(l10n.language.rawValue)
        .padding(.horizontal, ControlPanelLayout.horizontalContentPadding)
        .padding(.vertical, 16)
        .frame(width: panelWidth, height: Self.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(l10n.text(.repairConfirmTitle), isPresented: $confirmRepair) {
            Button(l10n.text(.repair), role: .destructive) { model.repairSessions() }
            Button(l10n.text(.cancel), role: .cancel) {}
        } message: {
            Text(model.repairWarning)
        }
        .alert(l10n.text(.testNotification), isPresented: notificationMessageBinding) {
            Button(l10n.text(.ok), role: .cancel) {}
        } message: {
            Text(notificationMessage ?? "")
        }
    }

    private var generalPane: some View {
        PreferencesPane(remasureToken: l10n.language) {
            SettingsSection {
                SectionLabel(l10n.text(.general))
                PickerRow(
                    title: l10n.text(.language),
                    subtitle: l10n.text(.auto),
                    controlWidth: LanguagePickerSizing.controlWidth(
                        selectedTitle: settings.preferences.language.menuTitle(uiLanguage: l10n.language)))
                {
                    Picker(l10n.text(.language), selection: languageBinding) {
                        ForEach(LanguagePreference.allCases, id: \.self) { preference in
                            Text(preference.menuTitle(uiLanguage: l10n.language)).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize(horizontal: true, vertical: false)
                }
                PickerRow(title: l10n.text(.refreshInterval), subtitle: l10n.text(.minutes)) {
                    Picker(l10n.text(.refreshInterval), selection: refreshBinding) {
                        ForEach([60, 300, 600, 900, 1_800], id: \.self) { seconds in
                            Text("\(seconds / 60) \(l10n.text(.minutes))").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if #available(macOS 14.0, *) {
                    PickerRow(
                        title: l10n.text(.widgetRefreshInterval),
                        subtitle: l10n.text(.widgetRefreshIntervalDescription))
                    {
                        Picker(l10n.text(.widgetRefreshInterval), selection: widgetRefreshBinding) {
                            ForEach(RunwayPreferences.widgetRefreshIntervalOptions, id: \.self) { seconds in
                                Text(widgetRefreshIntervalLabel(seconds)).tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                PickerRow(title: l10n.text(.codexFolder), subtitle: "~/.codex") {
                    Button(l10n.text(.codexFolder), action: openCodexFolder)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var displayPane: some View {
        PreferencesPane(remasureToken: l10n.language) {
            SettingsSection {
                SectionLabel(l10n.text(.displayAppearanceSection))
                PickerRow(title: l10n.text(.appearance), subtitle: l10n.text(.appearanceSystem)) {
                    Picker(l10n.text(.appearance), selection: appearanceBinding) {
                        Text(l10n.text(.appearanceSystem)).tag(AppearancePreference.system)
                        Text(l10n.text(.appearanceLight)).tag(AppearancePreference.light)
                        Text(l10n.text(.appearanceDark)).tag(AppearancePreference.dark)
                    }
                    .pickerStyle(.segmented)
                }
                PickerRow(title: l10n.text(.statusBarStyle), subtitle: l10n.text(.display)) {
                    Picker(l10n.text(.statusBarStyle), selection: statusBarStyleBinding) {
                        ForEach(StatusBarDisplayStyle.allCases, id: \.self) { style in
                            Text(style.title(l10n)).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                }
                PickerRow(title: l10n.text(.statusBarProviderScope), subtitle: l10n.text(.display)) {
                    Picker(l10n.text(.statusBarProviderScope), selection: statusBarProviderScopeBinding) {
                        ForEach(StatusBarProviderScope.allCases, id: \.self) { scope in
                            Text(scope.title(l10n)).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if settings.preferences.statusBarDisplayStyle == .meters {
                    PickerRow(title: l10n.text(.statusBarMetersDetailStyle), subtitle: l10n.text(.statusBarMeters)) {
                        Picker(l10n.text(.statusBarMetersDetailStyle), selection: statusBarMetersDetailStyleBinding) {
                            ForEach(StatusBarMetersDetailStyle.allCases, id: \.self) { style in
                                Text(style.title(l10n)).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if settings.preferences.statusBarDisplayStyle == .battery {
                    PickerRow(title: l10n.text(.statusBarBatteryScope), subtitle: l10n.text(.statusBarBattery)) {
                        Picker(l10n.text(.statusBarBatteryScope), selection: statusBarBatteryScopeBinding) {
                            ForEach(StatusBarBatteryScope.allCases, id: \.self) { scope in
                                Text(scope.title(l10n)).tag(scope)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    PickerRow(title: l10n.text(.statusBarBatteryDetailStyle), subtitle: l10n.text(.statusBarBattery)) {
                        Picker(l10n.text(.statusBarBatteryDetailStyle), selection: statusBarBatteryDetailStyleBinding) {
                            ForEach(StatusBarBatteryDetailStyle.allCases, id: \.self) { style in
                                Text(style.title(l10n)).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            SettingsSection {
                MainPanelModuleSectionHeader(
                    title: l10n.text(.mainPanelModules),
                    subtitle: l10n.text(.mainPanelModulesDescription),
                    restoreTitle: l10n.text(.restoreDefaultOrder),
                    restoreDisabled: settings.preferences.mainPanelModuleOrder
                        == RunwayPreferences.defaultMainPanelModuleOrder,
                    onRestore: { settings.resetMainPanelModuleOrder() })
                VStack(spacing: 10) {
                    ForEach(
                        Array(settings.preferences.mainPanelModuleOrder.enumerated()),
                        id: \.element)
                    { index, module in
                        MainPanelModuleCard(
                            title: module.title(l10n),
                            subtitle: module.subtitle(l10n),
                            platform: module.platformTitle(l10n),
                            systemImage: module.systemImage,
                            visibleTitle: l10n.text(.moduleVisible),
                            hiddenTitle: l10n.text(.moduleHidden),
                            moveUpTitle: l10n.text(.accountsMoveUp),
                            moveDownTitle: l10n.text(.accountsMoveDown),
                            isEnabled: moduleVisibilityBinding(module),
                            hasConfiguration: module.hasConfiguration,
                            showsConfigurationWhenHidden: module.showsConfigurationWhenHidden,
                            canMoveUp: index > 0,
                            canMoveDown: index + 1 < settings.preferences.mainPanelModuleOrder.count,
                            onMoveUp: { settings.moveMainPanelModule(module, by: -1) },
                            onMoveDown: { settings.moveMainPanelModule(module, by: 1) })
                        {
                            moduleConfiguration(module)
                        }
                    }
                }
                .animation(
                    .easeInOut(duration: 0.18),
                    value: settings.preferences.mainPanelModuleOrder)
            }
            SettingsSection {
                SectionLabel(l10n.text(.notificationSettings))
                PreferenceToggleRow(
                    title: l10n.text(.quotaAlerts),
                    subtitle: l10n.text(.quotaAlertsDescription),
                    binding: quotaAlertsBinding)
                PreferenceToggleRow(
                    title: l10n.text(.resetCreditAlerts),
                    subtitle: l10n.text(.resetCreditAlertsDescription),
                    binding: resetCreditAlertsBinding)
                PreferenceToggleRow(
                    title: l10n.text(.rateLimitResetTodayAlerts),
                    subtitle: l10n.text(.rateLimitResetTodayAlertsDescription),
                    binding: rateLimitResetTodayAlertsBinding)
                ActionRow(
                    title: l10n.text(.testNotification),
                    subtitle: l10n.text(.testNotificationSubtitle),
                    button: l10n.text(.testNotification)) {
                        notificationMessage = model.testNotification()
                    }
            }
        }
    }

    @ViewBuilder
    private func moduleConfiguration(_ module: MainPanelModule) -> some View {
        switch module {
        case .quota:
            PreferenceToggleRow(
                title: l10n.text(.showModelSpecificQuotaUsage),
                subtitle: l10n.text(.modelSpecificQuotaUsageDescription),
                binding: modelSpecificQuotaUsageBinding)
        case .tokenUsage:
            ModulePickerRow(title: l10n.text(.tokenUsageChartStyle)) {
                Picker(l10n.text(.tokenUsageChartStyle), selection: tokenUsageChartStyleBinding) {
                    ForEach(TokenUsageChartStyle.allCases, id: \.self) { style in
                        Text(style.title(l10n)).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }
        case .rateLimitResetToday:
            ModulePickerRow(title: l10n.text(.rateLimitResetTodayRefreshInterval)) {
                Picker(
                    l10n.text(.rateLimitResetTodayRefreshInterval),
                    selection: rateLimitResetTodayRefreshIntervalBinding)
                {
                    ForEach(RunwayPreferences.rateLimitResetTodayRefreshIntervalOptions, id: \.self) { seconds in
                        Text(rateLimitResetTodayIntervalLabel(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
            }
        case .apiCost:
            ModulePickerRow(title: l10n.text(.apiCostSummaryRange)) {
                Picker(l10n.text(.apiCostSummaryRange), selection: apiCostSummaryRangeBinding) {
                    ForEach(ApiCostSummaryRange.allCases, id: \.self) { range in
                        Text(range.title(l10n)).tag(range)
                    }
                }
                .pickerStyle(.menu)
            }
        case .quotaEstimate:
            ModulePickerRow(title: l10n.text(.quotaEstimateWindowMode)) {
                Picker(l10n.text(.quotaEstimateWindowMode), selection: quotaEstimateWindowModeBinding) {
                    ForEach(QuotaEstimateWindowMode.allCases, id: \.self) { mode in
                        Text(mode.title(l10n)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
        case .resetCredits, .sessionRepair, .recentSessions:
            EmptyView()
        }
    }

    private var advancedPane: some View {
        PreferencesPane(remasureToken: l10n.language) {
            SettingsSection {
                SectionLabel(l10n.text(.advanced))
                ActionRow(title: l10n.text(.refresh), subtitle: l10n.text(.quota), button: l10n.text(.refresh)) {
                    model.refresh()
                }
                ActionRow(title: l10n.text(.selfCheck), subtitle: l10n.text(.sessionRepair), button: l10n.text(.selfCheck)) {
                    model.refresh()
                    model.refreshSessionReport()
                }
                PreferenceToggleRow(
                    title: l10n.text(.exportStatusJSON),
                    subtitle: "~/.codex-runway/status.json",
                    binding: exportsStatusJSONBinding)
                ActionRow(title: l10n.text(.repairIndex), subtitle: l10n.text(.backup), button: l10n.text(.repair), role: .destructive) {
                    confirmRepair = true
                }
            }
        }
    }

    private var aboutPane: some View {
        PreferencesPane(remasureToken: l10n.language) {
            SettingsSection {
                AboutLogoView()
                SectionLabel(l10n.text(.about))
                InfoRow(title: l10n.text(.version), subtitle: appVersion, value: "Codex Runway")
                PreferenceToggleRow(
                    title: l10n.text(.automaticallyCheckForUpdates),
                    subtitle: l10n.text(.checkForUpdates),
                    binding: automaticallyChecksForUpdatesBinding)
                ActionRow(
                    title: l10n.text(.checkForUpdates),
                    subtitle: l10n.text(.version),
                    button: l10n.text(.checkForUpdates),
                    action: checkForUpdates)
                ActionRow(
                    title: "GitHub",
                    subtitle: "github.com/Licoy/codex-runway",
                    button: l10n.text(.openGithub)) {
                        ExternalURLLauncher.open(Self.githubURL)
                    }
                ActionRow(
                    title: l10n.text(.feedbackIssue),
                    subtitle: "GitHub Issues",
                    button: l10n.text(.feedbackIssue)) {
                        ExternalURLLauncher.open(Self.feedbackURL)
                    }
            }
        }
    }

    private func openCodexFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }

    private var languageBinding: Binding<LanguagePreference> {
        Binding(get: { settings.preferences.language }, set: { settings.updateLanguage($0) })
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(get: { settings.preferences.appearance }, set: { settings.updateAppearance($0) })
    }

    private var refreshBinding: Binding<Int> {
        Binding(get: { settings.preferences.refreshIntervalSeconds }, set: { settings.updateRefreshInterval($0) })
    }

    private var widgetRefreshBinding: Binding<Int> {
        Binding(
            get: { settings.preferences.widgetRefreshIntervalSeconds },
            set: { settings.updateWidgetRefreshInterval($0) })
    }

    private func widgetRefreshIntervalLabel(_ seconds: Int) -> String {
        if seconds == 60 {
            return "60 \(l10n.text(.seconds))"
        }
        return "\(seconds / 60) \(l10n.text(.minutes))"
    }

    private var statusBarStyleBinding: Binding<StatusBarDisplayStyle> {
        Binding(get: { settings.preferences.statusBarDisplayStyle }, set: { settings.updateStatusBarDisplayStyle($0) })
    }

    private var statusBarProviderScopeBinding: Binding<StatusBarProviderScope> {
        Binding(
            get: { settings.preferences.statusBarProviderScope },
            set: { settings.updateStatusBarProviderScope($0) })
    }

    private var statusBarMetersDetailStyleBinding: Binding<StatusBarMetersDetailStyle> {
        Binding(get: { settings.preferences.statusBarMetersDetailStyle }, set: { settings.updateStatusBarMetersDetailStyle($0) })
    }

    private var statusBarBatteryScopeBinding: Binding<StatusBarBatteryScope> {
        Binding(get: { settings.preferences.statusBarBatteryScope }, set: { settings.updateStatusBarBatteryScope($0) })
    }

    private var statusBarBatteryDetailStyleBinding: Binding<StatusBarBatteryDetailStyle> {
        Binding(get: { settings.preferences.statusBarBatteryDetailStyle }, set: { settings.updateStatusBarBatteryDetailStyle($0) })
    }

    private func moduleVisibilityBinding(_ module: MainPanelModule) -> Binding<Bool> {
        switch module {
        case .quota:
            quotaSummaryBinding
        case .tokenUsage:
            tokenUsageHeatmapBinding
        case .rateLimitResetToday:
            rateLimitResetTodayBinding
        case .quotaEstimate:
            quotaEstimateSummaryBinding
        case .resetCredits:
            resetCreditsSummaryBinding
        case .apiCost:
            costSummaryBinding
        case .sessionRepair:
            repairSummaryBinding
        case .recentSessions:
            recentSessionsBinding
        }
    }

    private var quotaSummaryBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsQuotaSummary },
            set: { enabled in
                settings.updateShowsQuotaSummary(enabled)
                guard enabled else { return }
                if model.selectedProvider == .grok {
                    model.refreshGrok(.current)
                } else {
                    model.refreshQuota()
                }
            })
    }

    private var quotaEstimateSummaryBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsQuotaEstimateSummary },
            set: { enabled in
                settings.updateShowsQuotaEstimateSummary(enabled)
                guard enabled else { return }
                model.refreshQuotaEstimate()
            })
    }

    private var quotaEstimateWindowModeBinding: Binding<QuotaEstimateWindowMode> {
        Binding(
            get: { settings.preferences.quotaEstimateWindowMode },
            set: { settings.updateQuotaEstimateWindowMode($0) })
    }

    private var resetCreditsSummaryBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsResetCreditsSummary },
            set: { enabled in
                settings.updateShowsResetCreditsSummary(enabled)
                guard enabled else { return }
                if model.selectedProvider == .grok {
                    model.refreshGrok(.current)
                } else {
                    model.refreshResetCredits()
                }
            })
    }

    private var costSummaryBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsCostSummary },
            set: { enabled in
                settings.updateShowsCostSummary(enabled)
                guard enabled else { return }
                if model.selectedProvider == .grok {
                    model.refreshGrokLocalUsage()
                } else {
                    model.refreshCost()
                }
            })
    }

    private var modelSpecificQuotaUsageBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsModelSpecificQuotaUsage },
            set: { settings.updateShowsModelSpecificQuotaUsage($0) })
    }

    private var tokenUsageHeatmapBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsTokenUsageHeatmap },
            set: { enabled in
                settings.updateShowsTokenUsageHeatmap(enabled)
                guard enabled else { return }
                if model.selectedProvider == .grok {
                    model.refreshGrokLocalUsage()
                } else {
                    model.refreshTokenHeatmap(policy: .force)
                }
            })
    }

    private var tokenUsageChartStyleBinding: Binding<TokenUsageChartStyle> {
        Binding(
            get: { settings.preferences.tokenUsageChartStyle },
            set: { settings.updateTokenUsageChartStyle($0) })
    }

    private var rateLimitResetTodayBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsRateLimitResetToday },
            set: { enabled in
                settings.updateShowsRateLimitResetToday(enabled)
                if enabled {
                    model.refreshRateLimitResetToday(force: true)
                } else {
                    model.setRateLimitResetTodayReactionPollingEnabled(false)
                }
            })
    }

    private var rateLimitResetTodayRefreshIntervalBinding: Binding<Int> {
        Binding(
            get: { settings.preferences.rateLimitResetTodayRefreshIntervalSeconds },
            set: { settings.updateRateLimitResetTodayRefreshInterval($0) })
    }

    private func rateLimitResetTodayIntervalLabel(_ seconds: Int) -> String {
        if seconds < 3_600 {
            return "\(seconds / 60) \(l10n.text(.minutes))"
        }
        let hours = seconds / 3_600
        return "\(hours) \(l10n.text(.hours))"
    }

    private var apiCostSummaryRangeBinding: Binding<ApiCostSummaryRange> {
        Binding(
            get: { settings.preferences.apiCostSummaryRange },
            set: {
                settings.updateApiCostSummaryRange($0)
                model.refreshCost()
            })
    }

    private var notificationMessageBinding: Binding<Bool> {
        Binding(
            get: { notificationMessage != nil },
            set: { if !$0 { notificationMessage = nil } })
    }

    private var recentSessionsBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsRecentSessions },
            set: { enabled in
                settings.updateShowsRecentSessions(enabled)
                guard enabled else { return }
                if model.selectedProvider == .grok {
                    model.refreshGrokLocalUsage()
                } else {
                    model.refreshRecentSessions()
                }
            })
    }

    private var repairSummaryBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsSessionRepairSummary },
            set: { enabled in
                settings.updateShowsSessionRepairSummary(enabled)
                if enabled { model.refreshSessionReport() }
            })
    }

    private var automaticallyChecksForUpdatesBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.automaticallyChecksForUpdates },
            set: { settings.updateAutomaticallyChecksForUpdates($0) })
    }

    private var quotaAlertsBinding: Binding<Bool> {
        Binding(get: { settings.preferences.quotaAlertsEnabled }, set: { settings.updateQuotaAlertsEnabled($0) })
    }

    private var resetCreditAlertsBinding: Binding<Bool> {
        Binding(get: { settings.preferences.resetCreditAlertsEnabled }, set: { settings.updateResetCreditAlertsEnabled($0) })
    }

    private var rateLimitResetTodayAlertsBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.rateLimitResetTodayAlertsEnabled },
            set: { settings.updateRateLimitResetTodayAlertsEnabled($0) })
    }

    private var exportsStatusJSONBinding: Binding<Bool> {
        Binding(get: { settings.preferences.exportsStatusJSON }, set: { settings.updateExportsStatusJSON($0) })
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }
}

private struct AboutLogoView: View {
    var body: some View {
        Group {
            if let image = Self.appIconImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
    }

    private static var appIconImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.png")
        return NSImage(contentsOf: url)
    }
}

private extension StatusBarDisplayStyle {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .countdown: l10n.text(.statusBarCountdown)
        case .battery: l10n.text(.statusBarBattery)
        case .meters: l10n.text(.statusBarMeters)
        case .rings: l10n.text(.statusBarRings)
        case .text: l10n.text(.statusBarText)
        }
    }
}

private extension StatusBarProviderScope {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .selected: l10n.text(.statusBarProviderScopeSelected)
        case .both: l10n.text(.statusBarProviderScopeBoth)
        }
    }
}

private extension StatusBarMetersDetailStyle {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .remainingPercent: l10n.text(.statusBarMetersDetailRemainingPercent)
        case .resetTime: l10n.text(.statusBarMetersDetailResetTime)
        case .both: l10n.text(.statusBarMetersDetailBoth)
        }
    }
}

private extension StatusBarBatteryScope {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .fiveHour: l10n.text(.statusBarBatteryScopeFiveHour)
        case .weekly: l10n.text(.statusBarBatteryScopeWeekly)
        case .both: l10n.text(.statusBarBatteryScopeBoth)
        }
    }
}

private extension StatusBarBatteryDetailStyle {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .countdown: l10n.text(.statusBarBatteryDetailCountdown)
        case .remainingPercent: l10n.text(.statusBarBatteryDetailRemainingPercent)
        }
    }
}

private extension ApiCostSummaryRange {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .today: l10n.text(.today)
        case .current: l10n.text(.currentCycle)
        case .previous: l10n.text(.previousCycle)
        case .thisMonth: l10n.text(.thisMonth)
        }
    }
}

private extension TokenUsageChartStyle {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .heatmap: l10n.text(.tokenUsageChartHeatmap)
        case .line: l10n.text(.tokenUsageChartLine)
        case .bar: l10n.text(.tokenUsageChartBar)
        }
    }
}

private extension QuotaEstimateWindowMode {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .auto: l10n.text(.auto)
        case .rollingWeek: l10n.text(.quotaEstimateWindowRolling)
        }
    }
}

private extension MainPanelModule {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .quota: l10n.text(.quota)
        case .tokenUsage: l10n.text(.tokenUsageHeatmap)
        case .rateLimitResetToday: l10n.text(.rateLimitResetToday)
        case .quotaEstimate: l10n.text(.quotaEstimate)
        case .resetCredits: l10n.text(.resetCredits)
        case .apiCost: l10n.text(.apiCost)
        case .sessionRepair: l10n.text(.sessionRepair)
        case .recentSessions: l10n.text(.recentSessions)
        }
    }

    func subtitle(_ l10n: L10n) -> String {
        switch self {
        case .quota: l10n.text(.moduleQuotaDescription)
        case .tokenUsage: l10n.text(.tokenUsageHeatmapDescription)
        case .rateLimitResetToday: l10n.text(.rateLimitResetTodayDescription)
        case .quotaEstimate: l10n.text(.moduleQuotaEstimateDescription)
        case .resetCredits: l10n.text(.moduleResetCreditsDescription)
        case .apiCost: l10n.text(.moduleAPICostDescription)
        case .sessionRepair: l10n.text(.moduleSessionRepairDescription)
        case .recentSessions: l10n.text(.recentSessionsDescription)
        }
    }

    func platformTitle(_ l10n: L10n) -> String {
        switch self {
        case .rateLimitResetToday, .quotaEstimate, .sessionRepair:
            l10n.text(.moduleAppliesCodex)
        case .quota, .tokenUsage, .resetCredits, .apiCost, .recentSessions:
            l10n.text(.moduleAppliesBoth)
        }
    }

    var systemImage: String {
        switch self {
        case .quota: "gauge"
        case .tokenUsage: "chart.bar.xaxis"
        case .rateLimitResetToday: "arrow.clockwise.circle"
        case .quotaEstimate: "function"
        case .resetCredits: "arrow.counterclockwise.circle"
        case .apiCost: "dollarsign.circle"
        case .sessionRepair: "cross.case"
        case .recentSessions: "clock"
        }
    }

    var hasConfiguration: Bool {
        switch self {
        case .quota, .tokenUsage, .rateLimitResetToday, .quotaEstimate, .apiCost:
            true
        case .resetCredits, .sessionRepair, .recentSessions:
            false
        }
    }

    var showsConfigurationWhenHidden: Bool {
        self == .quota
    }
}

struct PreferencesPane<Content: View>: View {
    var remasureToken: AnyHashable = 0
    @ViewBuilder var content: Content

    var body: some View {
        PolishedScrollView(
            verticalPadding: 0,
            fadesEdges: false,
            remasureToken: remasureToken,
            showsOverlayScroller: true)
        {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

struct SettingsSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

private struct MainPanelModuleSectionHeader: View {
    var title: String
    var subtitle: String
    var restoreTitle: String
    var restoreDisabled: Bool
    var onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                SectionLabel(title)
                Spacer()
                Button(action: onRestore) {
                    Label(restoreTitle, systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(restoreDisabled)
            }
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MainPanelModuleCard<Configuration: View>: View {
    var title: String
    var subtitle: String
    var platform: String
    var systemImage: String
    var visibleTitle: String
    var hiddenTitle: String
    var moveUpTitle: String
    var moveDownTitle: String
    @Binding var isEnabled: Bool
    var hasConfiguration: Bool
    var showsConfigurationWhenHidden: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    @ViewBuilder var configuration: Configuration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isEnabled ? RunwaySurface.hoverAccent : RunwaySurface.sunken),
                        in: RoundedRectangle(
                            cornerRadius: RunwaySurface.radiusRow,
                            style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.medium))
                        Text(platform)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RunwaySurface.sunken,
                                in: Capsule())
                    }
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    ModuleMoveButton(
                        title: moveUpTitle,
                        systemImage: "chevron.up",
                        isEnabled: canMoveUp,
                        action: onMoveUp)
                    ModuleMoveButton(
                        title: moveDownTitle,
                        systemImage: "chevron.down",
                        isEnabled: canMoveDown,
                        action: onMoveDown)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isEnabled ? visibleTitle : hiddenTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(isEnabled ? visibleTitle : hiddenTitle)
                        .accessibilityLabel(isEnabled ? visibleTitle : hiddenTitle)
                        .accessibilityValue(isEnabled ? visibleTitle : hiddenTitle)
                }
            }
            .padding(11)

            if hasConfiguration, isEnabled || showsConfigurationWhenHidden {
                Divider()
                    .opacity(0.7)
                configuration
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .runwayCard(isEnabled ? .raised : .sunken)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }

}

private struct ModuleMoveButton: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ModulePickerRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            control
                .labelsHidden()
                .frame(width: 190, alignment: .trailing)
        }
    }
}

private struct PickerRow<Control: View>: View {
    var title: String
    var subtitle: String
    var controlWidth: CGFloat = 220
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            control.labelsHidden().frame(width: controlWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

enum ExternalURLLauncher {
    /// Opens a URL via Launch Services. Avoid launching browser executables with Process —
    /// that forces a multi-second handoff into an existing browser session.
    @MainActor
    static func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                openWithOpenTool(url)
            }
        }
    }

    @MainActor
    private static func openWithOpenTool(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Last resort: synchronous Launch Services open.
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PreferenceToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var binding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $binding) {
                Text(title).font(.body)
            }
            .toggleStyle(.checkbox)
            Text(subtitle)
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ActionRow: View {
    var title: String
    var subtitle: String
    var button: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            buttonView.fixedSize().frame(width: 220, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var buttonView: some View {
        if role == .destructive {
            Button(button, role: role, action: action)
                .buttonStyle(.bordered)
        } else {
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct InfoRow: View {
    var title: String
    var subtitle: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            if !value.isEmpty {
                Text(value).font(.body)
            }
        }
    }
}

private struct RowText: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body)
            Text(subtitle)
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
