import AppKit
import CodexRunwayCore
import SwiftUI

/// Renders the main popover (and its detail pages) with fixture data for design checks.
/// Example: CodexRunway --render-main-panel-mock=all /tmp/panel-shots
enum MainPanelMockRender {
    enum Page: String, CaseIterable {
        case main
        case accounts
        case resetCredits = "reset-credits"
        case apiCost = "api-cost"

        var sidePanel: RunwaySidePanel? {
            switch self {
            case .main: return nil
            case .accounts: return .accounts
            case .resetCredits: return .resetCredits
            case .apiCost: return .apiCost
            }
        }
    }

    enum Appearance: String, CaseIterable {
        case light
        case dark

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }
    }

    struct PanelLayoutMeasurement: Equatable, Sendable {
        var panelWidth: CGFloat
        var fittingWidth: CGFloat
        var fittingHeight: CGFloat
        var documentWidth: CGFloat
        var hostAvailable: Bool
    }

    /// Hosts the shipped popover at `RunwayPopoverView.panelSize` and reports
    /// fitting / scroll-document widths for locale layout tests.
    @MainActor
    static func measure(language: ResolvedLanguage) -> PanelLayoutMeasurement {
        let settings = fixtureSettings(language: language)
        let model = fixtureModel(settings: settings)
        let visibility = MainPanelVisibility()
        visibility.isVisible = true
        let root = RunwayPopoverRootView(
            model: model,
            settings: settings,
            mainPanelVisibility: visibility,
            checkForUpdates: {},
            openGitHub: {},
            openControlPanel: { _ in })
        let host = NSHostingView(rootView: AnyView(root))
        let panelWidth = RunwayPopoverView.panelSize.width
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: panelWidth,
            height: RunwayPopoverView.panelSize.height)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let document = findScrollDocument(in: host)
        let documentWidth = document?.frame.width ?? fitting.width
        let hostAvailable = fitting.width > 1 && fitting.height > 1
        return PanelLayoutMeasurement(
            panelWidth: panelWidth,
            fittingWidth: fitting.width,
            fittingHeight: fitting.height,
            documentWidth: documentWidth,
            hostAvailable: hostAvailable)
    }

    @MainActor
    static func writeLayoutDump(to directory: String) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var lines: [String] = []
        for language in ResolvedLanguage.allCases {
            let measurement = measure(language: language)
            lines.append(
                "\(language.rawValue) panel=\(measurement.panelWidth) fitting=\(measurement.fittingWidth)x\(measurement.fittingHeight) document=\(measurement.documentWidth) hostAvailable=\(measurement.hostAvailable)")
            let name = language == .english ? "english.txt" : "\(language.rawValue).txt"
            let file = root.appendingPathComponent(name)
            try lines.last!.write(to: file, atomically: true, encoding: .utf8)
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: root.appendingPathComponent("all.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func findScrollDocument(in view: NSView) -> NSView? {
        if let scroll = view as? NSScrollView {
            return scroll.documentView
        }
        for child in view.subviews {
            if let found = findScrollDocument(in: child) {
                return found
            }
        }
        return nil
    }

    @MainActor
    static func writeAll(to directory: String, language: ResolvedLanguage = .simplifiedChinese) throws {
        for page in Page.allCases {
            for appearance in Appearance.allCases {
                let path = "\(directory)/\(page.rawValue)-\(appearance.rawValue).png"
                try write(page: page, appearance: appearance, language: language, to: path)
            }
        }
    }

    @MainActor
    static func write(
        page: Page,
        appearance: Appearance,
        language: ResolvedLanguage,
        to path: String) throws
    {
        let data = try render(page: page, appearance: appearance, language: language)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url)
        print("wrote \(path) (\(data.count) bytes)")
    }

    @MainActor
    static func render(
        page: Page,
        appearance: Appearance,
        language: ResolvedLanguage) throws -> Data
    {
        let settings = fixtureSettings(language: language)
        let model = fixtureModel(settings: settings)
        let visibility = MainPanelVisibility()
        visibility.isVisible = true

        let root = RunwayPopoverRootView(
            model: model,
            settings: settings,
            mainPanelVisibility: visibility,
            checkForUpdates: {},
            openGitHub: {},
            openControlPanel: { _ in },
            initialDetailPage: page.sidePanel)
            .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: AnyView(root))
        host.appearance = appearance.nsAppearance
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: RunwayPopoverView.panelSize.width,
            height: RunwayPopoverView.panelSize.height)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        if fitting.height > 100 {
            host.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
            host.layoutSubtreeIfNeeded()
        }
        return try pngData(from: host, scale: 2)
    }

    /// 2x bitmap capture so text stays inspectable.
    @MainActor
    private static func pngData(from view: NSView, scale: CGFloat) throws -> Data {
        let bounds = view.bounds
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale),
                pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Isolated preferences so the render never reads or writes the user's real settings.
    /// One fixed suite, wiped per render: unique names would leak a plist per run.
    @MainActor
    private static func fixtureSettings(language: ResolvedLanguage) -> RunwaySettings {
        let suiteName = "codex-runway-mock-render"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("cannot create mock-render defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(language.preference)
        settings.updateShowsRecentSessions(true)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateShowsCostSummary(true)
        settings.updateShowsSessionRepairSummary(true)
        return settings
    }

    /// Model with throwing service stubs (never awaited before capture) and isolated stores.
    @MainActor
    private static func fixtureModel(settings: RunwaySettings) -> RunwayModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-mock-render-\(UUID().uuidString)", isDirectory: true)
        let accountStore = AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.unsupportedURL) },
            fetchResetCredits: { _ in throw URLError(.unsupportedURL) },
            fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
            dryRunSessions: { throw URLError(.unsupportedURL) },
            scanRecentSessions: { _ in throw URLError(.unsupportedURL) })
        let model = RunwayModel(
            settings: settings,
            services: services,
            accountStore: accountStore,
            costCacheStore: UsageCostCacheStore(
                cacheURL: root.appendingPathComponent("api-equivalent-cost.json")))
        seedFixtures(model, l10n: settings.l10n)
        return model
    }

    @MainActor
    private static func seedFixtures(_ model: RunwayModel, l10n: L10n) {
        let now = Date()
        let day: TimeInterval = 24 * 3_600

        model.accountDisplay = RunwayPreviewFixtures.accountDisplay(
            tier: .pro20x,
            displayName: "dev@example.com",
            email: "dev@example.com",
            expiresAt: now.addingTimeInterval(26 * day))

        model.quotaMeters = [
            QuotaMeter(
                title: l10n.text(.fiveHourUsage),
                window: RunwayPreviewFixtures.rateWindow(
                    usedPercent: 37,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(2.6 * 3_600)),
                now: now,
                markerPercents: [25, 50, 75]),
            QuotaMeter(
                title: l10n.text(.weeklyUsage),
                window: RunwayPreviewFixtures.rateWindow(
                    usedPercent: 58,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(3.2 * day)),
                now: now,
                markerPercents: [25, 50, 75]),
        ]

        model.rateLimitResetToday = RateLimitResetTodaySnapshot.devMock(kind: .yes, now: now)

        // Synthetic YTD token series so the heatmap renders in mock shots.
        var heatmap: [String: Int] = [:]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = utc.component(.year, from: now)
        if let start = utc.date(from: DateComponents(year: year, month: 1, day: 1)) {
            var cursor = start
            let today = utc.startOfDay(for: now)
            var index = 0
            while cursor <= today {
                let key = String(
                    format: "%04d-%02d-%02d",
                    utc.component(.year, from: cursor),
                    utc.component(.month, from: cursor),
                    utc.component(.day, from: cursor))
                if index % 3 != 0 {
                    heatmap[key] = (index % 7 + 1) * 12_000 + (index % 5) * 1_500
                }
                guard let next = utc.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                index += 1
            }
        }
        // All-devices series slightly higher than local (simulates multi-client usage).
        model.tokenHeatmapAllDevicesTokens = heatmap.mapValues { Int(Double($0) * 1.6) }
        model.tokenHeatmapLocalTokens = heatmap
        model.tokenHeatmapCalculatedAt = now
        model.tokenHeatmapOfficialStatsAsOf = String(
            format: "%04d-%02d-%02d",
            utc.component(.year, from: now),
            utc.component(.month, from: now),
            utc.component(.day, from: now))
        model.tokenHeatmapOfficialGeneratedAt = now

        let credits = RunwayPreviewFixtures.resetCredits(now: now)
        model.resetCreditSummary = ResetCreditSummary(snapshot: credits)
        model.resetCreditDetails = ResetCreditSummary.sortedByExpiry(credits.credits).enumerated().map { index, credit in
            let remaining = max(0, credit.remainingSeconds)
            let hasExpiry = credit.expiresAt != nil
            let state: ResetCreditState
            if credit.status != "available" {
                state = .unavailable
            } else if hasExpiry, remaining <= 7 * day {
                state = .expiring
            } else {
                state = .available
            }
            return ResetCreditDetail(
                id: credit.id ?? "\(index)",
                title: "\(l10n.text(.credit)) \(index + 1)",
                statusText: l10n.text(credit.status == "available" ? .statusAvailable : .statusUsed),
                state: state,
                expiresAt: credit.expiresAt,
                remainingDuration: remaining,
                remainingProgress: hasExpiry ? min(1, remaining / (30 * day)) : 1)
        }

        let cost = RunwayPreviewFixtures.apiCostSummary(now: now)
        model.costDetail = cost
        model.costText = "\(l10n.text(.estimatedAPICost)) \(cost.estimatedUSD.map(DurationFormatter.money) ?? "--")"
        model.costSubtitle = "\(cost.totals.totalTokens / 1_000_000)M tokens · \(cost.totals.turns) turns"

        model.sessionText = "0 \(l10n.text(.missing)), 0 \(l10n.text(.orphan)), 0 \(l10n.text(.duplicate))"
        model.recentSessions = RunwayPreviewFixtures.recentSessions(now: now)

        let accounts = RunwayPreviewFixtures.managedAccounts(now: now)
        model.managedAccounts = accounts
        model.activeAccountId = accounts.first?.id
    }
}
