@_spi(Benchmark) import CodexRunwayCore
import Darwin
import Foundation

private struct BenchmarkOptions {
    var lines = 50_000
    var relevantEvery = 10
    var irrelevantPayloadBytes = 256
    var maximumElapsedSeconds: Double?
    var maximumWarmSeconds: Double?
    var maximumPeakRSSMiB: Double?
    var usesRepository = false
    var keepFixture = false

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--lines":
                options.lines = try integerValue(after: argument, in: arguments, index: &index)
            case "--relevant-every":
                options.relevantEvery = try integerValue(after: argument, in: arguments, index: &index)
            case "--irrelevant-payload-bytes":
                options.irrelevantPayloadBytes = try integerValue(after: argument, in: arguments, index: &index)
            case "--max-seconds":
                options.maximumElapsedSeconds = try doubleValue(after: argument, in: arguments, index: &index)
            case "--max-warm-seconds":
                options.maximumWarmSeconds = try doubleValue(after: argument, in: arguments, index: &index)
            case "--max-rss-mib":
                options.maximumPeakRSSMiB = try doubleValue(after: argument, in: arguments, index: &index)
            case "--repository":
                options.usesRepository = true
            case "--keep-fixture":
                options.keepFixture = true
            case "--help", "-h":
                printUsage()
                exit(EXIT_SUCCESS)
            default:
                throw BenchmarkError.invalidArgument("unknown argument: \(argument)")
            }
            index += 1
        }
        guard options.lines > 0 else { throw BenchmarkError.invalidArgument("--lines must be greater than zero") }
        guard options.relevantEvery > 0 else {
            throw BenchmarkError.invalidArgument("--relevant-every must be greater than zero")
        }
        guard options.irrelevantPayloadBytes >= 0 else {
            throw BenchmarkError.invalidArgument("--irrelevant-payload-bytes must not be negative")
        }
        return options
    }

    private static func integerValue(
        after option: String,
        in arguments: [String],
        index: inout Int) throws -> Int
    {
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]) else {
            throw BenchmarkError.invalidArgument("\(option) requires an integer")
        }
        return value
    }

    private static func doubleValue(
        after option: String,
        in arguments: [String],
        index: inout Int) throws -> Double
    {
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]), value >= 0 else {
            throw BenchmarkError.invalidArgument("\(option) requires a non-negative number")
        }
        return value
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case unableToCreateFixture(String)
    case thresholdExceeded(String)

    var description: String {
        switch self {
        case let .invalidArgument(message),
             let .unableToCreateFixture(message),
             let .thresholdExceeded(message):
            message
        }
    }
}

private struct Fixture {
    var codexHome: URL
    var file: URL
    var expectedTokens: Int
}

private struct Measurement {
    var summary: ApiEquivalentSummary
    var elapsed: Double
    var warmElapsed: Double?
}

