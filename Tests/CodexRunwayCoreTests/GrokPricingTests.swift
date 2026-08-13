import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok API pricing")
struct GrokPricingTests {
    @Test("resolves official model IDs and CLI product aliases")
    func resolvesOfficialAndCLIAliases() {
        #expect(GrokPricingTable.price(for: "grok-4.5")?.cachedInputPerMillion == Decimal(string: "0.30"))
        #expect(GrokPricingTable.price(for: "grok-4.5-build")?.cachedInputPerMillion == Decimal(string: "0.30"))
        #expect(GrokPricingTable.price(for: "grok-4.5-build-free")?.cachedInputPerMillion == Decimal(string: "0.30"))
        #expect(GrokPricingTable.price(for: "grok-4.5-latest")?.outputPerMillion == 6)
        #expect(GrokPricingTable.price(for: "grok-4.5-2026-07-08")?.inputPerMillion == 2)
        #expect(GrokPricingTable.price(for: "grok-4.6-build")?.cachedInputPerMillion == Decimal(string: "0.50"))
        #expect(GrokPricingTable.price(for: "grok-4.3")?.inputPerMillion == Decimal(string: "1.25"))
        #expect(GrokPricingTable.price(for: "grok-4.20-0309-reasoning")?.outputPerMillion == Decimal(string: "2.50"))
        #expect(GrokPricingTable.price(for: "grok-build-0.1")?.inputPerMillion == 1)
        #expect(GrokPricingTable.price(for: "unknown-model") == nil)
        #expect(GrokPricingTable.price(for: "grok") == nil)
        #expect(GrokPricingTable.version == "xai-builtin-2026-08-13")
    }

    @Test("prices a short-context grok-4.5 request")
    func pricesShortContext() {
        let cost = GrokPricingTable.cost(
            model: "grok-4.5-build",
            inputTokens: 1_000,
            cachedInputTokens: 400,
            outputTokens: 200)
        // 600 * $2 + 400 * $0.30 + 200 * $6 per million
        #expect(cost == Decimal(string: "0.00252"))
    }

    @Test("applies long-context rates when prompt reaches 200k")
    func appliesLongContextThreshold() {
        let short = GrokPricingTable.cost(
            model: "grok-4.5",
            inputTokens: 199_999,
            cachedInputTokens: 0,
            outputTokens: 0)
        let long = GrokPricingTable.cost(
            model: "grok-4.5",
            inputTokens: 200_000,
            cachedInputTokens: 0,
            outputTokens: 0)
        #expect(short == Decimal(string: "0.399998"))
        #expect(long == Decimal(string: "0.8"))
        let longCached = GrokPricingTable.cost(
            model: "grok-4.6",
            inputTokens: 200_000,
            cachedInputTokens: 200_000,
            outputTokens: 0)
        #expect(longCached == Decimal(string: "0.2"))
    }

    @Test("does not invent a price for unknown models")
    func unknownModelIsUnpriced() {
        #expect(
            GrokPricingTable.cost(
                model: "mystery-model",
                inputTokens: 10_000,
                cachedInputTokens: 0,
                outputTokens: 100) == nil)
    }
}
