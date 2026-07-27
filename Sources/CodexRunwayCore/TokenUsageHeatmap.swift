import Foundation

public enum TokenUsageHeatmapMode: String, CaseIterable, Codable, Sendable, Hashable {
    case daily
    case weekly
    case cumulative
}

public struct TokenUsageChartPoint: Identifiable, Sendable, Equatable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    /// Mode metric used for chart height (daily / weekly total / cumulative of primary series).
    public var tokens: Int
    /// Tooltip: that calendar day's workspace total (all devices). For weekly points this is the week total.
    public var allDevicesTokens: Int
    /// Tooltip: that calendar day's local total. For weekly points this is the week total.
    public var localTokens: Int

    public init(
        dayKey: String,
        date: Date,
        tokens: Int,
        allDevicesTokens: Int = 0,
        localTokens: Int = 0)
    {
        self.dayKey = dayKey
        self.date = date
        self.tokens = tokens
        self.allDevicesTokens = allDevicesTokens
        self.localTokens = localTokens
    }
}

public struct TokenUsageChartSeries: Sendable, Equatable {
    public var mode: TokenUsageHeatmapMode
    public var points: [TokenUsageChartPoint]
    public var totalTokens: Int
    public var totalAllDevicesTokens: Int
    public var totalLocalTokens: Int
    public var hasAllDevicesData: Bool
    public var hasLocalData: Bool
    public var calculatedAt: Date
    public var hasUsage: Bool

    public init(
        mode: TokenUsageHeatmapMode,
        points: [TokenUsageChartPoint],
        totalTokens: Int,
        totalAllDevicesTokens: Int = 0,
        totalLocalTokens: Int = 0,
        hasAllDevicesData: Bool = false,
        hasLocalData: Bool = false,
        calculatedAt: Date,
        hasUsage: Bool)
    {
        self.mode = mode
        self.points = points
        self.totalTokens = totalTokens
        self.totalAllDevicesTokens = totalAllDevicesTokens
        self.totalLocalTokens = totalLocalTokens
        self.hasAllDevicesData = hasAllDevicesData
        self.hasLocalData = hasLocalData
        self.calculatedAt = calculatedAt
        self.hasUsage = hasUsage
    }
}

public struct TokenUsageHeatmapCell: Identifiable, Sendable, Equatable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    /// Mode metric used for intensity (daily / weekly / cumulative of primary series).
    public var tokens: Int
    /// Always that calendar day's workspace total (all devices) — for tooltips.
    public var allDevicesTokens: Int
    /// Always that calendar day's local total — for tooltips.
    public var localTokens: Int
    public var level: Int
    public var isInRange: Bool

    public init(
        dayKey: String,
        date: Date,
        tokens: Int,
        allDevicesTokens: Int = 0,
        localTokens: Int = 0,
        level: Int,
        isInRange: Bool)
    {
        self.dayKey = dayKey
        self.date = date
        self.tokens = tokens
        self.allDevicesTokens = allDevicesTokens
        self.localTokens = localTokens
        self.level = level
        self.isInRange = isInRange
    }
}

public struct TokenUsageHeatmapMonthLabel: Sendable, Equatable {
    public var weekIndex: Int
    public var month: Int

    public init(weekIndex: Int, month: Int) {
        self.weekIndex = weekIndex
        self.month = month
    }
}

public struct TokenUsageHeatmapSnapshot: Sendable, Equatable {
    public var mode: TokenUsageHeatmapMode
    /// Columns are weeks; each week has 7 weekday cells (calendar firstWeekday order).
    public var weeks: [[TokenUsageHeatmapCell]]
    public var monthLabels: [TokenUsageHeatmapMonthLabel]
    public var totalTokens: Int
    public var totalAllDevicesTokens: Int
    public var totalLocalTokens: Int
    public var hasAllDevicesData: Bool
    public var hasLocalData: Bool
    public var calculatedAt: Date
    public var hasUsage: Bool

    public init(
        mode: TokenUsageHeatmapMode,
        weeks: [[TokenUsageHeatmapCell]],
        monthLabels: [TokenUsageHeatmapMonthLabel],
        totalTokens: Int,
        totalAllDevicesTokens: Int = 0,
        totalLocalTokens: Int = 0,
        hasAllDevicesData: Bool = false,
        hasLocalData: Bool = false,
        calculatedAt: Date,
        hasUsage: Bool)
    {
        self.mode = mode
        self.weeks = weeks
        self.monthLabels = monthLabels
        self.totalTokens = totalTokens
        self.totalAllDevicesTokens = totalAllDevicesTokens
        self.totalLocalTokens = totalLocalTokens
        self.hasAllDevicesData = hasAllDevicesData
        self.hasLocalData = hasLocalData
        self.calculatedAt = calculatedAt
        self.hasUsage = hasUsage
    }
}

