import Foundation
import Testing
@testable import CodexRunwayCore

let fixedNow = parseDate("2026-06-30T12:00:00Z")

final class RepositoryFixture {
    let root: URL
    let codexHome: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        codexHome = root.appending(path: ".codex", directoryHint: .isDirectory)
        databaseURL = root.appending(path: ".codex-runway/index.sqlite3")
        try FileManager.default.createDirectory(
            at: codexHome.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: codexHome.appending(path: "archived_sessions/2026/06/29", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func repository(
        parserVersion: Int = 1,
        priceBook: UsageCostPriceBook = .current,
        calendar: Calendar = utcCalendar(),
        beforeFlight: (@Sendable () async -> Void)? = nil) -> UsageCostRepository
    {
        UsageCostRepository(
            codexHome: codexHome,
            databaseURL: databaseURL,
            parserVersion: parserVersion,
            priceBook: priceBook,
            calendar: calendar,
            beforeFlight: beforeFlight)
    }

    @discardableResult
    func write(_ contents: String, basename: String) throws -> URL {
        let file = try sessionURL(basename: basename)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func sessionURL(basename: String) throws -> URL {
        let directory = codexHome.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: basename)
    }

    func archivedURL(basename: String) throws -> URL {
        let directory = codexHome.appending(path: "archived_sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: basename)
    }
}

actor RepositoryFlightGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

func fullWindowQuery() -> ApiCostQuery {
    query(id: "full", start: "2026-06-29T00:00:00Z", end: "2026-06-30T00:00:00Z")
}

func query(id: String, start: String, end: String) -> ApiCostQuery {
    ApiCostQuery(
        id: id,
        window: DateInterval(start: parseDate(start), end: parseDate(end)))
}

func tokenLine(
    timestamp: String,
    input: Int,
    cached: Int = 0,
    output: Int = 5,
    model: String = "gpt-5.5") -> String
{
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":0}}},"turn_context":{"model":"\(model)"}}
    """
}

func taskCompleteLine(timestamp: String, turnID: String = "turn-1") -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnID)"}}
    """
}

func append(_ text: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.synchronize()
}

func replacePreservingIdentity(_ contents: String, at file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    let data = Data(contents.utf8)
    try handle.write(contentsOf: data)
    try handle.truncate(atOffset: UInt64(data.count))
    try handle.synchronize()
}

func fileIdentity(_ file: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

func priceBook(
    version: String,
    input: Decimal,
    cached: Decimal,
    output: Decimal) -> UsageCostPriceBook
{
    let price = PricingTable.Price(
        inputPerMillion: input,
        cachedInputPerMillion: cached,
        outputPerMillion: output)
    return UsageCostPriceBook(
        version: version,
        priceForModel: { _ in price },
        equivalentPrice: price)
}

func parseDate(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: text) else {
        preconditionFailure("Invalid test timestamp: \(text)")
    }
    return date
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
