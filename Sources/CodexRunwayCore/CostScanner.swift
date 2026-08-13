import Foundation

struct UsageCostScanDiagnostics: Equatable, Sendable {
    var bytesRead = 0
    var candidateLines = 0
    var decodedLines = 0
    var maxBufferedBytes = 0
    var candidateFiles = 0
    var cacheHits = 0
    var rebuiltFiles = 0
    var maxConcurrentScans = 0
    var malformedCandidateLines = 0
    var oversizedLines = 0
}

struct UsageCostScanReport<Summary> {
    var summary: Summary
    var diagnostics: UsageCostScanDiagnostics
}

public struct UsageCostScanner: Sendable {
    public var codexHome: URL
    public var calendar: Calendar

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        calendar: Calendar = .autoupdatingCurrent)
    {
        self.codexHome = codexHome
        self.calendar = calendar
    }

    public func scan(window: DateInterval) throws -> UsageCostSummary {
        try scanReport(window: window).summary
    }

    func scanReport(window: DateInterval) throws -> UsageCostScanReport<UsageCostSummary> {
        var byModel: [String: TokenUsage] = [:]
        var unknown = Set<String>()
        let files = jsonlFiles(window: window)
        let stream = UsageCostLogStream(calendar: calendar)
        var diagnostics = UsageCostScanDiagnostics(candidateFiles: files.count)
        for file in files {
            try scan(
                file: file,
                window: window,
                byModel: &byModel,
                unknown: &unknown,
                stream: stream,
                diagnostics: &diagnostics)
        }
        let breakdown = byModel.keys.sorted().map { model in
            let usage = byModel[model] ?? .zero
            let cost = PricingTable.cost(model: model, usage: usage)
            if cost == nil { unknown.insert(model) }
            return ModelCostBreakdown(model: model, usage: usage, estimatedUSD: cost ?? 0)
        }
        let totals = try TokenUsage.sum(byModel.values)
        return UsageCostScanReport(
            summary: UsageCostSummary(
                window: window,
                totals: totals,
                modelBreakdown: breakdown,
                estimatedUSD: breakdown.reduce(Decimal(0)) { $0 + $1.estimatedUSD },
                pricingVersion: PricingTable.version,
                unknownModels: unknown.sorted()),
            diagnostics: diagnostics)
    }

    public func scanAPIEquivalent(window: DateInterval, calculatedAt: Date = Date()) throws -> ApiEquivalentSummary {
        try scanAPIEquivalentReport(window: window, calculatedAt: calculatedAt).summary
    }

    func scanAPIEquivalentReport(
        window: DateInterval,
        calculatedAt: Date = Date()) throws -> UsageCostScanReport<ApiEquivalentSummary>
    {
        var byModel: [String: ApiEquivalentTotals] = [:]
        var byProjectModel: [String: [String: ApiEquivalentTotals]] = [:]
        var byDay: [String: ApiEquivalentTotals] = [:]
        var byDayModel: [String: [String: ApiEquivalentTotals]] = [:]
        var unknown = Set<String>()
        let files = jsonlFiles(window: window)
        let stream = UsageCostLogStream(calendar: calendar)
        var diagnostics = UsageCostScanDiagnostics(candidateFiles: files.count)
        for file in files {
            try scanAPIEquivalent(
                file: file,
                window: window,
                byModel: &byModel,
                byProjectModel: &byProjectModel,
                byDay: &byDay,
                byDayModel: &byDayModel,
                unknown: &unknown,
                stream: stream,
                diagnostics: &diagnostics)
        }
        let modelRows = byModel.keys.sorted().map { model in
            let totals = byModel[model] ?? .zero
            let estimated = PricingTable.cost(model: model, totals: totals)
            return ApiEquivalentBreakdownRow(name: model, totals: totals, estimatedUSD: estimated, rawCredits: 0)
        }
        var projectRows: [ApiEquivalentBreakdownRow] = []
        projectRows.reserveCapacity(byProjectModel.count)
        for (project, projectModels) in byProjectModel {
            let projectTotals = try ApiEquivalentTotals.sum(projectModels.values)
            projectRows.append(ApiEquivalentBreakdownRow(
                name: project,
                totals: projectTotals,
                estimatedUSD: Self.estimatedCost(byModel: projectModels),
                rawCredits: 0))
        }
        projectRows.sort { lhs, rhs in
            lhs.totals.totalTokens == rhs.totals.totalTokens
                ? lhs.name < rhs.name
                : lhs.totals.totalTokens > rhs.totals.totalTokens
        }
        let dailyRows = byDay.keys.sorted().map { day in
            let totals = byDay[day] ?? .zero
            return ApiEquivalentDailyRow(
                date: day,
                totals: totals,
                estimatedUSD: Self.estimatedCost(byModel: byDayModel[day] ?? [:]),
                rawCredits: 0)
        }
        let totals = try ApiEquivalentTotals.sum(byDay.values)
        let estimatedUSD = Self.estimatedCost(byModel: byModel)
        let confidence: ApiEquivalentConfidence
        if totals.totalTokens == 0 {
            confidence = .unavailable
        } else if estimatedUSD == nil {
            confidence = .tokensOnly
        } else {
            confidence = .priced
        }
        var warnings = unknown.sorted().map { "unknown-model:\($0)" }
        if diagnostics.oversizedLines > 0 {
            warnings.append("oversized-jsonl-lines:\(diagnostics.oversizedLines)")
        }
        return UsageCostScanReport(
            summary: ApiEquivalentSummary(
                source: totals.totalTokens > 0 ? .localSessions : .unavailable,
                confidence: confidence,
                window: window,
                estimatedUSD: estimatedUSD,
                totals: totals,
                dailyRows: dailyRows,
                modelRows: modelRows,
                projectRows: projectRows,
                clientRows: [],
                rawCredits: 0,
                warnings: warnings,
                pricingVersion: PricingTable.version,
                calculatedAt: calculatedAt),
            diagnostics: diagnostics)
    }

    private func scan(
        file: URL,
        window: DateInterval,
        byModel: inout [String: TokenUsage],
        unknown: inout Set<String>,
        stream: UsageCostLogStream,
        diagnostics: inout UsageCostScanDiagnostics) throws
    {
        var currentModel = "unknown-model"
        let result = try stream.read(file: file) { line in
            let record = line.record
            if let contextModel = record.contextModel {
                currentModel = contextModel
            }
            guard window.contains(record.timestamp) else { return }
            guard let usage = record.lastTokenUsage else { return }
            let model = record.model ?? currentModel
            byModel[model, default: .zero] = try byModel[model, default: .zero].adding(usage)
            if PricingTable.price(for: model) == nil { unknown.insert(model) }
        }
        record(result: result, diagnostics: &diagnostics)
    }

    private func scanAPIEquivalent(
        file: URL,
        window: DateInterval,
        byModel: inout [String: ApiEquivalentTotals],
        byProjectModel: inout [String: [String: ApiEquivalentTotals]],
        byDay: inout [String: ApiEquivalentTotals],
        byDayModel: inout [String: [String: ApiEquivalentTotals]],
        unknown: inout Set<String>,
        stream: UsageCostLogStream,
        diagnostics: inout UsageCostScanDiagnostics) throws
    {
        var currentModel = "unknown-model"
        var currentProject = SessionProjectName.unknown
        let result = try stream.read(file: file) { line in
            let record = line.record
            if let cwd = record.sessionCWD {
                currentProject = SessionProjectName.displayName(for: cwd)
            }
            if let contextModel = record.contextModel {
                currentModel = contextModel
            }
            guard window.contains(record.timestamp) else { return }
            guard let usage = record.lastTokenUsage else { return }
            let model = record.model ?? currentModel
            let totals = try ApiEquivalentTotals(validating: usage, turns: 1, threads: 0)
            let day = record.dayKey
            byModel[model, default: .zero] = try byModel[model, default: .zero].adding(totals)
            byProjectModel[currentProject, default: [:]][model, default: .zero] = try byProjectModel[
                currentProject,
                default: [:]
            ][model, default: .zero].adding(totals)
            byDay[day, default: .zero] = try byDay[day, default: .zero].adding(totals)
            byDayModel[day, default: [:]][model, default: .zero] = try byDayModel[
                day,
                default: [:]
            ][model, default: .zero].adding(totals)
            if PricingTable.price(for: model) == nil { unknown.insert(model) }
        }
        record(result: result, diagnostics: &diagnostics)
    }

    private func record(
        result: UsageCostLogStreamResult,
        diagnostics: inout UsageCostScanDiagnostics)
    {
        diagnostics.bytesRead += result.bytesRead
        diagnostics.candidateLines += result.candidateLines
        diagnostics.decodedLines += result.decodedLines
        diagnostics.malformedCandidateLines += result.malformedCandidateLines
        diagnostics.oversizedLines += result.oversizedLines
        diagnostics.maxBufferedBytes = max(diagnostics.maxBufferedBytes, result.maxBufferedBytes)
    }

    private func jsonlFiles(window: DateInterval) -> [URL] {
        ["sessions", "archived_sessions"].flatMap { folder in
            let root = codexHome.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return [URL]()
            }
            return enumerator.compactMap { ($0 as? URL) }
                .filter { $0.pathExtension == "jsonl" && isLikelyRelevant($0, window: window) }
        }
    }

    func isLikelyRelevant(_ file: URL, window: DateInterval) -> Bool {
        if let day = dayFromPath(file) {
            let calendar = Calendar(identifier: .gregorian)
            let padded = DateInterval(
                start: calendar.date(byAdding: .day, value: -1, to: window.start) ?? window.start,
                end: calendar.date(byAdding: .day, value: 1, to: window.end) ?? window.end)
            return padded.contains(day)
        }
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            return modified >= window.start.addingTimeInterval(-86_400) && modified <= window.end.addingTimeInterval(86_400)
        }
        return true
    }

    private func dayFromPath(_ file: URL) -> Date? {
        let components = file.pathComponents
        for index in 0..<(max(0, components.count - 2)) {
            guard components[index].count == 4,
                  let year = Int(components[index]),
                  let month = Int(components[index + 1]),
                  let day = Int(components[index + 2])
            else { continue }
            return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
        }
        let name = file.lastPathComponent
        guard let match = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return RunwayDates.parse(String(name[match]) + "T00:00:00Z")
    }

    private static func estimatedCost(byModel: [String: ApiEquivalentTotals]) -> Decimal? {
        var result = Decimal(0)
        var priced = false
        for item in byModel {
            guard let cost = PricingTable.cost(model: item.key, totals: item.value) else {
                continue
            }
            priced = true
            result += cost
        }
        return priced ? result : nil
    }
}

