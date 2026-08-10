import CodexRunwayCore

struct StatusBarRenderPlan: Equatable {
    let meters: [QuotaMeter]
    let rowsPerColumn: Int

    var columns: [[QuotaMeter]] {
        stride(from: 0, to: meters.count, by: rowsPerColumn).map { start in
            Array(meters[start..<min(start + rowsPerColumn, meters.count)])
        }
    }

    static func make(
        style: StatusBarDisplayStyle,
        batteryScope: StatusBarBatteryScope,
        meters: [QuotaMeter])
        -> StatusBarRenderPlan
    {
        let visibleMeters = switch style {
        case .battery:
            batteryMeters(scope: batteryScope, meters: meters)
        case .text, .countdown, .meters, .rings:
            meters
        }
        let rowsPerColumn = switch style {
        case .battery, .meters:
            visibleMeters.count > 1 ? 2 : 1
        case .text, .countdown, .rings:
            1
        }
        return StatusBarRenderPlan(meters: visibleMeters, rowsPerColumn: rowsPerColumn)
    }

    private static func batteryMeters(
        scope: StatusBarBatteryScope,
        meters: [QuotaMeter])
        -> [QuotaMeter]
    {
        guard scope != .both else { return meters }

        let standardMeters = meters.filter { $0.source == .standard }
        let modelSpecificMeters = meters.filter { $0.source == .modelSpecific }
        let expectedWindowMinutes = scope == .fiveHour ? 300 : 10_080
        let selectedStandard = standardMeters.first { $0.windowMinutes == expectedWindowMinutes }
            ?? standardMeters.first
        return selectedStandard.map { [$0] + modelSpecificMeters } ?? modelSpecificMeters
    }
}
