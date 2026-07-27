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
        let unknownWarnings = groups.byModel.keys
            .filter { priceBook.priceForModel($0) == nil }
            .sorted()
            .map { "unknown-model:\($0)" }
        return ApiEquivalentSummary(
            source: totals.totalTokens > 0 ? .localSessions : .unavailable,
            confidence: totals.totalTokens > 0 ? .priced : .unavailable,
            window: window,
            estimatedUSD: modelRows.compactMap(\.estimatedUSD).reduce(Decimal(0), +),
            totals: totals,
            dailyRows: dailyRows(groups, priceBook: priceBook),
            modelRows: modelRows,
            projectRows: projectRows(groups.byProject, priceBook: priceBook),
            clientRows: [],
            rawCredits: 0,
            warnings: unknownWarnings + warnings,
            pricingVersion: priceBook.version,
            calculatedAt: calculatedAt)
    }

    private struct Groups {
        var byModel: [String: ApiEquivalentTotals] = [:]
        var byProject: [String: ApiEquivalentTotals] = [:]
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
            result.byProject[event.project, default: .zero] = try result.byProject[
                event.project,
                default: .zero
            ].adding(totals)
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
                estimatedUSD: priceBook.cost(model: model, totals: totals)
                    ?? priceBook.equivalentCost(totals: totals),
                rawCredits: 0)
        }
    }

    private static func projectRows(
        _ grouped: [String: ApiEquivalentTotals],
        priceBook: UsageCostPriceBook
    ) -> [ApiEquivalentBreakdownRow] {
        grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs]?.totalTokens ?? 0
            let right = grouped[rhs]?.totalTokens ?? 0
            return left == right ? lhs < rhs : left > right
        }.map { project in
            let totals = grouped[project] ?? .zero
            return ApiEquivalentBreakdownRow(
                name: project,
                totals: totals,
                estimatedUSD: priceBook.equivalentCost(totals: totals),
                rawCredits: 0)
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
    ) -> Decimal {
        byModel.reduce(Decimal(0)) { result, item in
            result + (priceBook.cost(model: item.key, totals: item.value)
                ?? priceBook.equivalentCost(totals: item.value))
        }
    }
}