extension ApiEquivalentTotals {
    init(validating usage: TokenUsage, turns: Int, threads: Int) throws {
        guard usage.inputTokens >= 0,
              usage.cachedInputTokens >= 0,
              usage.outputTokens >= 0,
              usage.cachedInputTokens <= usage.inputTokens,
              turns >= 0,
              threads >= 0
        else { throw UsageCostArithmeticError.invalidValue(field: "token usage") }
        let uncached = usage.inputTokens - usage.cachedInputTokens
        let input = try checkedAdd(uncached, usage.cachedInputTokens, field: "input tokens")
        self.init(
            totalTokens: try checkedAdd(input, usage.outputTokens, field: "total tokens"),
            uncachedInputTokens: uncached,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens,
            turns: turns,
            threads: threads)
    }
}

public enum PricingTable {
    /// Bundled fallback verified against the official OpenAI pricing documentation.
    public static let version = "openai-builtin-2026-08-13"

    public struct Price: Codable, Equatable, Sendable {
        var inputPerMillion: Decimal
        var cachedInputPerMillion: Decimal
        var cacheWritePerMillion: Decimal?
        var outputPerMillion: Decimal
        var longContextInputPerMillion: Decimal?
        var longContextCachedInputPerMillion: Decimal?
        var longContextCacheWritePerMillion: Decimal?
        var longContextOutputPerMillion: Decimal?

