import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("OpenAI pricing catalog")
struct OpenAIPricingCatalogTests {
    @Test("parses the official Standard pricing Markdown table")
    func parsesStandardPricingTable() throws {
        let prices = try OpenAIPricingMarkdownParser.parseStandardPrices(Self.markdown)
        let astra = try #require(prices["gpt-6-astra"])
        let sol = try #require(prices["gpt-5.6-sol"])
        let terra = try #require(prices["gpt-5.6-terra"])

        #expect(astra.inputPerMillion == 10)
        #expect(astra.cachedInputPerMillion == 1)
        #expect(astra.cacheWritePerMillion == 12.5)
        #expect(astra.outputPerMillion == 50)
        #expect(astra.longContextInputPerMillion == 20)
        #expect(astra.longContextCachedInputPerMillion == 2)
        #expect(astra.longContextCacheWritePerMillion == 25)
        #expect(astra.longContextOutputPerMillion == 75)
        #expect(sol.inputPerMillion == 5)
        #expect(sol.cachedInputPerMillion == 0.5)
        #expect(sol.cacheWritePerMillion == 6.25)
        #expect(sol.outputPerMillion == 30)
        #expect(sol.longContextInputPerMillion == 10)
        #expect(sol.longContextOutputPerMillion == 45)
        #expect(terra.inputPerMillion == 2)
        #expect(prices["unrelated-provider"] == nil)
    }

    @Test("uses a downloaded catalog and writes a last-known-good cache")
    func downloadsAndCachesCatalog() async throws {
        let directory = try PricingTestDirectory()
        let cacheURL = directory.url.appendingPathComponent("pricing.json")
        let now = Date(timeIntervalSince1970: 1_786_579_200)
        let provider = OpenAIPricingCatalogProvider(
            cacheURL: cacheURL,
            refreshInterval: 0,
            fetch: { _ in
                OpenAIPricingHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.markdown.replacingOccurrences(
                        of: "| gpt-6-astra | $10.00 |",
                        with: "| gpt-6-astra | $12.00 |").utf8),
                    eTag: #""official-etag""#,
                    lastModified: "Thu, 13 Aug 2026 04:57:43 GMT")
            })

        let priceBook = await provider.priceBook(now: now)
        let oneMillionInput = ApiEquivalentTotals(
            totalTokens: 1_000_000,
            uncachedInputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            turns: 1,
            threads: 0)

        #expect(priceBook.version.hasPrefix("openai-docs-"))
        #expect(priceBook.cost(model: "gpt-5.6-terra", totals: oneMillionInput) == 2)
        #expect(priceBook.cost(model: "gpt-6-astra", totals: oneMillionInput) == 12)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("bundled Astra pricing works offline with no cache or a pre-Astra cache", arguments: [false, true])
    func bundledAstraOfflineFallback(useOlderCache: Bool) async throws {
        let directory = try PricingTestDirectory()
        let cacheURL = directory.url.appendingPathComponent("pricing.json")
        let fetchedAt = Date(timeIntervalSince1970: 1_786_579_200)
        if useOlderCache {
            let olderMarkdown = Self.markdown.split(separator: "\n")
                .filter { !$0.contains("| gpt-6-astra |") }
                .joined(separator: "\n")
            let initial = OpenAIPricingCatalogProvider(
                cacheURL: cacheURL,
                fetch: { _ in
                    OpenAIPricingHTTPResponse(
                        statusCode: 200,
                        data: Data(olderMarkdown.utf8),
                        eTag: nil,
                        lastModified: nil)
                })
            _ = await initial.priceBook(now: fetchedAt)
            #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        }

        let offline = OpenAIPricingCatalogProvider(
            cacheURL: cacheURL,
            fetch: { _ in throw URLError(.notConnectedToInternet) })
        let priceBook = await offline.priceBook(now: fetchedAt.addingTimeInterval(86_400))
        let totals = ApiEquivalentTotals(
            totalTokens: 11_000,
            uncachedInputTokens: 8_000,
            cachedInputTokens: 2_000,
            outputTokens: 1_000,
            turns: 1,
            threads: 1)

        #expect(priceBook.cost(model: "gpt-6-astra", totals: totals) == Decimal(string: "0.132"))
    }

    @Test("falls back to the cached catalog when refresh fails")
    func staleCacheFallback() async throws {
        let directory = try PricingTestDirectory()
        let cacheURL = directory.url.appendingPathComponent("pricing.json")
        let fetchedAt = Date(timeIntervalSince1970: 1_786_579_200)
        let initial = OpenAIPricingCatalogProvider(
            cacheURL: cacheURL,
            refreshInterval: 0,
            fetch: { _ in
                OpenAIPricingHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.markdown.utf8),
                    eTag: #""cached-etag""#,
                    lastModified: nil)
            })
        _ = await initial.priceBook(now: fetchedAt)

        let offline = OpenAIPricingCatalogProvider(
            cacheURL: cacheURL,
            refreshInterval: 0,
            fetch: { _ in throw URLError(.notConnectedToInternet) })
        let priceBook = await offline.priceBook(now: fetchedAt.addingTimeInterval(86_400))

        #expect(priceBook.version.hasPrefix("openai-docs-"))
        #expect(priceBook.priceForModel("gpt-5.6-sol")?.inputPerMillion == 5)
    }

    @Test("bundled lookup is exact except for dated snapshots")
    func exactModelLookup() {
        #expect(PricingTable.price(for: "gpt-6") == nil)
        #expect(PricingTable.price(for: "gpt-6-astra-mini") == nil)
        #expect(PricingTable.price(for: "gpt-5.6-sol")?.inputPerMillion == 5)
        #expect(PricingTable.price(for: "gpt-5.6-sol-2026-08-13")?.inputPerMillion == 5)
        #expect(PricingTable.price(for: "gpt-5.6-solstice") == nil)
        #expect(PricingTable.price(for: "gpt-5.5-pro")?.inputPerMillion == 30)
        #expect(PricingTable.price(for: "gpt-5.3-codex-spark")?.inputPerMillion == 1.75)
        #expect(PricingTable.price(for: "gpt-5.3-codex-spark")?.cachedInputPerMillion == 0.175)
        #expect(PricingTable.price(for: "gpt-5.3-codex-spark")?.outputPerMillion == 14)
    }

    private static let markdown = """
    # Pricing

    ### Standard pricing data

    | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | gpt-6-astra | $10.00 | $1.00 | $12.50 | $50.00 | $20.00 | $2.00 | $25.00 | $75.00 |
    | gpt-5.6-sol | $5.00 | $0.50 | $6.25 | $30.00 | $10.00 | $1.00 | $12.50 | $45.00 |
    | gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |
    | unrelated-provider | $1.00 | $0.10 | - | $2.00 | - | - | - | - |

    ### Batch pricing data

    | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | gpt-6-astra | $5.00 | $0.50 | $6.25 | $25.00 | $10.00 | $1.00 | $12.50 | $37.50 |
    | gpt-5.6-sol | $2.50 | $0.25 | $3.125 | $15.00 | $5.00 | $0.50 | $6.25 | $22.50 |
    """
}

private final class PricingTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
