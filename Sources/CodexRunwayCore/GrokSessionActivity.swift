import Foundation

/// Token / cost totals derived from local Grok CLI `turn_completed` session logs.
public struct GrokUsageTotals: Codable, Sendable, Equatable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedReadTokens: Int
    public var reasoningTokens: Int
    public var turns: Int
    public var modelCalls: Int
    /// API-equivalent USD from official xAI token prices, summed over priced turns.
    public var estimatedUSD: Decimal?

    public static let zero = GrokUsageTotals(
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
        cachedReadTokens: 0,
        reasoningTokens: 0,
        turns: 0,
        modelCalls: 0,
        estimatedUSD: nil)

    public init(
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cachedReadTokens: Int,
        reasoningTokens: Int,
        turns: Int,
        modelCalls: Int,
        estimatedUSD: Decimal?)
    {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.reasoningTokens = reasoningTokens
        self.turns = turns
        self.modelCalls = modelCalls
        self.estimatedUSD = estimatedUSD
    }

    public var hasData: Bool {
        totalTokens > 0 || turns > 0 || (estimatedUSD ?? 0) > 0
    }

    public var apiTotals: ApiEquivalentTotals {
        let cached = max(0, cachedReadTokens)
        let uncached = max(0, inputTokens - cached)
        return ApiEquivalentTotals(
            totalTokens: totalTokens,
            uncachedInputTokens: uncached,
            cachedInputTokens: cached,
            outputTokens: outputTokens,
            turns: turns,
            threads: turns > 0 ? 1 : 0)
    }

    public mutating func merge(_ other: GrokUsageTotals) {
        totalTokens += other.totalTokens
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedReadTokens += other.cachedReadTokens
        reasoningTokens += other.reasoningTokens
        turns += other.turns
        modelCalls += other.modelCalls
        switch (estimatedUSD, other.estimatedUSD) {
        case let (lhs?, rhs?):
            estimatedUSD = lhs + rhs
        case (nil, let rhs?):
            estimatedUSD = rhs
        default:
            break
        }
    }
}

public struct GrokModelUsageRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model }
    public var model: String
    public var totals: GrokUsageTotals

    public init(model: String, totals: GrokUsageTotals) {
        self.model = model
        self.totals = totals
    }
}

public struct GrokSessionActivityItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var projectName: String
    public var cwd: String?
    public var model: String?
    public var updatedAt: Date
    public var messageCount: Int
    public var totals: GrokUsageTotals

    public init(
        id: String,
        title: String,
        projectName: String,
        cwd: String?,
        model: String?,
        updatedAt: Date,
        messageCount: Int,
        totals: GrokUsageTotals)
    {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.cwd = cwd
        self.model = model
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.totals = totals
    }
}

public struct GrokLocalUsageSummary: Codable, Sendable, Equatable {
    public var totals: GrokUsageTotals
    public var sessionCount: Int
    public var modelRows: [GrokModelUsageRow]
    public var recentItems: [GrokSessionActivityItem]
    /// Calendar day (`yyyy-MM-dd`) → total tokens for Token 用量 charts.
    public var dailyTokens: [String: Int]
    public var costSummary: ApiEquivalentSummary
    public var calculatedAt: Date
    public var sourceLabel: String

    public init(
        totals: GrokUsageTotals,
        sessionCount: Int,
        modelRows: [GrokModelUsageRow],
        recentItems: [GrokSessionActivityItem],
        dailyTokens: [String: Int] = [:],
        costSummary: ApiEquivalentSummary,
        calculatedAt: Date,
        sourceLabel: String = "local-sessions")
    {
        self.totals = totals
        self.sessionCount = sessionCount
        self.modelRows = modelRows
        self.recentItems = recentItems
        self.dailyTokens = dailyTokens
        self.costSummary = costSummary
        self.calculatedAt = calculatedAt
        self.sourceLabel = sourceLabel
    }
}

