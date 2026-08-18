import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

/// Guards the token-usage heatmap section against the locale layout leak: when the
/// localized header strings exceed the panel content width, the section used to lay
/// out at its ideal width, which pushed the heatmap grid (and the header controls)
/// outside the popover. Regression: https://github.com/Licoy/codex-runway (heatmap).
@Suite("Token usage heatmap locale layout")
struct TokenUsageHeatmapLayoutTests {
    /// Popover content width: 400 panel − 2×16 padding − 4 scroll trailing padding.
    private static let hostWidth: CGFloat = 368
    /// The grid is allowed a small overflow at year end (53 weeks × 5pt min cells =
    /// 369pt) — same for every language — but any language-dependent leak pushes it
    /// ≥ 26pt wider, which this bound still catches.
    private static let gridWidthTolerance: CGFloat = 8

    @MainActor
    @Test("heatmap grid stays inside the panel width for every language")
    func heatmapGridFitsPanelForEveryLanguage() throws {
        var gridWidths: [ResolvedLanguage: CGFloat] = [:]
        for language in ResolvedLanguage.allCases {
            let host = makeHost(language: language, chartStyle: .heatmap)
            guard hostAvailable(host) else { continue }
            let gridFrames = platformHostFrames(in: host, containing: "HeatmapGrid")
            #expect(!gridFrames.isEmpty, "heatmap grid rendered for \(language)")
            guard let grid = gridFrames.first else { continue }
            #expect(grid.minX >= -0.5, "grid left edge inside panel for \(language), got \(grid)")
            #expect(
                grid.maxX <= Self.hostWidth + Self.gridWidthTolerance,
                "grid right edge inside panel for \(language), got \(grid)")
            gridWidths[language] = grid.width
        }
        // The grid geometry must be language-independent (same cell math for all).
        if let reference = gridWidths.values.first {
            for (language, width) in gridWidths {
                #expect(
                    abs(width - reference) < 0.5,
                    "grid width must not depend on language, \(language) got \(width) vs \(reference)")
            }
        }
    }

    @Test("late-year grid metrics fill the available panel width")
    func lateYearGridMetricsFillWidth() {
        let metrics = HeatmapLayoutMetrics.make(width: 364, weekCount: 34)
        #expect(abs(metrics.gridWidth - 364) < 0.51)
        #expect(metrics.cellSize > HeatmapLayoutMetrics.minCellSize)
        #expect(metrics.cellSize <= HeatmapLayoutMetrics.maxCellSize)
    }

    @Test("early-year grid keeps the compact cell cap instead of inflating")
    func earlyYearGridKeepsCellCap() {
        let metrics = HeatmapLayoutMetrics.make(width: 364, weekCount: 5)
        #expect(metrics.cellSize == HeatmapLayoutMetrics.maxCellSize)
        #expect(metrics.gridWidth < 364)
    }

    @Test("year-end 53-week grid stays near the panel width")
    func yearEndGridStaysBounded() {
        let metrics = HeatmapLayoutMetrics.make(width: 364, weekCount: 53)
        #expect(metrics.cellSize == HeatmapLayoutMetrics.minCellSize)
        #expect(metrics.gridWidth <= 364 + Self.gridWidthTolerance)
    }

    @MainActor
    @Test("rendered late-year heatmap uses the panel width")
    func renderedLateYearHeatmapFillsPanel() throws {
        let now = date(2026, 8, 18)
        let host = makeHost(language: .simplifiedChinese, chartStyle: .heatmap, now: now)
        guard hostAvailable(host) else { return }
        let gridFrames = platformHostFrames(in: host, containing: "HeatmapGrid")
        #expect(!gridFrames.isEmpty)
        guard let grid = gridFrames.first else { return }
        #expect(grid.minX >= -0.5)
        #expect(grid.maxX <= Self.hostWidth + Self.gridWidthTolerance)
        #expect(
            grid.width >= Self.hostWidth - 12,
            "grid should fill the panel, got width \(grid.width) in \(Self.hostWidth)")

        let controls = platformHostFrames(in: host, containing: "PopUpButton")
        if let popup = controls.first {
            #expect(
                popup.maxX >= Self.hostWidth - 40,
                "style control should sit on the trailing edge, got \(popup)")
        }
    }

    @MainActor
    @Test("heatmap header controls stay visible for every language")
    func heatmapHeaderControlsStayInsidePanel() throws {
        for language in ResolvedLanguage.allCases {
            let host = makeHost(language: language, chartStyle: .heatmap)
            guard hostAvailable(host) else { continue }
            let controls = platformHostFrames(in: host, containing: "SegmentedControl")
                + platformHostFrames(in: host, containing: "PopUpButton")
            #expect(!controls.isEmpty, "header controls rendered for \(language)")
            for frame in controls {
                #expect(frame.minX >= -0.5, "control left edge inside panel for \(language), got \(frame)")
                #expect(
                    frame.maxX <= Self.hostWidth + 0.5,
                    "control right edge inside panel for \(language), got \(frame)")
            }
        }
    }

    @MainActor
    @Test("trend charts share the same bounded header (Russian line/bar)")
    func trendChartsStayInsidePanel() throws {
        for style in [TokenUsageChartStyle.line, .bar] {
            let host = makeHost(language: .russian, chartStyle: style)
            guard hostAvailable(host) else { continue }
            let trend = platformHostFrames(in: host, containing: "TrendPointer")
            #expect(!trend.isEmpty, "trend chart rendered for \(style)")
            for frame in trend {
                #expect(frame.minX >= -0.5, "trend left edge inside panel for \(style), got \(frame)")
                #expect(
                    frame.maxX <= Self.hostWidth + Self.gridWidthTolerance,
                    "trend right edge inside panel for \(style), got \(frame)")
            }
        }
    }

    // MARK: - Harness

    @MainActor
    private func makeHost(
        language: ResolvedLanguage,
        chartStyle: TokenUsageChartStyle,
        now: Date = Date()
    ) -> NSHostingView<AnyView> {
        let heatmap = Self.mockTokens(now: now)
        let view = TokenUsageHeatmapView(
            allDevicesTokens: heatmap.mapValues { $0 * 2 },
            localTokens: heatmap,
            calculatedAt: now,
            officialStatsAsOf: Self.dayKey(now),
            officialGeneratedAt: now,
            chartStyle: .constant(chartStyle),
            l10n: L10n(language: language),
            isRefreshing: false,
            onRefresh: {})
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: Self.hostWidth, height: 300)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func hostAvailable(_ host: NSHostingView<AnyView>) -> Bool {
        let fitting = host.fittingSize
        return fitting.width > 1 && fitting.height > 1
    }

    /// SwiftUI hosts AppKit representables inside a platform host view whose frame
    /// is the SwiftUI-proposed frame; inner NSViews are laid out at (0, 0).
    @MainActor
    private func platformHostFrames(in view: NSView, containing token: String) -> [CGRect] {
        var result: [CGRect] = []
        let name = String(describing: type(of: view))
        if name.contains("PlatformViewHost"), name.contains(token) {
            result.append(view.frame)
        }
        for child in view.subviews {
            result.append(contentsOf: platformHostFrames(in: child, containing: token))
        }
        return result
    }

    /// Synthetic year-to-date daily token buckets (UTC day keys) so the grid has data.
    private static func mockTokens(now: Date) -> [String: Int] {
        var heatmap: [String: Int] = [:]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = utc.component(.year, from: now)
        guard let start = utc.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return heatmap
        }
        var cursor = start
        let today = utc.startOfDay(for: now)
        var index = 0
        while cursor <= today {
            let key = Self.dayKey(cursor, calendar: utc)
            if index % 3 != 0 {
                heatmap[key] = (index % 7 + 1) * 12_000 + (index % 5) * 1_500
            }
            guard let next = utc.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            index += 1
        }
        return heatmap
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func dayKey(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }
}
