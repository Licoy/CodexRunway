import Foundation

enum OpenAIPricingCatalogError: Error, Equatable {
    case invalidResponse
    case invalidStatus(Int)
    case invalidMarkdown
    case emptyCatalog
}

struct OpenAIPricingHTTPResponse: Sendable {
    var statusCode: Int
    var data: Data
    var eTag: String?
    var lastModified: String?
}

typealias OpenAIPricingFetcher = @Sendable (_ eTag: String?) async throws -> OpenAIPricingHTTPResponse

enum OpenAIPricingMarkdownParser {
    private static let standardHeading = "### Standard pricing data"

    static func parseStandardPrices(_ markdown: String) throws -> [String: PricingTable.Price] {
        var insideStandardTable = false
        var sawHeader = false
        var result: [String: PricingTable.Price] = [:]

        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == standardHeading {
                insideStandardTable = true
                continue
            }
            guard insideStandardTable else { continue }
            if line.hasPrefix("### ") { break }
            guard line.hasPrefix("|") else { continue }

            let cells = tableCells(line)
            guard cells.count == 9 else { continue }
            if cells[0] == "Model" {
                sawHeader = true
                continue
            }
            if cells[0].allSatisfy({ $0 == "-" || $0 == ":" }) { continue }
            guard sawHeader else { continue }

            let model = normalizedModelID(cells[0])
            guard isCodexCompatibleModelID(model),
                  let input = decimal(cells[1]),
                  let output = decimal(cells[4])
            else { continue }
            let cached = decimal(cells[2]) ?? input
            let price = PricingTable.Price(
                inputPerMillion: input,
                cachedInputPerMillion: cached,
                cacheWritePerMillion: decimal(cells[3]),
                outputPerMillion: output,
                longContextInputPerMillion: decimal(cells[5]),
                longContextCachedInputPerMillion: decimal(cells[6]),
                longContextCacheWritePerMillion: decimal(cells[7]),
                longContextOutputPerMillion: decimal(cells[8]))
            guard valid(price) else { throw OpenAIPricingCatalogError.invalidMarkdown }
            result[model] = price
        }

        guard insideStandardTable, sawHeader else {
            throw OpenAIPricingCatalogError.invalidMarkdown
        }
        guard !result.isEmpty else { throw OpenAIPricingCatalogError.emptyCatalog }
        return result
    }

    private static func tableCells(_ line: String) -> [String] {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return [] }
        return parts.dropFirst().dropLast().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func normalizedModelID(_ value: String) -> String {
        let withoutContextNote = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? value
        return withoutContextNote.lowercased()
    }

    private static func isCodexCompatibleModelID(_ value: String) -> Bool {
        value.hasPrefix("gpt-") || value.hasPrefix("codex-")
    }

    private static func decimal(_ value: String) -> Decimal? {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != "-", !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func valid(_ price: PricingTable.Price) -> Bool {
        let values = [
            price.inputPerMillion,
            price.cachedInputPerMillion,
            price.cacheWritePerMillion,
            price.outputPerMillion,
            price.longContextInputPerMillion,
            price.longContextCachedInputPerMillion,
            price.longContextCacheWritePerMillion,
            price.longContextOutputPerMillion,
        ].compactMap { $0 }
        return !values.isEmpty && values.allSatisfy { $0 >= 0 && $0 <= 10_000 }
    }
}

actor OpenAIPricingCatalogProvider {
    static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60

    private struct Cache: Codable, Sendable {
        var schemaVersion: Int
        var sourceURL: String
        var fetchedAt: Date
        var eTag: String?
        var lastModified: String?
        var prices: [String: PricingTable.Price]

        var priceBook: UsageCostPriceBook {
            let merged = PricingTable.mergedPrices(overrides: prices)
            let fallback = PricingTable.price(for: "gpt-5.6-sol", in: merged)
                ?? PricingTable.equivalentPrice
            return UsageCostPriceBook(
                version: pricingVersion,
                priceForModel: { model in PricingTable.price(for: model, in: merged) },
                equivalentPrice: fallback)
        }

        private var pricingVersion: String {
            let source = eTag ?? lastModified ?? ISO8601DateFormatter().string(from: fetchedAt)
            let token = source.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
            }
            let compact = String(token).replacingOccurrences(
                of: #"-+"#,
                with: "-",
                options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return "openai-docs-\(compact.prefix(48))"
        }
    }

    private let cacheURL: URL
    private let refreshInterval: TimeInterval
    private let fetch: OpenAIPricingFetcher
    private var cache: Cache?

    init(
        cacheURL: URL = OpenAIPricingCatalogProvider.defaultCacheURL,
        refreshInterval: TimeInterval = OpenAIPricingCatalogProvider.defaultRefreshInterval,
        fetch: @escaping OpenAIPricingFetcher = OpenAIPricingCatalogProvider.fetchOfficialPricing)
    {
        self.cacheURL = cacheURL
        self.refreshInterval = refreshInterval
        self.fetch = fetch
        cache = Self.loadCache(from: cacheURL)
    }

    func priceBook(now: Date = Date()) async -> UsageCostPriceBook {
        if let cache, now.timeIntervalSince(cache.fetchedAt) < refreshInterval {
            return cache.priceBook
        }

        do {
            let response = try await fetch(cache?.eTag)
            if response.statusCode == 304, var cache {
                cache.fetchedAt = now
                try save(cache)
                self.cache = cache
                return cache.priceBook
            }
            guard (200..<300).contains(response.statusCode) else {
                throw OpenAIPricingCatalogError.invalidStatus(response.statusCode)
            }
            guard let markdown = String(data: response.data, encoding: .utf8) else {
                throw OpenAIPricingCatalogError.invalidMarkdown
            }
            let prices = try OpenAIPricingMarkdownParser.parseStandardPrices(markdown)
            let updated = Cache(
                schemaVersion: 1,
                sourceURL: Self.sourceURL.absoluteString,
                fetchedAt: now,
                eTag: response.eTag,
                lastModified: response.lastModified,
                prices: prices)
            try save(updated)
            cache = updated
            return updated.priceBook
        } catch {
            return cache?.priceBook ?? .current
        }
    }

    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent("openai-pricing-v1.json")
    }

    private static func fetchOfficialPricing(eTag: String?) async throws -> OpenAIPricingHTTPResponse {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 10
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.setValue("CodexRunway/1", forHTTPHeaderField: "User-Agent")
        if let eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenAIPricingCatalogError.invalidResponse
        }
        return OpenAIPricingHTTPResponse(
            statusCode: response.statusCode,
            data: data,
            eTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    private static func loadCache(from url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(Cache.self, from: data),
              cache.schemaVersion == 1,
              cache.sourceURL == sourceURL.absoluteString,
              !cache.prices.isEmpty
        else { return nil }
        return cache
    }

    private func save(_ cache: Cache) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: cacheURL, options: .atomic)
    }
}
