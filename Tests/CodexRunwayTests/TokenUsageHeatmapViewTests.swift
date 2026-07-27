import CoreGraphics
import Testing
@testable import CodexRunway

@Suite("Token usage heatmap tooltip")
struct TokenUsageHeatmapViewTests {
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
}