public enum TokenUsageHeatmapBuilder {
    /// Builds a year-to-date contribution-style grid.
    /// - Parameter allDevicesTokens: Current-account official profile statistics.
    /// - Parameter localTokens: All session logs indexed on this Mac.
    /// Intensity prefers the official all-devices series when it has any usage.
    public static func make(
        allDevicesTokens: [String: Int],
        localTokens: [String: Int],
        mode: TokenUsageHeatmapMode,
        now: Date = Date(),
        firstWeekday: Int = Calendar.current.firstWeekday
    ) -> TokenUsageHeatmapSnapshot {
        // Local calendar so day keys align with the product's profile activity dates.
        let calendar = displayCalendar(firstWeekday: firstWeekday)
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return emptySnapshot(mode: mode, calculatedAt: now)
        }

        let gridStart = startOfWeek(containing: yearStart, calendar: calendar)
        let gridEnd = endOfWeek(containing: today, calendar: calendar)
        let dayKeys = orderedDayKeys(from: yearStart, through: today, calendar: calendar)
        // Keep both day-level sources intact for tooltips; they are not a subset relationship.
        let allDaily = clippedDaily(dayKeys: dayKeys, source: allDevicesTokens)
        let localDaily = clippedDaily(dayKeys: dayKeys, source: localTokens)
        let totalAll = allDaily.values.reduce(0, +)
        let totalLocal = localDaily.values.reduce(0, +)
        let hasAllDevicesData = totalAll > 0
        let hasLocalData = totalLocal > 0

        // Mode metrics only affect cell intensity, not the per-day tooltip amounts.
        let allMetric = metricSeries(
            mode: mode,
            dayKeys: dayKeys,
            daily: allDaily,
            yearStart: yearStart,
            today: today,
            calendar: calendar)
        let localMetric = metricSeries(
            mode: mode,
            dayKeys: dayKeys,
            daily: localDaily,
            yearStart: yearStart,
            today: today,
            calendar: calendar)
        // Prefer official profile activity for color intensity; otherwise use local only.
        let primaryMetric = hasAllDevicesData ? allMetric : localMetric
        let levels = intensityLevels(for: primaryMetric)
        let totalTokens = hasAllDevicesData ? totalAll : totalLocal

        var weeks: [[TokenUsageHeatmapCell]] = []
        var monthLabels: [TokenUsageHeatmapMonthLabel] = []
        var cursor = gridStart
        var weekIndex = 0
        var lastLabeledMonth: Int?

