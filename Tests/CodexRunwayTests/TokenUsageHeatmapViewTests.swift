import CoreGraphics
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Token usage heatmap tooltip")
struct TokenUsageHeatmapViewTests {
    @Test("tooltip preserves source values and explains an inverted comparison")
    func tooltipExplainsDifferentSourceScopes() {
        let l10n = L10n(language: .simplifiedChinese)
        let content = TokenUsageTooltipContent.make(
            date: "2026年7月25日",
            officialTokens: 998_000_000,
            localTokens: 1_611_000_000,
            l10n: l10n)

        #expect(content.primary == "官方统计（多端） 9.98亿 Tokens")
        #expect(content.secondary == "本机日志（全部本机会话） 16.11亿 Tokens")
        #expect(content.note == "数据源口径不同，不能作为包含关系比较")

        let ordinary = TokenUsageTooltipContent.make(
            date: "Jul 25, 2026",
            officialTokens: 1_611_000_000,
            localTokens: 998_000_000,
            l10n: L10n(language: .english))
        #expect(ordinary.primary == "Official stats (all devices) 1.61B Tokens")
        #expect(ordinary.secondary == "Local logs (all sessions) 998M Tokens")
        #expect(ordinary.note == nil)
    }

    @Test("Grok local-only tooltips omit official multi-device stats")
    func localOnlyTooltipOmitsOfficialStats() {
        let content = TokenUsageTooltipContent.make(
            date: "2026年7月26日",
            officialTokens: 0,
            localTokens: 3_455_780_000,
            l10n: L10n(language: .simplifiedChinese),
            showsOfficialStats: false)

        #expect(content.primary == "本机 34.56亿 Tokens")
        #expect(content.secondary == nil)
        #expect(content.note == nil)

        let size = TokenUsageTooltipLayout.size(
            for: content,
            cellRect: CGRect(x: 100, y: 20, width: 8, height: 8),
            containerSize: CGSize(width: 360, height: 100))
        #expect(size.height == 44)
    }

    @Test("official source caption exposes the backend statistics date")
    func officialSourceCaptionUsesStatsDate() {
        #expect(TokenUsageSourcePresentation.asOfText(
            statsAsOf: "2026-07-27",
            generatedAt: nil,
            l10n: L10n(language: .simplifiedChinese)) == "官方截至 2026-07-27")
        #expect(TokenUsageSourcePresentation.asOfText(
            statsAsOf: nil,
            generatedAt: Date(timeIntervalSince1970: 1_785_139_420),
            l10n: L10n(language: .english)) == "Official through 2026-07-27")
    }

    @Test("tooltip stays beside cells near either horizontal edge")
    func horizontalPlacementAvoidsHoveredCell() {
        let container = CGSize(width: 720, height: 89)
        let tooltip = CGSize(width: 220, height: 60)
        let firstCell = CGRect(x: 0, y: 26, width: 11, height: 11)
        let lastCell = CGRect(x: 709, y: 26, width: 11, height: 11)

        let firstOrigin = HeatmapTooltipPlacement.origin(
            cellRect: firstCell,
            tooltipSize: tooltip,
            containerSize: container)
        let lastOrigin = HeatmapTooltipPlacement.origin(
            cellRect: lastCell,
            tooltipSize: tooltip,
            containerSize: container)

        #expect(!CGRect(origin: firstOrigin, size: tooltip).intersects(firstCell))
        #expect(!CGRect(origin: lastOrigin, size: tooltip).intersects(lastCell))
        #expect(firstOrigin.x > firstCell.maxX)
        #expect(lastOrigin.x + tooltip.width < lastCell.minX)
    }

    @Test("narrow grids move tooltip below or above the hovered row")
    func verticalPlacementAvoidsHoveredCell() {
        let container = CGSize(width: 180, height: 89)
        let tooltip = CGSize(width: 180, height: 60)
        let topCell = CGRect(x: 84, y: 0, width: 11, height: 11)
        let bottomCell = CGRect(x: 84, y: 78, width: 11, height: 11)

        let topOrigin = HeatmapTooltipPlacement.origin(
            cellRect: topCell,
            tooltipSize: tooltip,
            containerSize: container)
        let bottomOrigin = HeatmapTooltipPlacement.origin(
            cellRect: bottomCell,
            tooltipSize: tooltip,
            containerSize: container)

        #expect(!CGRect(origin: topOrigin, size: tooltip).intersects(topCell))
        #expect(!CGRect(origin: bottomOrigin, size: tooltip).intersects(bottomCell))
        #expect(topOrigin.y > topCell.maxY)
        #expect(bottomOrigin.y + tooltip.height < bottomCell.minY)
    }

    @Test("mismatch tooltip stays inside a real year-end heatmap frame")
    func mismatchTooltipFitsRealHeatmapFrame() {
        let container = CGSize(width: 369, height: 109)
        let middleCell = CGRect(x: 182, y: 21, width: 5, height: 5)
        let content = TokenUsageTooltipContent.make(
            date: "2026年12月25日",
            officialTokens: 998_000_000,
            localTokens: 1_611_000_000,
            l10n: L10n(language: .simplifiedChinese))
        let tooltip = TokenUsageTooltipLayout.size(
            for: content,
            cellRect: middleCell,
            containerSize: container)
        let origin = HeatmapTooltipPlacement.origin(
            cellRect: middleCell,
            tooltipSize: tooltip,
            containerSize: container)
        let frame = CGRect(origin: origin, size: tooltip)

        #expect(tooltip.height == 80)
        #expect(frame.minX >= 0 && frame.maxX <= container.width)
        #expect(frame.minY >= 0 && frame.maxY <= container.height)
        #expect(!frame.intersects(middleCell))
    }

    @Test("bilingual trend mismatch tooltips avoid a centered line or bar point")
    func bilingualTrendMismatchTooltipsFit() {
        let container = CGSize(width: 368, height: 98)
        let middlePoint = CGRect(x: 180, y: 35, width: 8, height: 8)
        let contents = [
            TokenUsageTooltipContent.make(
                date: "Dec 25, 2026",
                officialTokens: 998_000_000,
                localTokens: 1_611_000_000,
                l10n: L10n(language: .english)),
            TokenUsageTooltipContent.make(
                date: "2026年12月25日",
                officialTokens: 998_000_000,
                localTokens: 1_611_000_000,
                l10n: L10n(language: .simplifiedChinese)),
        ]

        for content in contents {
            let tooltip = TokenUsageTooltipLayout.size(
                for: content,
                cellRect: middlePoint,
                containerSize: container)
            let origin = HeatmapTooltipPlacement.origin(
                cellRect: middlePoint,
                tooltipSize: tooltip,
                containerSize: container)
            let frame = CGRect(origin: origin, size: tooltip)

            #expect(frame.minX >= 0 && frame.maxX <= container.width)
            #expect(frame.minY >= 0 && frame.maxY <= container.height)
            #expect(!frame.intersects(middlePoint))
        }
    }
}
