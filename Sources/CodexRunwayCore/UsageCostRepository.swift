import Foundation

public enum UsageCostDayBoundary: Sendable, Hashable {
    case local
    case utc
}

public struct ApiCostQuery: Sendable, Hashable {
    public let id: String
    public let window: DateInterval
    public let dayBoundary: UsageCostDayBoundary

    public init(
        id: String,
        window: DateInterval,
        dayBoundary: UsageCostDayBoundary = .local)
    {
        self.id = id
        self.window = window
        self.dayBoundary = dayBoundary
    }
}

public enum UsageCostRefreshPolicy: Sendable, Hashable {
    case ifChanged
    case force
}

enum UsageCostRepositoryError: Error, Equatable, Sendable {
    case duplicateConflict(basename: String)
    case duplicateQueryID(String)
    case invalidQueryWindow(String)
}

struct UsageCostPriceBook: Sendable {
    let version: String
    let priceForModel: @Sendable (String) -> PricingTable.Price?
    let equivalentPrice: PricingTable.Price

    init(
        version: String,
        priceForModel: @escaping @Sendable (String) -> PricingTable.Price?,
        equivalentPrice: PricingTable.Price)
    {
        self.version = version
        self.priceForModel = priceForModel
        self.equivalentPrice = equivalentPrice
    }

    static let current = UsageCostPriceBook(
        version: PricingTable.version,
        priceForModel: PricingTable.price,
        equivalentPrice: PricingTable.equivalentPrice)

    func cost(model: String, totals: ApiEquivalentTotals) -> Decimal? {
        priceForModel(model).map { cost(totals: totals, price: $0) }
    }

    func equivalentCost(totals: ApiEquivalentTotals) -> Decimal {
        cost(totals: totals, price: equivalentPrice)
    }