        while cursor <= gridEnd {
            var column: [TokenUsageHeatmapCell] = []
            var columnMonth: Int?
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: cursor) else { continue }
                let dayKey = dayString(date, calendar: calendar)
                let isInRange = date >= yearStart && date <= today
                let allDay = isInRange ? (allDaily[dayKey] ?? 0) : 0
                let localDay = isInRange ? (localDaily[dayKey] ?? 0) : 0
                let primary = isInRange ? (primaryMetric[dayKey] ?? 0) : 0
                let level = isInRange ? (levels[dayKey] ?? 0) : 0
                column.append(TokenUsageHeatmapCell(
                    dayKey: dayKey,
                    date: date,
                    tokens: primary,
                    allDevicesTokens: allDay,
                    localTokens: localDay,
                    level: level,
                    isInRange: isInRange))
                if isInRange, columnMonth == nil {
                    columnMonth = calendar.component(.month, from: date)
                }
            }
            weeks.append(column)
            if let month = columnMonth, month != lastLabeledMonth {
                monthLabels.append(TokenUsageHeatmapMonthLabel(weekIndex: weekIndex, month: month))
                lastLabeledMonth = month
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
            weekIndex += 1
        }

        return TokenUsageHeatmapSnapshot(
            mode: mode,
            weeks: weeks,
            monthLabels: monthLabels,
            totalTokens: totalTokens,
            totalAllDevicesTokens: totalAll,
            totalLocalTokens: totalLocal,
            hasAllDevicesData: hasAllDevicesData,
            hasLocalData: hasLocalData,
            calculatedAt: now,
            hasUsage: totalAll > 0 || totalLocal > 0)
    }

    /// Max daily points shown on line / bar charts (rolling window ending today).
    public static let chartDailyWindowDays = 30

    /// Ordered points for line / bar charts.
    /// - daily: last up to 30 days
    /// - weekly: one point per week from year start through today
    /// - cumulative: one point per month from January through the current month
    public static func makeSeries(
        allDevicesTokens: [String: Int],
        localTokens: [String: Int],
        mode: TokenUsageHeatmapMode,
        now: Date = Date(),
        firstWeekday: Int = Calendar.current.firstWeekday
    ) -> TokenUsageChartSeries {
        let calendar = displayCalendar(firstWeekday: firstWeekday)
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return emptySeries(mode: mode, calculatedAt: now)
        }

        // Always index the full YTD so weekly / monthly aggregates stay complete.
        let yearDayKeys = orderedDayKeys(from: yearStart, through: today, calendar: calendar)
        let allDaily = clippedDaily(dayKeys: yearDayKeys, source: allDevicesTokens)
        let localDaily = clippedDaily(dayKeys: yearDayKeys, source: localTokens)
        let totalAll = allDaily.values.reduce(0, +)
        let totalLocal = localDaily.values.reduce(0, +)
        let hasAllDevicesData = totalAll > 0
        let hasLocalData = totalLocal > 0
        let totalTokens = hasAllDevicesData ? totalAll : totalLocal

        let primaryDaily = hasAllDevicesData ? allDaily : localDaily
        let points: [TokenUsageChartPoint]
        switch mode {
        case .daily:
            let windowStart = calendar.date(byAdding: .day, value: -(chartDailyWindowDays - 1), to: today) ?? today
            let seriesStart = max(yearStart, calendar.startOfDay(for: windowStart))
            let dayKeys = orderedDayKeys(from: seriesStart, through: today, calendar: calendar)
            points = dayKeys.compactMap { key in
                guard let date = date(fromDayKey: key, calendar: calendar) else { return nil }
                return TokenUsageChartPoint(
                    dayKey: key,
                    date: date,
                    tokens: primaryDaily[key] ?? 0,
                    allDevicesTokens: allDaily[key] ?? 0,
                    localTokens: localDaily[key] ?? 0)
            }
        case .weekly:
            points = weeklyChartPoints(
                from: yearStart,
                through: today,
                allDaily: allDaily,
                localDaily: localDaily,
                primaryDaily: primaryDaily,
                calendar: calendar)
        case .cumulative:
            // Line / bar "month" aggregation reuses the third segment control slot.
            points = monthlyChartPoints(
                from: yearStart,
                through: today,
                allDaily: allDaily,
                localDaily: localDaily,
                primaryDaily: primaryDaily,
                calendar: calendar)
        }

        return TokenUsageChartSeries(
            mode: mode,
            points: points,
            totalTokens: totalTokens,
            totalAllDevicesTokens: totalAll,
            totalLocalTokens: totalLocal,
            hasAllDevicesData: hasAllDevicesData,
            hasLocalData: hasLocalData,
            calculatedAt: now,
            hasUsage: totalAll > 0 || totalLocal > 0)
    }

    /// Single-series convenience (tests / callers with one map).
    public static func make(
        dailyTokens: [String: Int],
        mode: TokenUsageHeatmapMode,
        now: Date = Date(),
        firstWeekday: Int = Calendar.current.firstWeekday
    ) -> TokenUsageHeatmapSnapshot {
        make(
            allDevicesTokens: [:],
            localTokens: dailyTokens,
            mode: mode,
            now: now,
            firstWeekday: firstWeekday)
    }

    /// Single-series convenience for chart points.
    public static func makeSeries(
        dailyTokens: [String: Int],
        mode: TokenUsageHeatmapMode,
        now: Date = Date(),
        firstWeekday: Int = Calendar.current.firstWeekday
    ) -> TokenUsageChartSeries {
        makeSeries(
            allDevicesTokens: [:],
            localTokens: dailyTokens,
            mode: mode,
            now: now,
            firstWeekday: firstWeekday)
    }

    public static func make(
        dailyRows: [ApiEquivalentDailyRow],
        mode: TokenUsageHeatmapMode,
        now: Date = Date(),
        firstWeekday: Int = Calendar.current.firstWeekday
    ) -> TokenUsageHeatmapSnapshot {
        let map = Dictionary(uniqueKeysWithValues: dailyRows.map { ($0.date, max(0, $0.totals.totalTokens)) })
        return make(
            dailyTokens: map,
            mode: mode,
            now: now,
            firstWeekday: firstWeekday)
    }

    private static func clippedDaily(dayKeys: [String], source: [String: Int]) -> [String: Int] {
        dayKeys.reduce(into: [String: Int]()) { result, key in
            result[key] = max(0, source[key] ?? 0)
        }
    }

    private static func metricSeries(
        mode: TokenUsageHeatmapMode,
        dayKeys: [String],
        daily: [String: Int],
        yearStart: Date,
        today: Date,
        calendar: Calendar
    ) -> [String: Int] {
        switch mode {
        case .daily:
            return daily
        case .weekly:
            return weeklyTotalsByDayKey(
                from: yearStart,
                through: today,
                daily: daily,
                calendar: calendar)
        case .cumulative:
            return cumulativeTotals(dayKeys: dayKeys, daily: daily)
        }
    }

    public static func yearToDateWindow(
        now: Date = Date(),
        calendar: Calendar? = nil
    ) -> DateInterval {
        // Prefer the caller's calendar; default to local so profile activity day keys align.
        let cal = calendar ?? displayCalendar(firstWeekday: Calendar.current.firstWeekday)
        let today = cal.startOfDay(for: now)
        let year = cal.component(.year, from: today)
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
        let endExclusive = cal.date(byAdding: .day, value: 1, to: today) ?? now
        return DateInterval(start: start, end: endExclusive)
    }

    /// Locale-aware compact token count: 中文用「万 / 亿」, English uses K / M / B.
    public static func compactTokenCount(
        _ value: Int,
        language: ResolvedLanguage = .english
    ) -> String {
        let amount = max(0, value)
        if language == .simplifiedChinese {
            return compactTokenCountChinese(amount)
        }
        return compactTokenCountEnglish(amount)
    }

    private static func compactTokenCountChinese(_ value: Int) -> String {
        // 1 亿 = 100_000_000, 1 万 = 10_000
        if value >= 100_000_000 {
            return trimTrailingZeros(String(format: "%.2f", Double(value) / 100_000_000)) + "亿"
        }
        if value >= 10_000 {
            return trimTrailingZeros(String(format: "%.2f", Double(value) / 10_000)) + "万"
        }
        return "\(value)"
    }

    private static func compactTokenCountEnglish(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return trimTrailingZeros(String(format: "%.2f", Double(value) / 1_000_000_000)) + "B"
        }
        if value >= 1_000_000 {
            return trimTrailingZeros(String(format: "%.2f", Double(value) / 1_000_000)) + "M"
        }
        if value >= 1_000 {
            return trimTrailingZeros(String(format: "%.2f", Double(value) / 1_000)) + "K"
        }
        return "\(value)"
    }

    private static func trimTrailingZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." {
            result.removeLast()
        }
        return result
    }

    // MARK: - Internals

    private static func emptySnapshot(mode: TokenUsageHeatmapMode, calculatedAt: Date) -> TokenUsageHeatmapSnapshot {
        TokenUsageHeatmapSnapshot(
            mode: mode,
            weeks: [],
            monthLabels: [],
            totalTokens: 0,
            totalAllDevicesTokens: 0,
            totalLocalTokens: 0,
            hasAllDevicesData: false,
            hasLocalData: false,
            calculatedAt: calculatedAt,
            hasUsage: false)
    }

    private static func emptySeries(mode: TokenUsageHeatmapMode, calculatedAt: Date) -> TokenUsageChartSeries {
        TokenUsageChartSeries(
            mode: mode,
            points: [],
            totalTokens: 0,
            totalAllDevicesTokens: 0,
            totalLocalTokens: 0,
            hasAllDevicesData: false,
            hasLocalData: false,
            calculatedAt: calculatedAt,
            hasUsage: false)
    }

    private static func weeklyChartPoints(
        from start: Date,
        through end: Date,
        allDaily: [String: Int],
        localDaily: [String: Int],
        primaryDaily: [String: Int],
        calendar: Calendar
    ) -> [TokenUsageChartPoint] {
        var points: [TokenUsageChartPoint] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            let weekStart = startOfWeek(containing: cursor, calendar: calendar)
            var primaryTotal = 0
            var allTotal = 0
            var localTotal = 0
            var lastInRangeDay = weekStart
            var day = weekStart
            for _ in 0..<7 {
                if day >= start, day <= last {
                    let key = dayString(day, calendar: calendar)
                    primaryTotal += primaryDaily[key] ?? 0
                    allTotal += allDaily[key] ?? 0
                    localTotal += localDaily[key] ?? 0
                    lastInRangeDay = day
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            let key = dayString(lastInRangeDay, calendar: calendar)
            points.append(TokenUsageChartPoint(
                dayKey: key,
                date: lastInRangeDay,
                tokens: primaryTotal,
                allDevicesTokens: allTotal,
                localTokens: localTotal))
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            cursor = nextWeek
        }
        return points
    }

    private static func monthlyChartPoints(
        from start: Date,
        through end: Date,
        allDaily: [String: Int],
        localDaily: [String: Int],
        primaryDaily: [String: Int],
        calendar: Calendar
    ) -> [TokenUsageChartPoint] {
        var points: [TokenUsageChartPoint] = []
        let last = calendar.startOfDay(for: end)
        guard var cursor = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: start),
            month: calendar.component(.month, from: start),
            day: 1))
        else { return points }

        while cursor <= last {
            let month = calendar.component(.month, from: cursor)
            let year = calendar.component(.year, from: cursor)
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { break }
            let monthEndExclusive = nextMonth
            let rangeEnd = min(last, calendar.date(byAdding: .day, value: -1, to: monthEndExclusive) ?? last)

            var primaryTotal = 0
            var allTotal = 0
            var localTotal = 0
            var day = monthStart
            while day <= rangeEnd {
                if day >= start {
                    let key = dayString(day, calendar: calendar)
                    primaryTotal += primaryDaily[key] ?? 0
                    allTotal += allDaily[key] ?? 0
                    localTotal += localDaily[key] ?? 0
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }

            let pointDate = rangeEnd
            points.append(TokenUsageChartPoint(
                dayKey: dayString(pointDate, calendar: calendar),
                date: pointDate,
                tokens: primaryTotal,
                allDevicesTokens: allTotal,
                localTokens: localTotal))
            cursor = nextMonth
        }
        return points
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func displayCalendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = min(7, max(1, firstWeekday))
        return calendar
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: day) ?? day
    }

    private static func endOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let start = startOfWeek(containing: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 6, to: start) ?? date
    }

    private static func orderedDayKeys(from start: Date, through end: Date, calendar: Calendar) -> [String] {
        var keys: [String] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            keys.append(dayString(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    private static func weeklyTotalsByDayKey(
        from start: Date,
        through end: Date,
        daily: [String: Int],
        calendar: Calendar
    ) -> [String: Int] {
        // Single left-to-right pass: accumulate week totals, then stamp each in-range day.
        var result: [String: Int] = [:]
        result.reserveCapacity(daily.count)
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            let weekStart = startOfWeek(containing: cursor, calendar: calendar)
            var weekTotal = 0
            var daysInWeek: [String] = []
            daysInWeek.reserveCapacity(7)
            var day = weekStart
            for _ in 0..<7 {
                if day >= start, day <= last {
                    let key = dayString(day, calendar: calendar)
                    daysInWeek.append(key)
                    weekTotal += daily[key] ?? 0
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            for key in daysInWeek {
                result[key] = weekTotal
            }
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            cursor = nextWeek
        }
        return result
    }

    private static func cumulativeTotals(dayKeys: [String], daily: [String: Int]) -> [String: Int] {
        var running = 0
        var result: [String: Int] = [:]
        result.reserveCapacity(dayKeys.count)
        for key in dayKeys {
            running += daily[key] ?? 0
            result[key] = running
        }
        return result
    }

    /// Map positive values into levels 1...4; zeros stay 0.
    private static func intensityLevels(for metrics: [String: Int]) -> [String: Int] {
        let positives = metrics.values.filter { $0 > 0 }.sorted()
        guard let maxValue = positives.last, maxValue > 0 else {
            return metrics.mapValues { _ in 0 }
        }
        // Quartile thresholds among positive samples (stable for sparse data).
        let q1 = percentile(positives, 0.25)
        let q2 = percentile(positives, 0.50)
        let q3 = percentile(positives, 0.75)
        return metrics.mapValues { value in
            guard value > 0 else { return 0 }
            if value <= q1 { return 1 }
            if value <= q2 { return 2 }
            if value <= q3 { return 3 }
            return 4
        }
    }

    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[rank]
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        // Lightweight calendar day key matching the local session index.
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