@main
private enum CostScannerBenchmark {
    static func main() async {
        do {
            let options = try BenchmarkOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options: options)
        } catch {
            fail("benchmark failed: \(error)")
        }
    }

    private static func run(options: BenchmarkOptions) async throws {
        let fixture = try makeFixture(options: options)
        defer {
            if !options.keepFixture {
                try? FileManager.default.removeItem(at: fixture.codexHome)
            }
        }
        let fileBytes = try fixture.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let window = DateInterval(
            start: date("2026-07-18T00:00:00Z"),
            end: date("2026-07-19T00:00:00Z"))
        let measurement = try await measure(fixture: fixture, window: window, options: options)
        let peakRSSMiB = peakResidentMemoryMiB()

        print("fixture_bytes=\(fileBytes)")
        print(String(format: "elapsed_seconds=%.6f", measurement.elapsed))
        if let warmElapsed = measurement.warmElapsed {
            print(String(format: "warm_elapsed_seconds=%.6f", warmElapsed))
        }
        print(String(format: "peak_rss_mib=%.3f", peakRSSMiB))
        print("turns=\(measurement.summary.totals.turns)")
        print("tokens=\(measurement.summary.totals.totalTokens)")
        if options.keepFixture { print("fixture_path=\(fixture.codexHome.path)") }

        guard measurement.summary.totals.totalTokens == fixture.expectedTokens else {
            throw BenchmarkError.thresholdExceeded(
                "token count mismatch: expected \(fixture.expectedTokens), got \(measurement.summary.totals.totalTokens)")
        }
        if let limit = options.maximumElapsedSeconds, measurement.elapsed > limit {
            throw BenchmarkError.thresholdExceeded(
                String(format: "elapsed %.6fs exceeded %.6fs", measurement.elapsed, limit))
        }
        if let limit = options.maximumWarmSeconds,
           let warmElapsed = measurement.warmElapsed,
           warmElapsed > limit
        {
            throw BenchmarkError.thresholdExceeded(
                String(format: "warm elapsed %.6fs exceeded %.6fs", warmElapsed, limit))
        }
        if let limit = options.maximumPeakRSSMiB, peakRSSMiB > limit {
            throw BenchmarkError.thresholdExceeded(
                String(format: "peak RSS %.3f MiB exceeded %.3f MiB", peakRSSMiB, limit))
        }
    }

    private static func measure(
        fixture: Fixture,
        window: DateInterval,
        options: BenchmarkOptions
    ) async throws -> Measurement {
        guard options.usesRepository else {
            let started = ProcessInfo.processInfo.systemUptime
            let summary = try UsageCostScanner(codexHome: fixture.codexHome)
                .scanAPIEquivalent(window: window)
            return Measurement(
                summary: summary,
                elapsed: ProcessInfo.processInfo.systemUptime - started,
                warmElapsed: nil)
        }
        let repository = UsageCostRepository(
            codexHome: fixture.codexHome,
            databaseURL: fixture.codexHome.appendingPathComponent(".benchmark-index.sqlite3"))
        let query = ApiCostQuery(id: "benchmark", window: window)
        let started = ProcessInfo.processInfo.systemUptime
        let cold = try await repository.summaries(
            for: [query], calculatedAt: Date(), policy: .ifChanged)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let warmStarted = ProcessInfo.processInfo.systemUptime
        let warm = try await repository.summaries(
            for: [query], calculatedAt: Date(), policy: .ifChanged)
        return Measurement(
            summary: warm[query.id] ?? cold[query.id] ?? .unavailable(window: window),
            elapsed: elapsed,
            warmElapsed: ProcessInfo.processInfo.systemUptime - warmStarted)
    }

    private static func makeFixture(options: BenchmarkOptions) throws -> Fixture {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-cost-benchmark-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions/2026/07/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let file = sessionDirectory.appendingPathComponent("rollout-anonymous.jsonl")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw BenchmarkError.unableToCreateFixture(file.path)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try writeFixture(to: handle, options: options)
        let expectedEvents = (options.lines + options.relevantEvery - 1) / options.relevantEvery
        return Fixture(
            codexHome: codexHome,
            file: file,
            expectedTokens: expectedEvents * 1_050)
    }

    private static func writeFixture(to handle: FileHandle, options: BenchmarkOptions) throws {
        let irrelevantPayload = String(repeating: "x", count: options.irrelevantPayloadBytes)
        let tokenLine = #"{"timestamp":"2026-07-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":10}}},"turn_context":{"model":"gpt-5.5"}}"#
        let unrelatedLine = #"{"timestamp":"2026-07-18T12:00:00Z","type":"event_msg","payload":{"type":"message","role":"assistant","content":""# + irrelevantPayload + #""}}"#
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        append(#"{"timestamp":"2026-07-18T00:00:00Z","type":"session_meta","payload":{"id":"anonymous","cwd":"/anonymous/project"}}"#, to: &buffer)
        for line in 0..<options.lines {
            append(line.isMultiple(of: options.relevantEvery) ? tokenLine : unrelatedLine, to: &buffer)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    private static func append(_ line: String, to buffer: inout Data) {
        buffer.append(contentsOf: line.utf8)
        buffer.append(0x0A)
    }

    private static func date(_ text: String) -> Date {
        guard let value = ISO8601DateFormatter().date(from: text) else {
            fatalError("invalid benchmark date")
        }
        return value
    }

    private static func peakResidentMemoryMiB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / 1_048_576
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func printUsage() {
    print("""
    Usage: swift run -c release CodexRunwayCostBenchmark [options]
      --lines N                       JSONL workload lines (default: 50000)
      --relevant-every N              one token event per N lines (default: 10)
      --irrelevant-payload-bytes N    anonymous payload bytes per unrelated line (default: 256)
      --repository                    measure SQLite cold and warm repository queries
      --max-seconds N                 fail when scan elapsed time exceeds N
      --max-warm-seconds N            fail when warm repository query exceeds N
      --max-rss-mib N                 fail when process peak RSS exceeds N MiB
      --keep-fixture                  preserve and print the generated fixture path
    """)
}