    private func cost(totals: ApiEquivalentTotals, price: PricingTable.Price) -> Decimal {
        Decimal(totals.uncachedInputTokens) / 1_000_000 * price.inputPerMillion
            + Decimal(totals.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
            + Decimal(totals.outputTokens) / 1_000_000 * price.outputPerMillion
    }
}

struct UsageCostRepositoryDiagnostics: Equatable, Sendable {
    var bytesRead = 0
    var validationBytesRead = 0
    var candidateLines = 0
    var decodedLines = 0
    var malformedCandidateLines = 0
    var oversizedLines = 0
    var maxBufferedBytes = 0
    var rebuiltFiles = 0
    var indexPasses = 0
    var cacheHits = 0
    var appendedFiles = 0
    var incompleteTailFiles = 0
    var adoptedFiles = 0
    var duplicateFiles = 0
    var removedFiles = 0
    var databaseRebuilds = 0
    var maxConcurrentScans = 0
    var sharedFlightHits = 0
    var cancelledFlights = 0
}

public actor UsageCostRepository {
    private typealias Summaries = [String: ApiEquivalentSummary]

    private struct RequestKey: Sendable, Hashable {
        var queries: [ApiCostQuery]
        var calculatedAt: Date
        var policy: UsageCostRefreshPolicy
        var pricingVersion: String
    }

    private struct Flight {
        var id: UUID
        var task: Task<Summaries, any Error>
        var waiters: Set<UUID>
    }

    private let worker: UsageCostRepositoryWorker
    private let pricingProvider: OpenAIPricingCatalogProvider?
    private let fixedPriceBook: UsageCostPriceBook
    private let beforeFlight: (@Sendable () async -> Void)?
    private var inFlight: [RequestKey: Flight] = [:]
    private var sharedFlightHits = 0
    private var cancelledFlights = 0

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true))
    {
        worker = UsageCostRepositoryWorker(
            codexHome: codexHome,
            databaseURL: Self.defaultDatabaseURL,
            parserVersion: UsageCostRepositoryWorker.currentParserVersion,
            calendar: .autoupdatingCurrent)
        pricingProvider = OpenAIPricingCatalogProvider()
        fixedPriceBook = .current
        beforeFlight = nil
    }

    @_spi(Benchmark)
    public init(codexHome: URL, databaseURL: URL) {
        worker = UsageCostRepositoryWorker(
            codexHome: codexHome,
            databaseURL: databaseURL,
            parserVersion: UsageCostRepositoryWorker.currentParserVersion,
            calendar: .autoupdatingCurrent)
        pricingProvider = nil
        fixedPriceBook = .current
        beforeFlight = nil
    }

    init(
        codexHome: URL,
        databaseURL: URL,
        parserVersion: Int,
        priceBook: UsageCostPriceBook,
        calendar: Calendar = .autoupdatingCurrent,
        beforeFlight: (@Sendable () async -> Void)? = nil)
    {
        worker = UsageCostRepositoryWorker(
            codexHome: codexHome,
            databaseURL: databaseURL,
            parserVersion: parserVersion,
            calendar: calendar)
        pricingProvider = nil
        fixedPriceBook = priceBook
        self.beforeFlight = beforeFlight
    }

    public func summaries(
        for queries: [ApiCostQuery],
        calculatedAt: Date,
        policy: UsageCostRefreshPolicy,
        progress: CostScanProgressReporter? = nil
    ) async throws -> [String: ApiEquivalentSummary] {
        try Task.checkCancellation()
        guard !queries.isEmpty else { return [:] }
        try Self.validateQueries(queries)
        let priceBook: UsageCostPriceBook
        if let pricingProvider {
            priceBook = await pricingProvider.priceBook()
        } else {
            priceBook = fixedPriceBook
        }
        let canonicalQueries = queries.sorted(by: Self.queryOrder)
        let key = RequestKey(
            queries: canonicalQueries,
            calculatedAt: calculatedAt,
            policy: policy,
            pricingVersion: priceBook.version)

        let waiterID = UUID()
        let flight: Flight
        if var existing = inFlight[key] {
            sharedFlightHits += 1
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            flight = existing
            // Shared flights already report through the creator's progress sink.
            progress?.report(.preparing, force: true)
        } else {
            let task = Task { [worker, beforeFlight] in
                if let beforeFlight { await beforeFlight() }
                try Task.checkCancellation()
                return try await worker.summaries(
                    for: canonicalQueries,
                    calculatedAt: calculatedAt,
                    policy: policy,
                    priceBook: priceBook,
                    progress: progress)
            }
            flight = Flight(id: UUID(), task: task, waiters: [waiterID])
            inFlight[key] = flight
        }

        return try await withTaskCancellationHandler {
            do {
                let summaries = try await flight.task.value
                try Task.checkCancellation()
                finishWaiter(key: key, flightID: flight.id, waiterID: waiterID)
                return summaries
            } catch {
                finishWaiter(key: key, flightID: flight.id, waiterID: waiterID)
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key,
                    flightID: flight.id,
                    waiterID: waiterID)
            }
        }
    }

    func diagnosticsSnapshot() async -> UsageCostRepositoryDiagnostics {
        var snapshot = await worker.diagnosticsSnapshot()
        snapshot.sharedFlightHits = sharedFlightHits
        snapshot.cancelledFlights = cancelledFlights
        return snapshot
    }

    private func finishWaiter(key: RequestKey, flightID: UUID, waiterID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        if flight.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = flight
        }
    }

    private func cancelWaiter(key: RequestKey, flightID: UUID, waiterID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight.removeValue(forKey: key)
            cancelledFlights += 1
        } else {
            inFlight[key] = flight
        }
    }

    private static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/usage-cost-index-v1.sqlite3")
    }

    private static func validateQueries(_ queries: [ApiCostQuery]) throws {
        var identifiers = Set<String>()
        for query in queries {
            guard query.window.start.timeIntervalSince1970.isFinite,
                  query.window.end.timeIntervalSince1970.isFinite
            else { throw UsageCostRepositoryError.invalidQueryWindow(query.id) }
            guard identifiers.insert(query.id).inserted else {
                throw UsageCostRepositoryError.duplicateQueryID(query.id)
            }
        }
    }

    private static func queryOrder(_ lhs: ApiCostQuery, _ rhs: ApiCostQuery) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.window.start != rhs.window.start { return lhs.window.start < rhs.window.start }
        return lhs.window.end < rhs.window.end
    }
}