/// Scans `~/.grok/sessions/**/summary.json` and optional `updates.jsonl` turn usage.
public struct GrokSessionScanner: Sendable {
    public var grokHome: URL
    /// Grok CLI reports `costUsdTicks` such that USD = ticks / 1_000_000_000.
    /// Kept for diagnostics; API-equivalent cost uses `GrokPricingTable`, not ticks.
    public static let costUsdTicksPerDollar: Decimal = 1_000_000_000
    public static let pricingVersion = GrokPricingTable.version

    public init(
        grokHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true))
    {
        self.grokHome = grokHome
    }

    /// Recent sessions + year-to-date daily tokens + cost for the given window.
    public func scan(
        recentLimit: Int = 5,
        sessionLimit: Int = 300,
        costWindow: DateInterval? = nil,
        now: Date = Date()
    ) throws -> GrokLocalUsageSummary {
        let recentLimit = max(0, recentLimit)
        let sessionLimit = max(recentLimit, sessionLimit)
        let summaries = try listSummaries(limit: sessionLimit)
        let calendar = Calendar.autoupdatingCurrent
        let yearStart = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: now),
            month: 1,
            day: 1)) ?? calendar.startOfDay(for: now)
        // Default cost window = YTD; heatmap receives full daily map and clips itself.
        let costWindow = costWindow ?? DateInterval(start: yearStart, end: now)

        var aggregate = GrokUsageTotals.zero
        var byModel: [String: GrokUsageTotals] = [:]
        var byProject: [String: GrokUsageTotals] = [:]
        var byDay: [String: GrokUsageTotals] = [:]
        var dailyTokens: [String: Int] = [:]
        var items: [GrokSessionActivityItem] = []
        items.reserveCapacity(min(recentLimit, summaries.count))

        for (index, summary) in summaries.enumerated() {
            let parsed = parseUsage(
                from: summary.directory.appendingPathComponent("updates.jsonl"),
                fallbackDate: summary.updatedAt,
                fallbackModel: summary.model,
                calendar: calendar)
            // Keep all day keys; TokenUsageHeatmapBuilder clips to the display year.
            for (day, dayTotals) in parsed.byDay {
                dailyTokens[day, default: 0] += dayTotals.totalTokens
            }

            // Cost window aggregation.
            let inCostWindow = mergeWindowed(
                parsed: parsed,
                window: costWindow,
                calendar: calendar,
                into: &aggregate,
                byModel: &byModel,
                byProject: &byProject,
                byDay: &byDay,
                projectName: summary.projectName)

            if index < recentLimit {
                items.append(
                    GrokSessionActivityItem(
                        id: summary.id,
                        title: summary.title,
                        projectName: summary.projectName,
                        cwd: summary.cwd,
                        model: summary.model,
                        updatedAt: summary.updatedAt,
                        messageCount: summary.messageCount,
                        totals: inCostWindow ? windowedSessionTotals(parsed, window: costWindow, calendar: calendar) : .zero))
            }
        }

        let modelRows = sortedModelRows(byModel)
        let costSummary = makeCostSummary(
            aggregate: aggregate,
            byModel: byModel,
            byProject: byProject,
            byDay: byDay,
            window: costWindow,
            now: now)

        return GrokLocalUsageSummary(
            totals: aggregate,
            sessionCount: summaries.count,
            modelRows: modelRows,
            recentItems: items,
            dailyTokens: dailyTokens,
            costSummary: costSummary,
            calculatedAt: now)
    }

    /// Cost-only scan for a specific API-cost range (detail page).
    public func scanCost(window: DateInterval, now: Date = Date()) throws -> ApiEquivalentSummary {
        try scan(
            recentLimit: 0,
            sessionLimit: 400,
            costWindow: window,
            now: now).costSummary
    }

    public static func usd(fromCostTicks ticks: Int64?) -> Decimal? {
        guard let ticks, ticks != 0 else { return nil }
        return Decimal(ticks) / costUsdTicksPerDollar
    }

    // MARK: - Internals

    private struct SummaryFile {
        var id: String
        var title: String
        var projectName: String
        var cwd: String?
        var model: String?
        var updatedAt: Date
        var messageCount: Int
        var directory: URL
    }

    private struct ParsedUsage {
        var byDay: [String: GrokUsageTotals]
        var byDayModel: [String: [String: GrokUsageTotals]]
    }

    private func listSummaries(limit: Int) throws -> [SummaryFile] {
        guard limit > 0 else { return [] }
        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else { return [] }

        var candidates: [(url: URL, mtime: Date)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "summary.json" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            candidates.append((url, mtime))
        }

        candidates.sort {
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.url.path < $1.url.path
        }

        var result: [SummaryFile] = []
        result.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates.prefix(limit) {
            if let summary = try? parseSummary(at: candidate.url, mtime: candidate.mtime) {
                result.append(summary)
            }
        }
        return result
    }

    private func parseSummary(at url: URL, mtime: Date) throws -> SummaryFile {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let info = root["info"] as? [String: Any] ?? [:]
        let id = nonEmpty(info["id"] as? String)
            ?? url.deletingLastPathComponent().lastPathComponent
        let cwd = nonEmpty(info["cwd"] as? String)
        let title = nonEmpty(root["generated_title"] as? String)
            ?? nonEmpty(root["session_summary"] as? String)
            ?? "Untitled session"
        let model = nonEmpty(root["current_model_id"] as? String)
        let updatedAt = parseDate(root["last_active_at"] as? String)
            ?? parseDate(root["updated_at"] as? String)
            ?? mtime
        let messages = (root["num_chat_messages"] as? Int)
            ?? (root["num_messages"] as? Int)
            ?? 0
        return SummaryFile(
            id: id,
            title: title,
            projectName: SessionProjectName.displayName(for: cwd),
            cwd: cwd,
            model: model,
            updatedAt: updatedAt,
            messageCount: messages,
            directory: url.deletingLastPathComponent())
    }

    private func parseUsage(
        from updatesURL: URL,
        fallbackDate: Date,
        fallbackModel: String?,
        calendar: Calendar
    ) -> ParsedUsage {
        guard FileManager.default.fileExists(atPath: updatesURL.path),
              let data = try? Data(contentsOf: updatesURL),
              !data.isEmpty
        else {
            return ParsedUsage(byDay: [:], byDayModel: [:])
        }

        var byDay: [String: GrokUsageTotals] = [:]
        var byDayModel: [String: [String: GrokUsageTotals]] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard lineContainsTurnUsage(line),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let update = ((object["params"] as? [String: Any])?["update"] as? [String: Any]),
                  (update["sessionUpdate"] as? String) == "turn_completed",
                  let usage = update["usage"] as? [String: Any]
            else {
                continue
            }
            let day = dayKey(for: object, fallback: fallbackDate, calendar: calendar)
            var turn = usageTotals(from: usage, countAsTurn: true, model: nil)
            turn.estimatedUSD = accumulateModelUsage(
                usage["modelUsage"] as? [String: Any],
                fallbackUsage: usage,
                fallbackModel: fallbackModel,
                day: day,
                byDayModel: &byDayModel)
            var dayTotals = byDay[day] ?? .zero
            dayTotals.merge(turn)
            byDay[day] = dayTotals
        }
        return ParsedUsage(
            byDay: byDay,
            byDayModel: byDayModel)
    }

    /// Prices each model row from official API rates. Returns the sum of priced
    /// rows (nil if none priced) so mixed unknown models do not blank the turn.
    private func accumulateModelUsage(
        _ modelUsage: [String: Any]?,
        fallbackUsage: [String: Any],
        fallbackModel: String?,
        day: String,
        byDayModel: inout [String: [String: GrokUsageTotals]]
    ) -> Decimal? {
        var pricedSum: Decimal?
        var sawModel = false
        if let modelUsage {
            for (model, value) in modelUsage {
                guard let modelObject = value as? [String: Any] else { continue }
                sawModel = true
                mergeModelRow(
                    usageTotals(from: modelObject, countAsTurn: false, model: model),
                    model: model,
                    day: day,
                    byDayModel: &byDayModel,
                    pricedSum: &pricedSum)
            }
        }
        if !sawModel, let fallbackModel, !fallbackModel.isEmpty {
            mergeModelRow(
                usageTotals(from: fallbackUsage, countAsTurn: false, model: fallbackModel),
                model: fallbackModel,
                day: day,
                byDayModel: &byDayModel,
                pricedSum: &pricedSum)
        }
        return pricedSum
    }

    private func mergeModelRow(
        _ row: GrokUsageTotals,
        model: String,
        day: String,
        byDayModel: inout [String: [String: GrokUsageTotals]],
        pricedSum: inout Decimal?
    ) {
        var dayModels = byDayModel[day] ?? [:]
        var dayRow = dayModels[model] ?? .zero
        dayRow.merge(row)
        dayModels[model] = dayRow
        byDayModel[day] = dayModels
        if let cost = row.estimatedUSD {
            pricedSum = (pricedSum ?? 0) + cost
        }
    }

    @discardableResult
    private func mergeWindowed(
        parsed: ParsedUsage,
        window: DateInterval,
        calendar: Calendar,
        into aggregate: inout GrokUsageTotals,
        byModel: inout [String: GrokUsageTotals],
        byProject: inout [String: GrokUsageTotals],
        byDay: inout [String: GrokUsageTotals],
        projectName: String
    ) -> Bool {
        var matched = GrokUsageTotals.zero
        for (day, dayTotals) in parsed.byDay {
            guard let dayDate = dayDate(day, calendar: calendar),
                  dayDate >= window.start,
                  dayDate < window.end
            else { continue }
            matched.merge(dayTotals)
            var bucket = byDay[day] ?? .zero
            bucket.merge(dayTotals)
            byDay[day] = bucket
            if let models = parsed.byDayModel[day] {
                for (model, modelTotals) in models {
                    var row = byModel[model] ?? .zero
                    row.merge(modelTotals)
                    byModel[model] = row
                }
            }
        }
        guard matched.hasData else { return false }
        aggregate.merge(matched)
        var project = byProject[projectName] ?? .zero
        project.merge(matched)
        byProject[projectName] = project
        return true
    }

    private func windowedSessionTotals(
        _ parsed: ParsedUsage,
        window: DateInterval,
        calendar: Calendar
    ) -> GrokUsageTotals {
        var matched = GrokUsageTotals.zero
        for (day, dayTotals) in parsed.byDay {
            guard let dayDate = dayDate(day, calendar: calendar),
                  dayDate >= window.start,
                  dayDate < window.end
            else { continue }
            matched.merge(dayTotals)
        }
        return matched
    }

    private func makeCostSummary(
        aggregate: GrokUsageTotals,
        byModel: [String: GrokUsageTotals],
        byProject: [String: GrokUsageTotals],
        byDay: [String: GrokUsageTotals],
        window: DateInterval,
        now: Date
    ) -> ApiEquivalentSummary {
        let dailyRows = byDay.keys.sorted().map { day -> ApiEquivalentDailyRow in
            let totals = byDay[day] ?? .zero
            return ApiEquivalentDailyRow(
                date: day,
                totals: totals.apiTotals,
                estimatedUSD: totals.estimatedUSD,
                rawCredits: 0)
        }
        let modelRows = sortedModelRows(byModel).map {
            ApiEquivalentBreakdownRow(
                name: $0.model,
                totals: $0.totals.apiTotals,
                estimatedUSD: $0.totals.estimatedUSD,
                rawCredits: 0)
        }
        let projectRows = byProject
            .map {
                ApiEquivalentBreakdownRow(
                    name: $0.key,
                    totals: $0.value.apiTotals,
                    estimatedUSD: $0.value.estimatedUSD,
                    rawCredits: 0)
            }
            .sorted {
                if $0.totals.totalTokens != $1.totals.totalTokens {
                    return $0.totals.totalTokens > $1.totals.totalTokens
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        let clientRows = [
            ApiEquivalentBreakdownRow(
                name: "Grok CLI",
                totals: aggregate.apiTotals,
                estimatedUSD: aggregate.estimatedUSD,
                rawCredits: 0),
        ]
        let unknownModels = byModel.keys
            .filter { GrokPricingTable.price(for: $0) == nil }
            .sorted()
        let confidence: ApiEquivalentConfidence
        if aggregate.totalTokens == 0 {
            confidence = .unavailable
        } else if aggregate.estimatedUSD == nil {
            confidence = .tokensOnly
        } else {
            confidence = .priced
        }
        return ApiEquivalentSummary(
            source: aggregate.totalTokens > 0 ? .localSessions : .unavailable,
            confidence: confidence,
            window: window,
            estimatedUSD: aggregate.estimatedUSD,
            totals: aggregate.apiTotals,
            dailyRows: dailyRows,
            modelRows: modelRows,
            projectRows: projectRows,
            clientRows: clientRows,
            rawCredits: 0,
            warnings: unknownModels.map { "unknown-model:\($0)" },
            pricingVersion: Self.pricingVersion,
            calculatedAt: now)
    }

    private func sortedModelRows(_ byModel: [String: GrokUsageTotals]) -> [GrokModelUsageRow] {
        byModel
            .map { GrokModelUsageRow(model: $0.key, totals: $0.value) }
            .sorted {
                if $0.totals.totalTokens != $1.totals.totalTokens {
                    return $0.totals.totalTokens > $1.totals.totalTokens
                }
                return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
            }
    }

    private func lineContainsTurnUsage(_ line: Data.SubSequence) -> Bool {
        line.range(of: Data("turn_completed".utf8)) != nil
            && line.range(of: Data("\"usage\"".utf8)) != nil
    }

    private func usageTotals(
        from usage: [String: Any],
        countAsTurn: Bool,
        model: String?
    ) -> GrokUsageTotals {
        let input = intValue(usage["inputTokens"])
        let output = intValue(usage["outputTokens"])
        let cached = intValue(usage["cachedReadTokens"])
        let reasoning = intValue(usage["reasoningTokens"])
        let reportedTotal = intValue(usage["totalTokens"])
        let total = reportedTotal > 0 ? reportedTotal : max(0, input + output)
        let modelCalls = intValue(usage["modelCalls"])
        let cost = model.flatMap {
            GrokPricingTable.cost(
                model: $0,
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output)
        }
        return GrokUsageTotals(
            totalTokens: total,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cached,
            reasoningTokens: reasoning,
            turns: countAsTurn ? 1 : 0,
            modelCalls: modelCalls,
            estimatedUSD: cost)
    }

    private func dayKey(for object: [String: Any], fallback: Date, calendar: Calendar) -> String {
        if let seconds = timestampSeconds(object["timestamp"]) {
            return dayString(Date(timeIntervalSince1970: seconds), calendar: calendar)
        }
        if let meta = (object["params"] as? [String: Any])?["_meta"] as? [String: Any],
           let ms = timestampSeconds(meta["agentTimestampMs"]).map({ $0 / 1000 })
            ?? timestampSeconds(meta["streamStartMs"]).map({ $0 / 1000 })
            ?? timestampSeconds(meta["turnStartMs"]).map({ $0 / 1000 })
        {
            return dayString(Date(timeIntervalSince1970: ms), calendar: calendar)
        }
        return dayString(fallback, calendar: calendar)
    }

    private func timestampSeconds(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return TimeInterval(number)
        case let number as Int64:
            return TimeInterval(number)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }

    private func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dayDate(_ day: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as Int:
            return max(0, number)
        case let number as Int64:
            return max(0, Int(clamping: number))
        case let number as Double:
            return max(0, Int(number.rounded()))
        case let number as NSNumber:
            return max(0, number.intValue)
        default:
            return 0
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, let date = RunwayDates.parse(raw) else { return nil }
        return date
    }
}
