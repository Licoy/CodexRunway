import AppKit
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status bar quota layout")
struct StatusBarRenderPlanTests {
    @Test("weekly-only quota never reserves an empty second slot")
    func weeklyOnlyQuotaCompactsEveryStyle() {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)

        for style in StatusBarDisplayStyle.allCases {
            let plan = StatusBarRenderPlan.make(
                style: style,
                batteryScope: .both,
                meters: [weekly])

            #expect(plan.meters == [weekly])
            #expect(plan.columns == [[weekly]])
        }
    }
    @Test("battery scopes select standard windows by duration instead of array position")
    func batteryScopesUseWindowDuration() {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)

        let weeklyPlan = StatusBarRenderPlan.make(
            style: .battery,
            batteryScope: .weekly,
            meters: [weekly, modelSpecific])
        let fiveHourPlan = StatusBarRenderPlan.make(
            style: .battery,
            batteryScope: .fiveHour,
            meters: [weekly, modelSpecific])

        #expect(weeklyPlan.meters == [weekly, modelSpecific])
        #expect(fiveHourPlan.meters == [weekly, modelSpecific])
    }
    @Test("three visible quotas are grouped without dropping the model-specific window")
    func threeVisibleQuotasAreGrouped() {
        let fiveHour = meter(title: "5小时", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)
        let meters = [fiveHour, weekly, modelSpecific]

        for style in StatusBarDisplayStyle.allCases {
            let plan = StatusBarRenderPlan.make(
                style: style,
                batteryScope: .both,
                meters: meters)

            if style == .meters || style == .battery {
                #expect(plan.meters == meters)
                #expect(plan.columns == [[fiveHour, weekly], [modelSpecific]])
            } else {
                #expect(plan.meters == meters)
                #expect(plan.columns == [[fiveHour], [weekly], [modelSpecific]])
            }
        }

        let fiveHourBattery = StatusBarRenderPlan.make(
            style: .battery,
            batteryScope: .fiveHour,
            meters: meters)
        let weeklyBattery = StatusBarRenderPlan.make(
            style: .battery,
            batteryScope: .weekly,
            meters: meters)
        #expect(fiveHourBattery.meters == [fiveHour, modelSpecific])
        #expect(weeklyBattery.meters == [weekly, modelSpecific])
    }
    @Test("content view draws from the visible quota plan")
    @MainActor
    func contentViewUsesRenderPlan() {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)
        let view = StatusBarContentView(frame: .zero)
        let displayMinute = Int(Date().timeIntervalSince1970 / 60)

        view.update(StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: preferences(style: .meters),
                language: .simplifiedChinese),
            content: StatusBarContentState.Content(
                text: "6天",
                meters: [weekly, modelSpecific],
                displayMinute: displayMinute)))

        #expect(view.renderPlan.meters == [weekly, modelSpecific])
        #expect(view.renderPlan.columns == [[weekly, modelSpecific]])
    }
    @Test("countdown layouts redraw at minute boundaries")
    @MainActor
    func countdownLayoutsRedrawAtMinuteBoundaries() {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let displayMinute = Int(Date().timeIntervalSince1970 / 60)
        let view = StatusBarContentView(frame: .zero)
        let configuration = StatusBarContentState.Configuration(
            preferences: preferences(style: .countdown, batteryDetailStyle: .countdown),
            language: .simplifiedChinese)
        let state = { minute in
            StatusBarContentState(
                configuration: configuration,
                content: StatusBarContentState.Content(
                    text: "固定文案",
                    meters: [weekly],
                    displayMinute: minute))
        }

        let firstUpdate = view.update(state(displayMinute))
        let sameMinuteUpdate = view.update(state(displayMinute))
        let nextMinuteUpdate = view.update(state(displayMinute + 1))

        #expect(firstUpdate)
        #expect(!sameMinuteUpdate)
        #expect(nextMinuteUpdate)
    }
    @Test("single and trailing quota rows stay vertically centered inside the menu bar")
    func quotaRowsStayInsideMenuBarBounds() {
        let fiveHour = meter(title: "5小时", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)
        let displayMinute = Int(Date().timeIntervalSince1970 / 60)
        let configuration = StatusBarContentState.Configuration(
            preferences: preferences(style: .meters),
            language: .simplifiedChinese)

        for meters in [[weekly], [fiveHour, weekly, modelSpecific]] {
            let layout = StatusBarContentLayout(state: StatusBarContentState(
                configuration: configuration,
                content: StatusBarContentState.Content(
                    text: "",
                    meters: meters,
                    displayMinute: displayMinute)))
            let bounds = NSRect(x: 0, y: 0, width: layout.preferredWidth, height: 22)
            let columns = layout.renderPlan.columns
            let columnFrames = layout.columnFrames(
                widths: layout.meterColumnWidths,
                gap: 6,
                in: bounds)

            #expect(columnFrames.count == columns.count)
            #expect(columnFrames.allSatisfy { $0.minX >= bounds.minX && $0.maxX <= bounds.maxX })
            for (column, frame) in zip(columns, columnFrames) {
                let rows = layout.rowFrames(count: column.count, in: frame, height: 10)
                #expect(rows.count == column.count)
                #expect(rows.allSatisfy { $0.minY >= bounds.minY && $0.maxY <= bounds.maxY })
                if column.count == 1 {
                    #expect(rows[0].midY == bounds.midY)
                }
            }
        }
    }

    @Test("all status bar styles render weekly-only and model-specific layouts")
    @MainActor
    func allStylesRenderVariableQuotaCounts() throws {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let fiveHour = meter(title: "5小时", usedPercent: 20, windowMinutes: 300)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)

        for style in StatusBarDisplayStyle.allCases {
            let stylePreferences = preferences(style: style)
            let compact = try render(preferences: stylePreferences, meters: [weekly])
            let expanded = try render(
                preferences: stylePreferences,
                meters: [fiveHour, weekly, modelSpecific])

            #expect(compact.data.count > 100)
            #expect(expanded.data.count > 100)
            #expect(expanded.width > compact.width)
            try writeSnapshotIfRequested(compact.data, name: "\(style.rawValue)-weekly-only")
            try writeSnapshotIfRequested(expanded.data, name: "\(style.rawValue)-with-model-specific")
        }
    }

    @Test("text style displays the same percentages as quota rings")
    func textStyleUsesRingPercentages() {
        let fiveHour = meter(title: "5小时", usedPercent: 20, windowMinutes: 300)
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let configuration = StatusBarContentState.Configuration(
            preferences: preferences(style: .text),
            language: .simplifiedChinese)
        let displayMinute = Int(Date().timeIntervalSince1970 / 60)
        let layout = StatusBarContentLayout(state: StatusBarContentState(
            configuration: configuration,
            content: StatusBarContentState.Content(
                text: "6天23小时",
                meters: [fiveHour, weekly],
                displayMinute: displayMinute)))
        let noQuotaLayout = StatusBarContentLayout(state: StatusBarContentState(
            configuration: configuration,
            content: StatusBarContentState.Content(
                text: "6天23小时",
                meters: [],
                displayMinute: displayMinute)))

        #expect(layout.ringText(for: fiveHour) == "80")
        #expect(layout.textCaptions == ["80%", "89%"])
        #expect(noQuotaLayout.textCaptions == ["--"])
        #expect(layout.preferredWidth > noQuotaLayout.preferredWidth)
    }

    @Test("battery scopes and detail settings render variable quota counts")
    @MainActor
    func batterySettingsRenderVariableQuotaCounts() throws {
        let weekly = meter(title: "每周", usedPercent: 11, windowMinutes: 10_080)
        let fiveHour = meter(title: "5小时", usedPercent: 20, windowMinutes: 300)
        let modelSpecific = meter(
            title: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            windowMinutes: 10_080,
            source: .modelSpecific)

        for scope in StatusBarBatteryScope.allCases {
            for detailStyle in StatusBarBatteryDetailStyle.allCases {
                let batteryPreferences = preferences(
                    style: .battery,
                    batteryScope: scope,
                    batteryDetailStyle: detailStyle)
                let compact = try render(
                    preferences: batteryPreferences,
                    meters: [weekly])
                let expanded = try render(
                    preferences: batteryPreferences,
                    meters: [fiveHour, weekly, modelSpecific])
                #expect(compact.data.count > 100)
                #expect(expanded.data.count > 100)
                #expect(expanded.width > compact.width)
            }
        }
    }

    @MainActor
    private func render(
        preferences: RunwayPreferences,
        meters: [QuotaMeter]) throws
        -> (data: Data, width: CGFloat)
    {
        let view = StatusBarContentView(frame: .zero)
        view.appearance = NSAppearance(named: .darkAqua)
        let displayMinute = Int(Date().timeIntervalSince1970 / 60)
        view.update(StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: preferences,
                language: .simplifiedChinese),
            content: StatusBarContentState.Content(
                text: "6天23小时",
                meters: meters,
                displayMinute: displayMinute)))
        let width = ceil(view.preferredWidth)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 22)

        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (data, width)
    }

    private func preferences(
        style: StatusBarDisplayStyle,
        batteryScope: StatusBarBatteryScope = .both,
        batteryDetailStyle: StatusBarBatteryDetailStyle = .remainingPercent)
        -> RunwayPreferences
    {
        var preferences = RunwayPreferences()
        preferences.statusBarDisplayStyle = style
        preferences.statusBarMetersDetailStyle = .remainingPercent
        preferences.statusBarBatteryScope = batteryScope
        preferences.statusBarBatteryDetailStyle = batteryDetailStyle
        return preferences
    }

    private func writeSnapshotIfRequested(_ data: Data, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEX_RUNWAY_STATUS_BAR_SNAPSHOTS"] else {
            return
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
        try data.write(to: directoryURL.appendingPathComponent("\(name).png"))
    }

    private func meter(
        title: String,
        usedPercent: Int,
        windowMinutes: Int,
        source: QuotaMeterSource = .standard)
        -> QuotaMeter
    {
        let now = Date()
        return QuotaMeter(
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: now.addingTimeInterval(TimeInterval(windowMinutes * 60))),
            now: now,
            source: source)
    }
}
