import Foundation

enum UsageCostSummaryBuilder {
    static func make(
        events: [UsageCostIndexedEvent],
        window: DateInterval,
        calculatedAt: Date,
        priceBook: UsageCostPriceBook,
        warnings: [String] = []
    ) throws -> ApiEquivalentSummary {
        let groups = try group(events)
        let modelRows = modelRows(groups.byModel, priceBook: priceBook)
        let totals = try ApiEquivalentTotals.sum(groups.byDay.values)
        let unknownModels = groups.byModel.keys
            .filter { priceBook.priceForModel($0) == nil }
            .sorted()
        let estimatedUSD = estimatedCost(byModel: groups.byModel, priceBook: priceBook)
        let confidence: ApiEquivalentConfidence
        if totals.totalTokens == 0 {
            confidence = .unavailable
        } else if estimatedUSD == nil {
            confidence = .tokensOnly
        } else {
            confidence = .priced
        }
        return ApiEquivalentSummary(
            source: totals.totalTokens > 0 ? .localSessions : .unavailable,
            confidence: confidence,
            window: window,
            estimatedUSD: estimatedUSD,
            totals: totals,
            dailyRows: dailyRows(groups, priceBook: priceBook),
            modelRows: modelRows,
            projectRows: try projectRows(groups.byProjectModel, priceBook: priceBook),
            clientRows: [],
            rawCredits: 0,
            warnings: unknownModels.map { "unknown-model:\($0)" } + warnings,
            pricingVersion: priceBook.version,
            calculatedAt: calculatedAt)
    }

    private struct Groups {
        var byModel: [String: ApiEquivalentTotals] = [:]
        var byProjectModel: [String: [String: ApiEquivalentTotals]] = [:]
        var byDay: [String: ApiEquivalentTotals] = [:]
        var byDayModel: [String: [String: ApiEquivalentTotals]] = [:]
    }

    private static func group(_ events: [UsageCostIndexedEvent]) throws -> Groups {
        var result = Groups()
        for event in events {
            let input = try checkedAdd(
                event.uncachedInputTokens,
                event.cachedInputTokens,
                field: "input tokens")
            let totals = ApiEquivalentTotals(
                totalTokens: try checkedAdd(input, event.outputTokens, field: "total tokens"),
                uncachedInputTokens: event.uncachedInputTokens,
                cachedInputTokens: event.cachedInputTokens,
                outputTokens: event.outputTokens,
                turns: event.turns,
                threads: 0)
            result.byModel[event.model, default: .zero] = try result.byModel[
                event.model,
                default: .zero
            ].adding(totals)
            result.byProjectModel[event.project, default: [:]][event.model, default: .zero] =
                try result.byProjectModel[event.project, default: [:]][event.model, default: .zero]
                    .adding(totals)
            result.byDay[event.dayKey, default: .zero] = try result.byDay[
                event.dayKey,
                default: .zero
            ].adding(totals)
            result.byDayModel[event.dayKey, default: [:]][event.model, default: .zero] =
                try result.byDayModel[event.dayKey, default: [:]][event.model, default: .zero]
                    .adding(totals)
        }
        return result
    }

    private static func modelRows(
        _ grouped: [String: ApiEquivalentTotals],
        priceBook: UsageCostPriceBook
    ) -> [ApiEquivalentBreakdownRow] {
        grouped.keys.sorted().map { model in
            let totals = grouped[model] ?? .zero
            return ApiEquivalentBreakdownRow(
                name: model,
                totals: totals,
                estimatedUSD: priceBook.cost(model: model, totals: totals),
                rawCredits: 0)
        }
    }

    private static func projectRows(
        _ grouped: [String: [String: ApiEquivalentTotals]],
        priceBook: UsageCostPriceBook
    ) throws -> [ApiEquivalentBreakdownRow] {
        let rows = try grouped.map { project, byModel -> ApiEquivalentBreakdownRow in
            let totals = try ApiEquivalentTotals.sum(byModel.values)
            return ApiEquivalentBreakdownRow(
                name: project,
                totals: totals,
                estimatedUSD: estimatedCost(byModel: byModel, priceBook: priceBook),
                rawCredits: 0)
        }
        return rows.sorted { lhs, rhs in
            lhs.totals.totalTokens == rhs.totals.totalTokens
                ? lhs.name < rhs.name
                : lhs.totals.totalTokens > rhs.totals.totalTokens
        }
    }

    private static func dailyRows(
        _ groups: Groups,
        priceBook: UsageCostPriceBook
    ) -> [ApiEquivalentDailyRow] {
        groups.byDay.keys.sorted().map { day in
            let totals = groups.byDay[day] ?? .zero
            return ApiEquivalentDailyRow(
                date: day,
                totals: totals,
                estimatedUSD: estimatedCost(
                    byModel: groups.byDayModel[day] ?? [:],
                    priceBook: priceBook),
                rawCredits: 0)
        }
    }

    private static func estimatedCost(
        byModel: [String: ApiEquivalentTotals],
        priceBook: UsageCostPriceBook
    ) -> Decimal? {
        var result = Decimal(0)
        var priced = false
        for item in byModel {
            guard let cost = priceBook.cost(model: item.key, totals: item.value) else {
                continue
            }
            priced = true
            result += cost
        }
        return priced ? result : nil
    }
}