        init(
            inputPerMillion: Decimal,
            cachedInputPerMillion: Decimal,
            cacheWritePerMillion: Decimal? = nil,
            outputPerMillion: Decimal,
            longContextInputPerMillion: Decimal? = nil,
            longContextCachedInputPerMillion: Decimal? = nil,
            longContextCacheWritePerMillion: Decimal? = nil,
            longContextOutputPerMillion: Decimal? = nil)
        {
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.outputPerMillion = outputPerMillion
            self.longContextInputPerMillion = longContextInputPerMillion
            self.longContextCachedInputPerMillion = longContextCachedInputPerMillion
            self.longContextCacheWritePerMillion = longContextCacheWritePerMillion
            self.longContextOutputPerMillion = longContextOutputPerMillion
        }
    }

    static let builtInPrices: [String: Price] = [
        "gpt-5.6": Price(
            inputPerMillion: 5,
            cachedInputPerMillion: 0.5,
            cacheWritePerMillion: 6.25,
            outputPerMillion: 30,
            longContextInputPerMillion: 10,
            longContextCachedInputPerMillion: 1,
            longContextCacheWritePerMillion: 12.5,
            longContextOutputPerMillion: 45),
        "gpt-5.6-sol": Price(
            inputPerMillion: 5,
            cachedInputPerMillion: 0.5,
            cacheWritePerMillion: 6.25,
            outputPerMillion: 30,
            longContextInputPerMillion: 10,
            longContextCachedInputPerMillion: 1,
            longContextCacheWritePerMillion: 12.5,
            longContextOutputPerMillion: 45),
        "gpt-5.6-terra": Price(
            inputPerMillion: 2,
            cachedInputPerMillion: 0.2,
            cacheWritePerMillion: 2.5,
            outputPerMillion: 12,
            longContextInputPerMillion: 4,
            longContextCachedInputPerMillion: 0.4,
            longContextCacheWritePerMillion: 5,
            longContextOutputPerMillion: 18),
        "gpt-5.6-luna": Price(
            inputPerMillion: 0.2,
            cachedInputPerMillion: 0.02,
            cacheWritePerMillion: 0.25,
            outputPerMillion: 1.2,
            longContextInputPerMillion: 0.4,
            longContextCachedInputPerMillion: 0.04,
            longContextCacheWritePerMillion: 0.5,
            longContextOutputPerMillion: 1.8),
        "gpt-5.5": Price(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30),
        "gpt-5.5-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180),
        "gpt-5.4": Price(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15),
        "gpt-5.4-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180),
        "gpt-5.4-mini": Price(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5),
        "gpt-5.4-nano": Price(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.25),
        "gpt-5.3-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14),
        "gpt-5.3-codex-spark": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14),
        "gpt-5.2-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14),
        "gpt-5.2": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14),
        "gpt-5.1": Price(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10),
        "gpt-5": Price(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10),
        "gpt-5-mini": Price(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2),
        "gpt-5-nano": Price(inputPerMillion: 0.05, cachedInputPerMillion: 0.005, outputPerMillion: 0.4),
        "gpt-5-pro": Price(inputPerMillion: 15, cachedInputPerMillion: 15, outputPerMillion: 120),
        "codex-mini-latest": Price(inputPerMillion: 1.5, cachedInputPerMillion: 0.375, outputPerMillion: 6),
    ]

    public static func price(for model: String) -> Price? {
        price(for: model, in: builtInPrices)
    }

    static func price(for model: String, in prices: [String: Price]) -> Price? {
        let key = normalizedModelID(model)
        if let exact = prices[key] { return exact }
        guard let snapshotBase = snapshotBaseModelID(key) else { return nil }
        return prices[snapshotBase]
    }

    static func mergedPrices(overrides: [String: Price]) -> [String: Price] {
        builtInPrices.merging(overrides) { _, remote in remote }
    }

    static func isCompatibleCacheVersion(_ value: String) -> Bool {
        value == version || value.hasPrefix("openai-docs-")
    }

    public static func cost(model: String, usage: TokenUsage) -> Decimal? {
        guard let price = price(for: model) else { return nil }
        return cost(usage: usage, price: price)
    }

    static func cost(model: String, totals: ApiEquivalentTotals) -> Decimal? {
        guard let price = price(for: model) else { return nil }
        return cost(totals: totals, price: price)
    }

    static func equivalentCost(totals: ApiEquivalentTotals) -> Decimal {
        cost(totals: totals, price: equivalentPrice)
    }

    static var equivalentPrice: Price {
        builtInPrices["gpt-5.6-sol"]!
    }

    private static func normalizedModelID(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func snapshotBaseModelID(_ model: String) -> String? {
        let suffixPattern = #"-\d{4}-\d{2}-\d{2}$"#
        guard let range = model.range(of: suffixPattern, options: .regularExpression) else {
            return nil
        }
        return String(model[..<range.lowerBound])
    }

    private static func cost(usage: TokenUsage, price: Price) -> Decimal {
        return Decimal(usage.inputTokens - usage.cachedInputTokens) / 1_000_000 * price.inputPerMillion
            + Decimal(usage.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
            + Decimal(usage.outputTokens) / 1_000_000 * price.outputPerMillion
    }

    private static func cost(totals: ApiEquivalentTotals, price: Price) -> Decimal {
        Decimal(totals.uncachedInputTokens) / 1_000_000 * price.inputPerMillion
            + Decimal(totals.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
            + Decimal(totals.outputTokens) / 1_000_000 * price.outputPerMillion
    }
}
