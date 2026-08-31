import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Token usage heatmap")
struct TokenUsageHeatmapTests {
    @Test("Codex profile daily buckets match the product token activity values")
    func profileDailyUsageDecode() throws {
        let data = """
        {
          "stats": {
            "daily_usage_buckets": [
              {"start_date":"2026-07-25","tokens":488682728},
              {"start_date":"2026-07-26","tokens":159644197}
            ]
          },
          "metadata": {
            "generated_at": "2026-07-27T08:03:40.648014Z",
            "stats_as_of": "2026-07-27",
            "stats_error": null
          }
        }
        """.data(using: .utf8)!

        let usage = try CodexProfileTokenUsage.decode(from: data)

        #expect(usage.dailyTokens["2026-07-25"] == 488_682_728)
        #expect(usage.dailyTokens["2026-07-26"] == 159_644_197)
        #expect(usage.statsAsOf == "2026-07-27")
        #expect(usage.generatedAt == RunwayDates.parse("2026-07-27T08:03:40.648014Z"))
    }

    @Test("Codex profile daily buckets reject invalid usage")
    func profileDailyUsageRejectsInvalidValues() {
        let negative = """
        {"stats":{"daily_usage_buckets":[{"start_date":"2026-07-26","tokens":-1}]}}
        """.data(using: .utf8)!
        let invalidDate = """
        {"stats":{"daily_usage_buckets":[{"start_date":"2026-02-30","tokens":1}]}}
        """.data(using: .utf8)!
        let statsError = """
        {"stats":{"daily_usage_buckets":[]},"metadata":{"stats_error":"failed"}}
        """.data(using: .utf8)!
        let invalidMetadata = """
        {
          "stats":{"daily_usage_buckets":[]},
          "metadata":{"generated_at":"not-a-date","stats_as_of":"2026-02-30"}
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try CodexProfileTokenUsage.decode(from: negative)
        }
        #expect(throws: DecodingError.self) {
            try CodexProfileTokenUsage.decode(from: invalidDate)
        }
        #expect(throws: DecodingError.self) {
            try CodexProfileTokenUsage.decode(from: statsError)
        }
        #expect(throws: DecodingError.self) {
            try CodexProfileTokenUsage.decode(from: invalidMetadata)
        }
    }

    @Test("empty data still builds a year-to-date grid")
    func emptyDataBuildsGrid() {
        let now = date("2026-07-15")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: [:],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        #expect(!snapshot.weeks.isEmpty)
        #expect(snapshot.totalTokens == 0)
        #expect(!snapshot.hasUsage)
        #expect(snapshot.weeks.allSatisfy { $0.count == 7 })
        #expect(snapshot.weeks.flatMap { $0 }.filter(\.isInRange).allSatisfy { $0.level == 0 })
    }

    @Test("daily mode uses per-day totals")
    func dailyModeUsesPerDayTotals() {
        let now = date("2026-01-10")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: [
                "2026-01-05": 100,
                "2026-01-06": 400,
            ],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        let cells = snapshot.weeks.flatMap { $0 }.filter(\.isInRange)
        let jan5 = cells.first { $0.dayKey == "2026-01-05" }
        let jan6 = cells.first { $0.dayKey == "2026-01-06" }
        #expect(jan5?.tokens == 100)
        #expect(jan6?.tokens == 400)
        #expect(snapshot.totalTokens == 500)
        #expect(snapshot.hasUsage)
        #expect((jan6?.level ?? 0) >= (jan5?.level ?? 0))
    }

    @Test("weekly mode paints each day with the week total")
    func weeklyModeUsesWeekTotals() {
        let now = date("2026-01-10")
        // 2026-01-04 is Sunday; with firstWeekday=1 (Sunday) this is one week.
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: [
                "2026-01-04": 10,
                "2026-01-05": 30,
                "2026-01-06": 60,
            ],
            mode: .weekly,
            now: now,
            firstWeekday: 1)

        let cells = snapshot.weeks.flatMap { $0 }.filter(\.isInRange)
        let weekCells = cells.filter { ["2026-01-04", "2026-01-05", "2026-01-06"].contains($0.dayKey) }
        #expect(weekCells.count == 3)
        #expect(weekCells.allSatisfy { $0.tokens == 100 })
    }

    @Test("cumulative mode increases through the year")
    func cumulativeModeRunningTotal() {
        let now = date("2026-01-05")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: [
                "2026-01-01": 10,
                "2026-01-02": 20,
                "2026-01-03": 30,
            ],
            mode: .cumulative,
            now: now,
            firstWeekday: 1)

        let cells = Dictionary(
            uniqueKeysWithValues: snapshot.weeks.flatMap { $0 }.filter(\.isInRange).map { ($0.dayKey, $0.tokens) })
        #expect(cells["2026-01-01"] == 10)
        #expect(cells["2026-01-02"] == 30)
        #expect(cells["2026-01-03"] == 60)
        #expect(cells["2026-01-04"] == 60)
        #expect(cells["2026-01-05"] == 60)
    }

    @Test("zero-token days stay at level zero")
    func zeroTokenDaysStayLevelZero() {
        let now = date("2026-03-01")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: ["2026-02-15": 1_000],
            mode: .daily,
            now: now,
            firstWeekday: 2)

        let zeros = snapshot.weeks.flatMap { $0 }.filter { $0.isInRange && $0.dayKey != "2026-02-15" }
        #expect(zeros.allSatisfy { $0.level == 0 && $0.tokens == 0 })
        let peak = snapshot.weeks.flatMap { $0 }.first { $0.dayKey == "2026-02-15" }
        #expect(peak?.level == 4 || peak?.level == 1)
    }

    @Test("future days after today are out of range")
    func futureDaysOutOfRange() {
        let now = date("2026-06-15")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: ["2026-06-20": 999],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        let future = snapshot.weeks.flatMap { $0 }.first { $0.dayKey == "2026-06-20" }
        #expect(future?.isInRange == false)
        #expect(snapshot.totalTokens == 0)
    }

    @Test("year-to-date window starts on January 1 in the display calendar")
    func yearToDateWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-07-27T12:00:00Z")
        let window = TokenUsageHeatmapBuilder.yearToDateWindow(now: now, calendar: calendar)
        #expect(dayKey(window.start) == "2026-01-01")
        #expect(dayKey(window.end.addingTimeInterval(-1)) == "2026-07-27")
    }

    @Test("official profile window follows UTC day boundaries")
    func utcYearToDateWindow() {
        let now = date("2026-08-30T01:00:00+08:00")
        let window = TokenUsageHeatmapBuilder.utcYearToDateWindow(now: now)

        #expect(window.start == date("2026-01-01T00:00:00Z"))
        #expect(window.end == date("2026-08-30T00:00:00Z"))
    }

    @Test("UTC heatmap clips to the UTC civil day and looks up UTC keys")
    func utcHeatmapAlignsKeysToUtcDay() {
        let now = date("2026-08-30T01:00:00+08:00")
        let utc = TimeZone(secondsFromGMT: 0)!
        let snapshot = TokenUsageHeatmapBuilder.make(
            allDevicesTokens: ["2026-08-29": 100, "2026-08-30": 200],
            localTokens: ["2026-08-29": 10, "2026-08-30": 20],
            mode: .daily,
            now: now,
            firstWeekday: 1,
            timeZone: utc)
        let cells = snapshot.weeks.flatMap { $0 }
        let utcToday = cells.first { $0.dayKey == "2026-08-29" }

        #expect(utcToday?.isInRange == true)
        #expect(utcToday?.allDevicesTokens == 100)
        #expect(utcToday?.localTokens == 10)
        #expect(!cells.contains { $0.dayKey == "2026-08-30" && $0.isInRange })
        #expect(snapshot.totalAllDevicesTokens == 100)
        #expect(snapshot.totalLocalTokens == 10)
    }

    @Test("compact token counts use 万/亿 in Chinese and K/M/B in English")
    func compactTokenCountFormatting() {
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(999, language: .simplifiedChinese) == "999")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(3_000_100, language: .simplifiedChinese) == "300.01万")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(982_000_000, language: .simplifiedChinese) == "9.82亿")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .simplifiedChinese) == "1万")

        #expect(TokenUsageHeatmapBuilder.compactTokenCount(1_500, language: .english) == "1.5K")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(100_340_000, language: .english) == "100.34M")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(2_000_000_000, language: .english) == "2B")

        #expect(TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .traditionalChinese) == "1萬")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(100_000_000, language: .japanese) == "1億")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .korean) == "1만")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(1_500, language: .french) == "1.5K")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(1_500, language: .russian) == "1.5K")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .japanese) != "1.5K")
        #expect(TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .french) != TokenUsageHeatmapBuilder.compactTokenCount(10_000, language: .japanese))
    }

    @Test("intensity prefers all-devices series while cells keep both values")
    func dualSeriesPrefersAllDevicesForIntensity() {
        let now = date("2026-01-10")
        let snapshot = TokenUsageHeatmapBuilder.make(
            allDevicesTokens: [
                "2026-01-05": 1_600_000_000,
                "2026-01-06": 100,
            ],
            localTokens: [
                "2026-01-05": 1_000_000_000,
                "2026-01-06": 50,
            ],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        let jan5 = snapshot.weeks.flatMap { $0 }.first { $0.dayKey == "2026-01-05" }
        #expect(jan5?.allDevicesTokens == 1_600_000_000)
        #expect(jan5?.localTokens == 1_000_000_000)
        #expect(jan5?.tokens == 1_600_000_000)
        #expect(snapshot.hasAllDevicesData)
        #expect(snapshot.hasLocalData)
        #expect(snapshot.totalAllDevicesTokens == 1_600_000_100)
        #expect(snapshot.totalLocalTokens == 1_000_000_050)
    }

    @Test("local values above official remain independent and are never clamped")
    func localAboveOfficialPreservesBothSources() {
        let snapshot = TokenUsageHeatmapBuilder.make(
            allDevicesTokens: ["2026-01-05": 998_000_000],
            localTokens: ["2026-01-05": 1_611_000_000],
            mode: .daily,
            now: date("2026-01-10"),
            firstWeekday: 1)

        let cell = snapshot.weeks.flatMap { $0 }.first { $0.dayKey == "2026-01-05" }
        #expect(cell?.allDevicesTokens == 998_000_000)
        #expect(cell?.localTokens == 1_611_000_000)
        #expect(cell?.tokens == 998_000_000)
        #expect(snapshot.totalAllDevicesTokens == 998_000_000)
        #expect(snapshot.totalLocalTokens == 1_611_000_000)
    }

    @Test("weekly mode colors by week total but tooltip fields stay daily")
    func weeklyModeKeepsDailyTooltipValues() {
        let now = date("2026-01-10")
        // 2026-01-04 is Sunday with firstWeekday=1.
        let snapshot = TokenUsageHeatmapBuilder.make(
            allDevicesTokens: [
                "2026-01-04": 10,
                "2026-01-05": 30,
                "2026-01-06": 60,
            ],
            localTokens: [
                "2026-01-05": 7,
            ],
            mode: .weekly,
            now: now,
            firstWeekday: 1)

        let jan5 = snapshot.weeks.flatMap { $0 }.first { $0.dayKey == "2026-01-05" }
        // Intensity metric is the week total.
        #expect(jan5?.tokens == 100)
        // Tooltip fields must remain that day's own profile activity totals.
        #expect(jan5?.allDevicesTokens == 30)
        #expect(jan5?.localTokens == 7)
    }

    @Test("month labels mark first week of each month in range")
    func monthLabels() {
        let now = date("2026-03-20")
        let snapshot = TokenUsageHeatmapBuilder.make(
            dailyTokens: [:],
            mode: .daily,
            now: now,
            firstWeekday: 1)
        let months = snapshot.monthLabels.map(\.month)
        #expect(months.contains(1))
        #expect(months.contains(2))
        #expect(months.contains(3))
        #expect(months == months.sorted())
    }

    @Test("chart series daily mode is capped at the last 30 days")
    func chartSeriesDailyPointCount() {
        let now = date("2026-03-20")
        var daily: [String: Int] = [:]
        // Spread usage across more than 30 days of the year.
        for day in 1...20 {
            daily[String(format: "2026-01-%02d", day)] = 10
            daily[String(format: "2026-02-%02d", day)] = 20
            daily[String(format: "2026-03-%02d", day)] = 30
        }
        let series = TokenUsageHeatmapBuilder.makeSeries(
            dailyTokens: daily,
            mode: .daily,
            now: now,
            firstWeekday: 1)

        #expect(series.points.count == TokenUsageHeatmapBuilder.chartDailyWindowDays)
        #expect(series.points.first?.dayKey == "2026-02-19")
        #expect(series.points.last?.dayKey == "2026-03-20")
        #expect(series.points.contains { $0.dayKey == "2026-01-15" } == false)
        #expect(series.hasUsage)
    }

    @Test("chart series daily mode early in the year uses available days only")
    func chartSeriesDailyEarlyYear() {
        let now = date("2026-01-10")
        let series = TokenUsageHeatmapBuilder.makeSeries(
            dailyTokens: [
                "2026-01-05": 100,
                "2026-01-06": 400,
            ],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        #expect(series.points.count == 10)
        let byKey = Dictionary(uniqueKeysWithValues: series.points.map { ($0.dayKey, $0.tokens) })
        #expect(byKey["2026-01-05"] == 100)
        #expect(byKey["2026-01-06"] == 400)
        #expect(series.totalTokens == 500)
    }

    @Test("chart series weekly mode collapses to one point per week")
    func chartSeriesWeeklyOnePointPerWeek() {
        let now = date("2026-01-10")
        let series = TokenUsageHeatmapBuilder.makeSeries(
            dailyTokens: [
                "2026-01-04": 10,
                "2026-01-05": 30,
                "2026-01-06": 60,
            ],
            mode: .weekly,
            now: now,
            firstWeekday: 1)

        // 2026-01-01..01-10 with Sunday firstWeekday spans 2 weeks.
        #expect(series.points.count == 2)
        let weekWithUsage = series.points.first { $0.tokens == 100 }
        #expect(weekWithUsage != nil)
        #expect(weekWithUsage?.allDevicesTokens == 0)
        #expect(weekWithUsage?.localTokens == 100)
    }

    @Test("chart series third mode is one point per month")
    func chartSeriesMonthlyOnePointPerMonth() {
        let now = date("2026-03-15")
        let series = TokenUsageHeatmapBuilder.makeSeries(
            dailyTokens: [
                "2026-01-01": 10,
                "2026-01-20": 20,
                "2026-02-05": 40,
                "2026-03-10": 100,
            ],
            mode: .cumulative,
            now: now,
            firstWeekday: 1)

        #expect(series.points.count == 3)
        #expect(series.points[0].tokens == 30)
        #expect(series.points[1].tokens == 40)
        #expect(series.points[2].tokens == 100)
    }

    @Test("chart series prefers all-devices primary values")
    func chartSeriesPrefersAllDevices() {
        let now = date("2026-01-10")
        let series = TokenUsageHeatmapBuilder.makeSeries(
            allDevicesTokens: [
                "2026-01-05": 1_600,
                "2026-01-06": 100,
            ],
            localTokens: [
                "2026-01-05": 50,
                "2026-01-06": 20,
            ],
            mode: .daily,
            now: now,
            firstWeekday: 1)

        let jan5 = series.points.first { $0.dayKey == "2026-01-05" }
        #expect(jan5?.tokens == 1_600)
        #expect(jan5?.allDevicesTokens == 1_600)
        #expect(jan5?.localTokens == 50)
        #expect(series.hasAllDevicesData)
        #expect(series.totalTokens == 1_700)
    }

    private func date(_ value: String) -> Date {
        if value.count == 10 {
            return ISO8601DateFormatter().date(from: "\(value)T12:00:00Z")!
        }
        return ISO8601DateFormatter().date(from: value)!
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
