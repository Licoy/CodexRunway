import Foundation

/// Official xAI Text API token prices for Grok API-equivalent cost.
///
/// Bundled fallback verified against https://docs.x.ai/developers/pricing
/// on 2026-08-13. Unknown model IDs are not invented as exact costs.
/// Long-context rates apply to the whole request when prompt tokens reach
/// the published threshold (200k).
public enum GrokPricingTable {
    public static let version = "xai-builtin-2026-08-13"
    public static let longContextThresholdTokens = 200_000

    public struct Price: Equatable, Sendable {
        public var inputPerMillion: Decimal
        public var cachedInputPerMillion: Decimal
        public var outputPerMillion: Decimal
        public var longContextInputPerMillion: Decimal?
        public var longContextCachedInputPerMillion: Decimal?
        public var longContextOutputPerMillion: Decimal?
        public var longContextThresholdTokens: Int

        public init(
            inputPerMillion: Decimal,
            cachedInputPerMillion: Decimal,
            outputPerMillion: Decimal,
            longContextInputPerMillion: Decimal? = nil,
            longContextCachedInputPerMillion: Decimal? = nil,
            longContextOutputPerMillion: Decimal? = nil,
            longContextThresholdTokens: Int = GrokPricingTable.longContextThresholdTokens)
        {
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.outputPerMillion = outputPerMillion
            self.longContextInputPerMillion = longContextInputPerMillion
            self.longContextCachedInputPerMillion = longContextCachedInputPerMillion
            self.longContextOutputPerMillion = longContextOutputPerMillion
            self.longContextThresholdTokens = longContextThresholdTokens
        }
    }

    static let builtInPrices: [String: Price] = [
        "grok-4.6": flagship45Family(cached: Decimal(string: "0.50")!, longCached: 1),
        "grok-4.5": flagship45Family(cached: Decimal(string: "0.30")!, longCached: Decimal(string: "0.60")!),
        "grok-4.3": midFamily,
        "grok-4.20-0309-reasoning": midFamily,
        "grok-4.20-0309-non-reasoning": midFamily,
        "grok-4.20-multi-agent-0309": midFamily,
        "grok-build-0.1": Price(
            inputPerMillion: 1,
            cachedInputPerMillion: Decimal(string: "0.20")!,
            outputPerMillion: 2,
            longContextInputPerMillion: 2,
            longContextCachedInputPerMillion: Decimal(string: "0.40")!,
            longContextOutputPerMillion: 4),
    ]

    public static func price(for model: String) -> Price? {
        price(for: model, in: builtInPrices)
    }

    static func price(for model: String, in prices: [String: Price]) -> Price? {
        var key = normalizedModelID(model)
        if key.isEmpty { return nil }
        if let exact = prices[key] { return exact }

        if key.hasSuffix("-latest") {
            key.removeLast("-latest".count)
            if let exact = prices[key] { return exact }
        }

        if let stripped = strippingProductSuffix(key), let exact = prices[stripped] {
            return exact
        }

        if let snapshot = snapshotBaseModelID(key) {
            if let exact = prices[snapshot] { return exact }
            if let stripped = strippingProductSuffix(snapshot), let exact = prices[stripped] {
                return exact
            }
        }
        return nil
    }

    /// Per-request API cost. `inputTokens` is the prompt size used for the
    /// long-context threshold. Reasoning tokens are treated as already included
    /// in `outputTokens` (CLI `reasoningTokens` is a subset, not extra).
    public static func cost(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Decimal? {
        guard let price = price(for: model) else { return nil }
        return cost(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            price: price)
    }

    public static func cost(model: String, totals: GrokUsageTotals) -> Decimal? {
        cost(
            model: model,
            inputTokens: totals.inputTokens,
            cachedInputTokens: totals.cachedReadTokens,
            outputTokens: totals.outputTokens)
    }

    static func cost(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        price: Price
    ) -> Decimal {
        let cached = max(0, cachedInputTokens)
        let uncached = max(0, inputTokens - cached)
        let output = max(0, outputTokens)
        let useLong = inputTokens >= price.longContextThresholdTokens
            && price.longContextInputPerMillion != nil
        let inputRate = useLong
            ? (price.longContextInputPerMillion ?? price.inputPerMillion)
            : price.inputPerMillion
        let cachedRate = useLong
            ? (price.longContextCachedInputPerMillion ?? price.cachedInputPerMillion)
            : price.cachedInputPerMillion
        let outputRate = useLong
            ? (price.longContextOutputPerMillion ?? price.outputPerMillion)
            : price.outputPerMillion
        return Decimal(uncached) / 1_000_000 * inputRate
            + Decimal(cached) / 1_000_000 * cachedRate
            + Decimal(output) / 1_000_000 * outputRate
    }

    private static func flagship45Family(cached: Decimal, longCached: Decimal) -> Price {
        Price(
            inputPerMillion: 2,
            cachedInputPerMillion: cached,
            outputPerMillion: 6,
            longContextInputPerMillion: 4,
            longContextCachedInputPerMillion: longCached,
            longContextOutputPerMillion: 12)
    }

    private static let midFamily = Price(
        inputPerMillion: Decimal(string: "1.25")!,
        cachedInputPerMillion: Decimal(string: "0.20")!,
        outputPerMillion: Decimal(string: "2.50")!,
        longContextInputPerMillion: Decimal(string: "2.50")!,
        longContextCachedInputPerMillion: Decimal(string: "0.40")!,
        longContextOutputPerMillion: 5)

    private static func normalizedModelID(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// CLI product SKUs such as `grok-4.5-build` share the `grok-4.5` API price.
    /// Do not strip the infix in `grok-build-0.1`.
    private static func strippingProductSuffix(_ model: String) -> String? {
        for suffix in ["-build-free", "-build"] where model.hasSuffix(suffix) {
            let base = String(model.dropLast(suffix.count))
            if !base.isEmpty, base != "grok" {
                return base
            }
        }
        return nil
    }

    private static func snapshotBaseModelID(_ model: String) -> String? {
        let suffixPattern = #"-\d{4}-\d{2}-\d{2}$"#
        guard let range = model.range(of: suffixPattern, options: .regularExpression) else {
            return nil
        }
        return String(model[..<range.lowerBound])
    }
}
