import AppKit
import CodexRunwayCore
import SwiftUI

enum ControlPanelTab: Hashable {
    case general
    case accounts
    case display
    case advanced
    case about
}

struct ControlPanelView: View {
    static let githubURL = URL(string: "https://github.com/Licoy/codex-runway")!
    private static let feedbackURL = URL(string: "https://github.com/Licoy/codex-runway/issues/new")!

    @ObservedObject var settings: RunwaySettings
    @ObservedObject var model: RunwayModel
    var checkForUpdates: () -> Void
    var initialTab: ControlPanelTab = .general

    @State private var selectedTab: ControlPanelTab
    @State private var confirmRepair = false
    @State private var notificationMessage: String?
    private var l10n: L10n { settings.l10n }

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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 546, height: 662)
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
        PreferencesPane {
            SettingsSection {
                SectionLabel(l10n.text(.general))
                PickerRow(title: l10n.text(.language), subtitle: l10n.text(.auto)) {
                    Picker(l10n.text(.language), selection: languageBinding) {
                        Text(l10n.text(.auto)).tag(LanguagePreference.system)
                        Text(l10n.text(.languageEnglish)).tag(LanguagePreference.english)
                        Text(l10n.text(.languageSimplifiedChinese)).tag(LanguagePreference.simplifiedChinese)
                    }
                    .pickerStyle(.menu)
                }
                PickerRow(title: l10n.text(.refreshInterval), subtitle: l10n.text(.minutes)) {
                    Picker(l10n.text(.refreshInterval), selection: refreshBinding) {
                        ForEach([60, 300, 600, 900, 1_800], id: \.self) { seconds in
                            Text("\(seconds / 60) \(l10n.text(.minutes))").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
                PickerRow(title: l10n.text(.codexFolder), subtitle: "~/.codex") {
                    Button(l10n.text(.codexFolder), action: openCodexFolder)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var displayPane: some View {
        PreferencesPane {
            SettingsSection {
                SectionLabel(l10n.text(.display))
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
                PreferenceToggleRow(
                    title: l10n.text(.showTokenUsageHeatmap),
                    subtitle: l10n.text(.tokenUsageHeatmapDescription),
                    binding: tokenUsageHeatmapBinding)
                if settings.preferences.showsTokenUsageHeatmap {
                    PickerRow(
                        title: l10n.text(.tokenUsageChartStyle),
                        subtitle: l10n.text(.tokenUsageHeatmapDescription))
                    {
                        Picker(l10n.text(.tokenUsageChartStyle), selection: tokenUsageChartStyleBinding) {
                            ForEach(TokenUsageChartStyle.allCases, id: \.self) { style in
                                Text(style.title(l10n)).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                PreferenceToggleRow(
                    title: l10n.text(.showCostSummary),
                    subtitle: l10n.text(.apiEquivalent),
                    binding: costSummaryBinding)
                PickerRow(title: l10n.text(.apiCostSummaryRange), subtitle: l10n.text(.apiEquivalent)) {
                    Picker(l10n.text(.apiCostSummaryRange), selection: apiCostSummaryRangeBinding) {
                        ForEach(ApiCostSummaryRange.allCases, id: \.self) { range in
                            Text(range.title(l10n)).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                }
                PreferenceToggleRow(
                    title: l10n.text(.showRateLimitResetToday),
                    subtitle: l10n.text(.rateLimitResetTodayDescription),
                    binding: rateLimitResetTodayBinding)
                if settings.preferences.showsRateLimitResetToday {
                    PickerRow(
                        title: l10n.text(.rateLimitResetTodayRefreshInterval),
                        subtitle: l10n.text(.rateLimitResetTodayDescription))
                    {
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
                }
                PreferenceToggleRow(
                    title: l10n.text(.showRecentSessions),
                    subtitle: l10n.text(.recentSessionsDescription),
                    binding: recentSessionsBinding)
                PreferenceToggleRow(
                    title: l10n.text(.showSessionRepairSummary),
                    subtitle: l10n.text(.sessionRepair),
                    binding: repairSummaryBinding)
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

    private var advancedPane: some View {
        PreferencesPane {
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
        PreferencesPane {
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

    private var statusBarStyleBinding: Binding<StatusBarDisplayStyle> {
        Binding(get: { settings.preferences.statusBarDisplayStyle }, set: { settings.updateStatusBarDisplayStyle($0) })
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

    private var costSummaryBinding: Binding<Bool> {
        Binding(get: { settings.preferences.showsCostSummary }, set: { settings.updateShowsCostSummary($0) })
    }

    private var tokenUsageHeatmapBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showsTokenUsageHeatmap },
            set: { enabled in
                settings.updateShowsTokenUsageHeatmap(enabled)
                if enabled {
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
        Binding(get: { settings.preferences.showsRecentSessions }, set: { settings.updateShowsRecentSessions($0) })
    }

    private var repairSummaryBinding: Binding<Bool> {
        Binding(get: { settings.preferences.showsSessionRepairSummary }, set: { settings.updateShowsSessionRepairSummary($0) })
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

struct PreferencesPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
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

private struct PickerRow<Control: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            control.labelsHidden().frame(width: 220, alignment: .trailing)
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
