import Foundation

public struct UsageCostCacheStore: Sendable {
    public var cacheURL: URL

    public init(cacheURL: URL = Self.defaultCacheURL) {
        self.cacheURL = cacheURL
    }

    public func load() -> ApiEquivalentSummary? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let summary = try? decoder.decode(ApiEquivalentSummary.self, from: data),
              PricingTable.isCompatibleCacheVersion(summary.pricingVersion)
        else {
            return nil
        }
        return summary
    }

    public func save(_ summary: ApiEquivalentSummary) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try data.write(to: cacheURL, options: .atomic)
    }

    public static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent("api-equivalent-cost.json")
    }
}
