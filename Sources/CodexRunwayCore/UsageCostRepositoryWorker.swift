import Foundation
import SQLite3

actor UsageCostRepositoryWorker {
    static let currentParserVersion = 3

    private let codexHome: URL
    private let databaseURL: URL
    private let parserVersion: Int
    private let priceBook: UsageCostPriceBook
    private let calendar: Calendar
    private var store: UsageCostIndexStore?
    private var diagnostics = UsageCostRepositoryDiagnostics()
    private var activeScans = 0

    init(
        codexHome: URL,
        databaseURL: URL,
        parserVersion: Int,
        priceBook: UsageCostPriceBook,
        calendar: Calendar)
    {
        self.codexHome = codexHome
        self.databaseURL = databaseURL
        self.parserVersion = parserVersion
        self.priceBook = priceBook
        self.calendar = calendar
    }

    func summaries(
        for queries: [ApiCostQuery],
        calculatedAt: Date,
        policy: UsageCostRefreshPolicy,
        progress: CostScanProgressReporter? = nil
    ) throws -> [String: ApiEquivalentSummary] {
        try Task.checkCancellation()
        activeScans += 1
        diagnostics.maxConcurrentScans = max(diagnostics.maxConcurrentScans, activeScans)
        defer { activeScans -= 1 }

        do {
            return try calculateSummaries(
                queries: queries,
                calculatedAt: calculatedAt,
                policy: policy,
                progress: progress)
        } catch {
            guard try shouldRebuild(after: error) else { throw error }
            let rebuilt = try rebuildStore(reason: "database-corrupt")
            return try calculateSummaries(
                queries: queries,
                calculatedAt: calculatedAt,
                policy: policy,
                opened: rebuilt,
                progress: progress)
        }
    }

    func diagnosticsSnapshot() -> UsageCostRepositoryDiagnostics {
        diagnostics
    }

    private func calculateSummaries(
        queries: [ApiCostQuery],
        calculatedAt: Date,
        policy: UsageCostRefreshPolicy,
        opened suppliedStore: (store: UsageCostIndexStore, warnings: [String])? = nil,
        progress: CostScanProgressReporter? = nil
    ) throws -> [String: ApiEquivalentSummary] {
        try Task.checkCancellation()
        progress?.report(.preparing, force: true)
        let opened = try suppliedStore ?? openStore()
        let refreshWarnings = try UsageCostIndexRefresher(
            codexHome: codexHome,
            store: opened.store,
            parserVersion: parserVersion,
            calendar: calendar)
            .refresh(policy: policy, diagnostics: &diagnostics, progress: progress)
        try opened.store.validateEventStorage()
        let warnings = opened.warnings + refreshWarnings
        var result = [String: ApiEquivalentSummary](minimumCapacity: queries.count)
        let totalQueries = queries.count
        for (index, query) in queries.enumerated() {
            try Task.checkCancellation()
            progress?.report(.aggregating(completed: index, total: totalQueries), force: true)
            let events = try opened.store.events(in: query.window)
            try Task.checkCancellation()
            result[query.id] = try UsageCostSummaryBuilder.make(
                events: events,
                window: query.window,
                calculatedAt: calculatedAt,
                priceBook: priceBook,
                warnings: warnings)
        }
        if totalQueries > 0 {
            progress?.report(.aggregating(completed: totalQueries, total: totalQueries), force: true)
        }
        try Task.checkCancellation()
        return result
    }

    private func openStore() throws -> (store: UsageCostIndexStore, warnings: [String]) {
        let currentTimeZoneIdentifier = calendar.timeZone.identifier
        if let store {
            guard store.timeZoneIdentifier != currentTimeZoneIdentifier else {
                return (store, [])
            }
            self.store = nil
            return try rebuildStore(reason: "time-zone")
        }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            let opened = try UsageCostIndexStore(
                url: databaseURL,
                parserVersion: parserVersion,
                timeZoneIdentifier: currentTimeZoneIdentifier)
            store = opened
            return (opened, [])
        } catch let error as UsageCostIndexStoreError {
            switch error {
            case .schemaVersionMismatch:
                return try rebuildStore(reason: "schema-version")
            case .parserVersionMismatch:
                return try rebuildStore(reason: "parser-version")
            case .timeZoneMismatch:
                return try rebuildStore(reason: "time-zone")
            case .corruptRow:
                return try rebuildStore(reason: "database-corrupt")
            default:
                throw error
            }
        } catch let error as SQLiteError where Self.isUnambiguousCorruption(error) {
            return try rebuildStore(reason: "database-corrupt")
        }
    }

    private func rebuildStore(reason: String) throws -> (store: UsageCostIndexStore, warnings: [String]) {
        store = nil
        for url in databaseFiles() where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let rebuilt = try UsageCostIndexStore(
            url: databaseURL,
            parserVersion: parserVersion,
            timeZoneIdentifier: calendar.timeZone.identifier)
        store = rebuilt
        diagnostics.databaseRebuilds += 1
        return (rebuilt, ["usage-index-rebuilt:\(reason)"])
    }

    private func shouldRebuild(after error: any Error) throws -> Bool {
        if let storeError = error as? UsageCostIndexStoreError {
            switch storeError {
            case .schemaVersionMismatch, .parserVersionMismatch, .timeZoneMismatch, .corruptRow:
                return true
            default:
                return false
            }
        }
        if let rollback = error as? SQLiteRollbackError {
            return try shouldRebuild(after: rollback.primary)
                || Self.isUnambiguousCorruption(rollback.rollback)
        }
        guard let sqliteError = error as? SQLiteError else { return false }
        if Self.isUnambiguousCorruption(sqliteError) { return true }
        guard sqliteError.code & 0xFF == SQLITE_ERROR || sqliteError.code & 0xFF == SQLITE_SCHEMA,
              let store
        else { return false }
        do {
            return try !store.storageIsValid()
        } catch let validationError as SQLiteError
            where Self.isUnambiguousCorruption(validationError)
        {
            return true
        }
    }

    private func databaseFiles() -> [URL] {
        [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            databaseURL,
        ]
    }

    private static func isUnambiguousCorruption(_ error: SQLiteError) -> Bool {
        let primaryCode = error.code & 0xFF
        return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }
}
