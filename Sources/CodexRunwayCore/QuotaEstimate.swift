import Foundation

public enum QuotaEstimateWindowMode: String, CaseIterable, Codable, Sendable, Hashable {
    /// JS “auto”: official cycle of weekly, else secondary, else 5-hour, else primary.
    case auto
    case rollingWeek

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? Self.auto.rawValue
        switch raw {
        case Self.rollingWeek.rawValue:
            self = .rollingWeek
        default:
            self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum QuotaEstimatePricing {
    /// Unofficial ChatGPT credit conversion (1000 Credits ≈ $40). Not an official price list.
    public static let usdPerCredit: Double = 0.04
    public static let version = "credits-usd-2026-08-26"
    public static let significantChangePercent: Double = 10
    public static let maxHistorySamples = 12
    public static let analyticsLookbackDays = 30
}

public enum QuotaEstimateChangeKind: String, Sendable, Equatable {
    case decreased
    case increased
    case similar
}

public struct QuotaEstimateDailyRow: Sendable, Equatable, Identifiable {
    public var id: String { date }
    public var date: String
    public var credits: Double
    public var tokens: Int
    public var turns: Int
    public var usd: Double

    public init(date: String, credits: Double, tokens: Int, turns: Int, usd: Double) {
        self.date = date
        self.credits = credits
        self.tokens = tokens
        self.turns = turns
        self.usd = usd
    }

    public static func usd(forCredits credits: Double) -> Double {
        credits * QuotaEstimatePricing.usdPerCredit
    }
}

public struct QuotaEstimateHistorySample: Codable, Sendable, Equatable {
    public var cycleStartDate: String
    public var estimatedCredits: Double
    public var usedPercent: Double
    public var usedCredits: Double
    public var recordedAt: Date

    public init(
        cycleStartDate: String,
        estimatedCredits: Double,
        usedPercent: Double,
        usedCredits: Double,
        recordedAt: Date)
    {
        self.cycleStartDate = cycleStartDate
        self.estimatedCredits = estimatedCredits
        self.usedPercent = usedPercent
        self.usedCredits = usedCredits
        self.recordedAt = recordedAt
    }
}

public struct QuotaEstimateSnapshot: Sendable, Equatable {
    public var windowMode: QuotaEstimateWindowMode
    public var cycleStartDate: String
    public var usedPercent: Double
    public var usedCredits: Double
    public var usedUSD: Double
    public var dayCount: Int
    public var estimatedCredits: Double?
    public var estimatedUSD: Double?
    public var canExtrapolate: Bool
    public var hasWeeklyWindow: Bool
    public var currentRows: [QuotaEstimateDailyRow]
    public var previousEstimate: QuotaEstimateHistorySample?
    public var changePercent: Double?
    public var changeKind: QuotaEstimateChangeKind?
    public var history: [QuotaEstimateHistorySample]
    public var calculatedAt: Date

    public init(
        windowMode: QuotaEstimateWindowMode,
        cycleStartDate: String,
        usedPercent: Double,
        usedCredits: Double,
        usedUSD: Double,
        dayCount: Int,
        estimatedCredits: Double?,
        estimatedUSD: Double?,
        canExtrapolate: Bool,
        hasWeeklyWindow: Bool,
        currentRows: [QuotaEstimateDailyRow],
        previousEstimate: QuotaEstimateHistorySample?,
        changePercent: Double?,
        changeKind: QuotaEstimateChangeKind?,
        history: [QuotaEstimateHistorySample],
        calculatedAt: Date)
    {
        self.windowMode = windowMode
        self.cycleStartDate = cycleStartDate
        self.usedPercent = usedPercent
        self.usedCredits = usedCredits
        self.usedUSD = usedUSD
        self.dayCount = dayCount
        self.estimatedCredits = estimatedCredits
        self.estimatedUSD = estimatedUSD
        self.canExtrapolate = canExtrapolate
        self.hasWeeklyWindow = hasWeeklyWindow
        self.currentRows = currentRows
        self.previousEstimate = previousEstimate
        self.changePercent = changePercent
        self.changeKind = changeKind
        self.history = history
        self.calculatedAt = calculatedAt
    }
}

public enum QuotaEstimateCalculator {
    public static func weeklyWindow(from quota: QuotaSnapshot) -> RateWindow? {
        if let secondary = quota.secondary, isWeekly(secondary) {
            return secondary
        }
        if isWeekly(quota.primary) {
            return quota.primary
        }
        return nil
    }

    public static func isWeekly(_ window: RateWindow) -> Bool {
        guard let minutes = window.windowMinutes, minutes > 0 else { return false }
        return minutes >= 6 * 24 * 60
    }

    public static func isFiveHour(_ window: RateWindow) -> Bool {
        guard let minutes = window.windowMinutes, minutes > 0 else { return false }
        return minutes <= 12 * 60
    }

    /// Same meter order as the reference script’s auto mode.
    public static func autoMeter(from quota: QuotaSnapshot) -> RateWindow {
        if let weekly = weeklyWindow(from: quota) {
            return weekly
        }
        if let secondary = quota.secondary {
            return secondary
        }
        if isFiveHour(quota.primary) {
            return quota.primary
        }
        return quota.primary
    }

    public static func make(
        quota: QuotaSnapshot,
        dailyRows: [ApiEquivalentDailyRow],
        mode: QuotaEstimateWindowMode,
        history: [QuotaEstimateHistorySample] = [],
        now: Date = Date()) -> QuotaEstimateSnapshot
    {
        let weekly = weeklyWindow(from: quota)
        let meter: RateWindow?
        switch mode {
        case .auto:
            meter = autoMeter(from: quota)
        case .rollingWeek:
            meter = weekly
        }
        let cycleStartDate = cycleStart(
            mode: mode,
            meter: meter,
            dailyRows: dailyRows,
            now: now)
        let currentRows = dailyRows
            .filter { $0.date >= cycleStartDate }
            .sorted { $0.date < $1.date }
            .map(row(from:))
        let usedCredits = currentRows.reduce(0) { $0 + $1.credits }
        let usedPercent = meter?.usedPercentExact ?? 0
        let canExtrapolate = meter != nil && usedPercent > 0 && usedCredits > 0
        let estimatedCredits = canExtrapolate ? usedCredits / (usedPercent / 100) : nil
        let comparison = compare(
            estimatedCredits: estimatedCredits,
            cycleStartDate: cycleStartDate,
            history: history)

        return QuotaEstimateSnapshot(
            windowMode: mode,
            cycleStartDate: cycleStartDate,
            usedPercent: usedPercent,
            usedCredits: usedCredits,
            usedUSD: QuotaEstimateDailyRow.usd(forCredits: usedCredits),
            dayCount: currentRows.count,
            estimatedCredits: estimatedCredits,
            estimatedUSD: estimatedCredits.map(QuotaEstimateDailyRow.usd(forCredits:)),
            canExtrapolate: canExtrapolate,
            hasWeeklyWindow: weekly != nil,
            currentRows: currentRows,
            previousEstimate: comparison.previous,
            changePercent: comparison.changePercent,
            changeKind: comparison.kind,
            history: QuotaEstimateHistoryStore.normalized(history),
            calculatedAt: now)
    }

    public static func sample(from snapshot: QuotaEstimateSnapshot) -> QuotaEstimateHistorySample? {
        guard snapshot.canExtrapolate, let estimated = snapshot.estimatedCredits else { return nil }
        return QuotaEstimateHistorySample(
            cycleStartDate: snapshot.cycleStartDate,
            estimatedCredits: estimated,
            usedPercent: snapshot.usedPercent,
            usedCredits: snapshot.usedCredits,
            recordedAt: snapshot.calculatedAt)
    }

    public static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }

    public static func utcDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    public static func addUTCDays(_ ymd: String, _ delta: Int) -> String {
        guard let date = dayFormatter.date(from: ymd),
              let shifted = utcCalendar.date(byAdding: .day, value: delta, to: date)
        else { return ymd }
        return utcDay(shifted)
    }

    public static func analyticsRange(now: Date = Date()) -> (start: String, end: String, window: DateInterval) {
        let startDay = utcCalendar.startOfDay(for: now).addingTimeInterval(
            -Double(QuotaEstimatePricing.analyticsLookbackDays) * 86_400)
        let endDay = utcCalendar.startOfDay(for: now).addingTimeInterval(86_400)
        return (utcDay(startDay), utcDay(endDay), DateInterval(start: startDay, end: endDay))
    }

    private static func cycleStart(
        mode: QuotaEstimateWindowMode,
        meter: RateWindow?,
        dailyRows: [ApiEquivalentDailyRow],
        now: Date) -> String
    {
        switch mode {
        case .rollingWeek:
            return rollingWeekStart(dailyRows: dailyRows, now: now)
        case .auto:
            let seconds = TimeInterval((meter?.windowMinutes ?? 10_080) * 60)
            if let reset = meter?.resetsAt, seconds > 0 {
                return utcDay(reset.addingTimeInterval(-seconds))
            }
            return addUTCDays(utcDay(now), -6)
        }
    }

    private static func rollingWeekStart(dailyRows: [ApiEquivalentDailyRow], now: Date) -> String {
        let dates = dailyRows.map(\.date).filter { !$0.isEmpty }.sorted()
        if let latest = dates.last {
            return addUTCDays(latest, -6)
        }
        return addUTCDays(utcDay(now), -6)
    }

    private static func row(from daily: ApiEquivalentDailyRow) -> QuotaEstimateDailyRow {
        QuotaEstimateDailyRow(
            date: daily.date,
            credits: daily.rawCredits,
            tokens: daily.totals.totalTokens,
            turns: daily.totals.turns,
            usd: QuotaEstimateDailyRow.usd(forCredits: daily.rawCredits))
    }

    private static func compare(
        estimatedCredits: Double?,
        cycleStartDate: String,
        history: [QuotaEstimateHistorySample]
    ) -> (previous: QuotaEstimateHistorySample?, changePercent: Double?, kind: QuotaEstimateChangeKind?) {
        guard let estimatedCredits else {
            return (nil, nil, nil)
        }
        let previous = history
            .filter { $0.cycleStartDate != cycleStartDate }
            .sorted { $0.cycleStartDate < $1.cycleStartDate }
            .last
        guard let previous, previous.estimatedCredits > 0 else {
            return (previous, nil, nil)
        }
        let change = (estimatedCredits - previous.estimatedCredits) / previous.estimatedCredits * 100
        let kind: QuotaEstimateChangeKind
        if abs(change) < QuotaEstimatePricing.significantChangePercent {
            kind = .similar
        } else if change < 0 {
            kind = .decreased
        } else {
            kind = .increased
        }
        return (previous, change, kind)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
