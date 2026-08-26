import Foundation

public struct QuotaEstimateHistoryStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load(accountKey: String) -> [QuotaEstimateHistorySample] {
        Self.normalized(loadFile().accounts[accountKey] ?? [])
    }

    public func upsert(accountKey: String, sample: QuotaEstimateHistorySample) -> [QuotaEstimateHistorySample] {
        var payload = loadFile()
        let samples = Self.merging(payload.accounts[accountKey] ?? [], sample)
        payload.accounts[accountKey] = samples
        save(payload)
        return samples
    }

    public static func normalized(_ samples: [QuotaEstimateHistorySample]) -> [QuotaEstimateHistorySample] {
        var latest: [String: QuotaEstimateHistorySample] = [:]
        for sample in samples {
            if let existing = latest[sample.cycleStartDate], sample.recordedAt < existing.recordedAt {
                continue
            }
            latest[sample.cycleStartDate] = sample
        }
        return latest.values
            .sorted { $0.cycleStartDate < $1.cycleStartDate }
            .suffix(QuotaEstimatePricing.maxHistorySamples)
            .map { $0 }
    }

    public static func merging(
        _ samples: [QuotaEstimateHistorySample],
        _ sample: QuotaEstimateHistorySample) -> [QuotaEstimateHistorySample]
    {
        normalized(samples + [sample])
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent("quota-estimate-history.json")
    }

    private struct FilePayload: Codable {
        var accounts: [String: [QuotaEstimateHistorySample]]
    }

    private func loadFile() -> FilePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? decoder.decode(FilePayload.self, from: data)
        else { return FilePayload(accounts: [:]) }
        return payload
    }

    private func save(_ payload: FilePayload) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort derived cache; never fail a quota refresh.
        }
    }
}
