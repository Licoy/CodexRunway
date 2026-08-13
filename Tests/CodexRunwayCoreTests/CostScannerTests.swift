import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost scanner")
struct CostScannerTests {
    @Test("aggregates token_count events inside the selected window")
    func aggregatesTokenCounts() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appending(path: "rollout-test.jsonl")
        try """
        {"timestamp":"2026-06-28T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":999,"reasoning_output_tokens":0}}},"rate_limits":{"plan_type":"pro"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":10}}},"turn_context":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}},"turn_context":{"model":"unknown-model"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scan(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-29T01:00:00Z")!))

        #expect(summary.totals.inputTokens == 1_500)
        #expect(summary.totals.cachedInputTokens == 200)
        #expect(summary.totals.outputTokens == 75)
        #expect(summary.estimatedUSD > 0)
        #expect(summary.unknownModels == ["unknown-model"])
    }

    @Test("uses latest turn context model for following token count events")
    func usesTurnContextModel() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appending(path: "rollout-context-model.jsonl")
        try """
        {"timestamp":"2026-06-29T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0}}}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scan(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-29T01:00:00Z")!))

        #expect(summary.modelBreakdown.map(\.model) == ["gpt-5.5"])
        #expect(summary.unknownModels.isEmpty)
        #expect(summary.estimatedUSD > 0)
    }

    @Test("detects relevant session files from dated paths")
    func detectsRelevantDatedPaths() {
        let scanner = UsageCostScanner(codexHome: URL(fileURLWithPath: "/tmp/.codex"))
        let window = DateInterval(
            start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-06-29T05:00:00Z")!)

        #expect(scanner.isLikelyRelevant(
            URL(fileURLWithPath: "/tmp/.codex/sessions/2026/06/29/rollout-a.jsonl"),
            window: window))
        #expect(scanner.isLikelyRelevant(
            URL(fileURLWithPath: "/tmp/.codex/sessions/2026/03/29/rollout-a.jsonl"),
            window: window) == false)
    }

    @Test("API equivalent report exposes deterministic scan diagnostics")
    func apiEquivalentReportDiagnostics() throws {
        let root = try TemporaryDirectory()
        let sessions = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        let archived = root.url.appending(path: "archived_sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let firstContents = """
        {"timestamp":"2026-06-29T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        not-json
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":0}}}}
        """
        let secondContents = """
        {"timestamp":"2026-06-29T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
        """
        try firstContents.write(
            to: sessions.appending(path: "rollout-first.jsonl"), atomically: true, encoding: .utf8)
        try secondContents.write(
            to: archived.appending(path: "rollout-second.jsonl"), atomically: true, encoding: .utf8)

        let report = try UsageCostScanner(codexHome: root.url).scanAPIEquivalentReport(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(report.summary.totals.turns == 2)
        #expect(report.diagnostics.bytesRead == firstContents.utf8.count + secondContents.utf8.count)
        #expect(report.diagnostics.candidateLines == 3)
        #expect(report.diagnostics.decodedLines == 3)
        #expect(report.diagnostics.maxBufferedBytes == max(firstContents.utf8.count, secondContents.utf8.count))
        #expect(report.diagnostics.candidateFiles == 2)
    }

    @Test("local API equivalent scans the weekly window without pricing unknown models")
    func localAPIEquivalentUsesWeeklyWindow() throws {
        let root = try TemporaryDirectory()
        let calculatedAt = ISO8601DateFormatter().date(from: "2026-06-30T10:00:00Z")!
        let sessionDir = root.url.appending(path: "sessions/2026/06/25", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appending(path: "rollout-weekly.jsonl")
        try """
        {"timestamp":"2026-06-25T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":10}}},"turn_context":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}},"turn_context":{"model":"unknown-model"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scanAPIEquivalent(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!),
            calculatedAt: calculatedAt)

        #expect(summary.calculatedAt == calculatedAt)
        #expect(summary.source == .localSessions)
        #expect(summary.confidence == .tokensOnly)
        #expect(summary.totals.uncachedInputTokens == 1_300)
        #expect(summary.totals.cachedInputTokens == 200)
        #expect(summary.totals.outputTokens == 75)
        #expect(summary.totals.turns == 2)
        #expect(summary.dailyRows.map(\.date) == ["2026-06-25", "2026-06-29"])
        #expect(summary.dailyRows[0].estimatedUSD != summary.estimatedUSD)
        #expect(summary.modelRows.map(\.name) == ["gpt-5.3-codex", "unknown-model"])
        #expect(summary.estimatedUSD == nil)
        #expect(summary.warnings.isEmpty == false)
    }

    @Test("local API equivalent groups usage by project cwd")
    func localAPIEquivalentGroupsProjects() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/Users/me/dev/codex-runway"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-project.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"timestamp":"2026-06-29T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-unknown.jsonl"), atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scanAPIEquivalent(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(summary.projectRows.map(\.name) == ["codex-runway", "Unknown project"])
        #expect(summary.projectRows[0].totals.totalTokens == 1_050)
        #expect(summary.projectRows[1].totals.totalTokens == 525)
    }

    @Test("project cwd before selected window still groups in-window tokens")
    func projectCWDCanPrecedeWindow() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-06-28T23:59:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/Users/me/dev/codex-runway"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-project-before-window.jsonl"), atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scanAPIEquivalent(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(summary.projectRows.map(\.name) == ["codex-runway"])
    }

    @Test("turn context model before selected window applies to in-window tokens")
    func modelContextCanPrecedeWindow() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-06-28T23:59:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}}}
        """.write(to: sessionDir.appending(path: "rollout-model-before-window.jsonl"), atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scanAPIEquivalent(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(summary.modelRows.map(\.name) == ["gpt-5.5"])
        #expect(summary.warnings.isEmpty)
    }

    @Test("streams CRLF records across chunk boundaries and includes the final unterminated record")
    func streamsChunkBoundariesAndFinalRecord() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let padding = String(repeating: "x", count: 262_100)
        let irrelevant = "{\"timestamp\":\"2026-06-29T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"message\",\"content\":\"\(padding)\"}}"
        let token = "{\"timestamp\":\"2026-06-29T00:01:00.123Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":5,\"reasoning_output_tokens\":2}}},\"turn_context\":{\"model\":\"gpt-5.5\"}}"
        let contents = irrelevant + "\r\n" + token
        try Data(contents.utf8).write(to: sessionDir.appending(path: "rollout-boundary.jsonl"))

        let report = try UsageCostScanner(codexHome: root.url).scanAPIEquivalentReport(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(report.summary.totals.uncachedInputTokens == 80)
        #expect(report.summary.totals.cachedInputTokens == 20)
        #expect(report.summary.totals.outputTokens == 5)
        #expect(report.summary.totals.turns == 1)
        #expect(report.diagnostics.bytesRead == contents.utf8.count)
    }

    @Test("rejects malformed candidates and recovers after oversized lines with an explicit warning")
    func reportsOversizedLinesAndRecovers() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let oversized = "{\"token_count\":\"" + String(repeating: "x", count: 8 * 1_024 * 1_024) + "\"}"
        let malformed = "{\"type\":\"token_count\""
        let token = "{\"timestamp\":\"2026-06-29T00:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0}}},\"turn_context\":{\"model\":\"gpt-5.5\"}}"
        let contents = oversized + "\n" + malformed + "\n" + token + "\n"
        try Data(contents.utf8).write(to: sessionDir.appending(path: "rollout-oversized.jsonl"))

        let report = try UsageCostScanner(codexHome: root.url).scanAPIEquivalentReport(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(report.summary.totals.turns == 1)
        #expect(report.diagnostics.oversizedLines == 1)
        #expect(report.diagnostics.malformedCandidateLines == 1)
        #expect(report.diagnostics.maxBufferedBytes <= 8 * 1_024 * 1_024)
        #expect(report.summary.warnings.contains("oversized-jsonl-lines:1"))
    }

    @Test("rejects invalid or overflowing token counts without trapping")
    func rejectsInvalidTokenCounts() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let usagePrefix = #"{"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"#
        let usageSuffix = #"}}},"turn_context":{"model":"gpt-5.5"}}"#
        let lines = [
            usagePrefix + "\"input_tokens\":\(Int.min),\"cached_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0" + usageSuffix,
            usagePrefix + "\"input_tokens\":1,\"cached_input_tokens\":2,\"output_tokens\":0,\"reasoning_output_tokens\":0" + usageSuffix,
            usagePrefix + "\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":\(Int.max),\"reasoning_output_tokens\":1" + usageSuffix,
            usagePrefix + "\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":5,\"reasoning_output_tokens\":2" + usageSuffix,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: sessionDir.appending(path: "rollout-invalid-token-counts.jsonl"))

        let report = try UsageCostScanner(codexHome: root.url).scanAPIEquivalentReport(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(report.summary.totals.totalTokens == 105)
        #expect(report.summary.totals.turns == 1)
        #expect(report.diagnostics.malformedCandidateLines == 3)
        #expect(report.diagnostics.decodedLines == 1)
    }

    @Test("stream checkpoints only LF-complete records and can reread a final partial record")
    func streamCheckpointDefersFinalRecord() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appending(path: "rollout-partial.jsonl")
        let context = "{\"timestamp\":\"2026-06-29T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\"}}\n"
        let token = "{\"timestamp\":\"2026-06-29T00:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0}}}}"
        try Data((context + token).utf8).write(to: file)
        let checkpoint = UInt64(context.utf8.count)
        let stream = UsageCostLogStream(chunkSize: 17)
        var firstPass: [UsageCostParsedLine] = []

        let partial = try stream.read(file: file, fromOffset: checkpoint) { firstPass.append($0) }

        #expect(firstPass.count == 1)
        #expect(firstPass.first?.byteOffset == checkpoint)
        #expect(firstPass.first?.isLFComplete == false)
        #expect(partial.lastCompleteOffset == checkpoint)
        #expect(partial.trailingLineStartOffset == checkpoint)

        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("\n".utf8))
        try writer.close()
        var secondPass: [UsageCostParsedLine] = []
        let completed = try stream.read(file: file, fromOffset: checkpoint) { secondPass.append($0) }

        #expect(secondPass.count == 1)
        #expect(secondPass.first?.byteOffset == checkpoint)
        #expect(secondPass.first?.isLFComplete == true)
        #expect(completed.lastCompleteOffset == completed.snapshotSize)
        #expect(completed.trailingLineStartOffset == nil)
    }

    @Test("stream reads only the file size captured when it opens")
    func streamUsesOpeningSnapshot() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appending(path: "rollout-growing.jsonl")
        let initial = "{\"timestamp\":\"2026-06-29T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\"}}\n"
        let appended = "{\"timestamp\":\"2026-06-29T00:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0}}}}\n"
        try Data(initial.utf8).write(to: file)
        let stream = UsageCostLogStream(chunkSize: 19)
        var firstPassCount = 0

        let first = try stream.read(file: file) { _ in
            firstPassCount += 1
            let writer = try FileHandle(forWritingTo: file)
            try writer.seekToEnd()
            try writer.write(contentsOf: Data(appended.utf8))
            try writer.close()
        }

        #expect(firstPassCount == 1)
        #expect(first.snapshotSize == UInt64(initial.utf8.count))
        #expect(first.bytesRead == initial.utf8.count)
        var suffixCount = 0
        let suffix = try stream.read(file: file, fromOffset: first.lastCompleteOffset) { _ in
            suffixCount += 1
        }
        #expect(suffixCount == 1)
        #expect(suffix.bytesRead == appended.utf8.count)
    }

    @Test("scanner propagates task cancellation between file chunks")
    func scannerPropagatesCancellation() async throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-cancel.jsonl"), atomically: true, encoding: .utf8)
        let scanner = UsageCostScanner(codexHome: root.url)
        let window = DateInterval(
            start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!)

        let didCancel = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try scanner.scanAPIEquivalent(window: window)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(didCancel)
    }

    @Test("turn context cwd groups API equivalent projects")
    func turnContextCWDGroupsProjects() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-06-29T00:00:00Z","type":"turn_context","payload":{"cwd":"/Users/me/dev/codex-runway","model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0}}}}
        """.write(to: sessionDir.appending(path: "rollout-codex-runway.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"timestamp":"2026-06-29T00:02:00Z","type":"turn_context","payload":{"cwd":"/Users/me/dev/aqbot","model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T00:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}}}
        """.write(to: sessionDir.appending(path: "rollout-aqbot.jsonl"), atomically: true, encoding: .utf8)

        let summary = try UsageCostScanner(codexHome: root.url).scanAPIEquivalent(
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!))

        #expect(summary.projectRows.map(\.name) == ["codex-runway", "aqbot"])
        #expect(summary.projectRows.map(\.totals.totalTokens) == [1_020, 510])
    }

    @Test("session activity scanner summarizes recent Codex sessions")
    func sessionActivitySummarizesRecentSessions() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionID = "019f17a5-436d-73b2-a93d-7af3e78cc827"
        try """
        {"id":"\(sessionID)","thread_name":"Status bar quota fix","updated_at":"2026-06-29T00:04:00Z"}
        """.write(to: root.url.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/Users/me/dev/codex-runway"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"message","role":"user","content":"Fix the status bar"}}
        {"timestamp":"2026-06-29T00:02:00Z","type":"event_msg","payload":{"type":"approval_request"}}
        {"timestamp":"2026-06-29T00:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-\(sessionID).jsonl"), atomically: true, encoding: .utf8)

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 5)
        let session = try #require(summary.items.first)

        #expect(session.title == "Status bar quota fix")
        #expect(session.projectName == "codex-runway")
        #expect(session.state == .needsAttention)
        #expect(session.totals.totalTokens == 1_050)
        #expect(session.estimatedUSD ?? 0 > 0)
    }

    @Test("session activity reports invalid token usage instead of dropping it")
    func sessionActivityRejectsInvalidTokenUsage() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(
            path: "sessions/2026/06/29",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionID = "deadbeef-dead-4eef-8ead-deadbeefdead"
        let contents = """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/project"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":\(Int.max),"reasoning_output_tokens":1}}}}
        """
        try contents.write(
            to: sessionDir.appending(path: "rollout-\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8)

        #expect(throws: UsageCostArithmeticError.self) {
            _ = try SessionActivityScanner(codexHome: root.url).scan(limit: 1)
        }
    }

    @Test("session activity scanner uses index titles but sorts by file activity")
    func sessionActivityUsesIndexTitlesButSortsByFileActivity() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        try """
        {"id":"\(firstID)","thread_name":"Index newest","updated_at":"2026-06-30T00:00:00Z"}
        {"id":"\(secondID)","thread_name":"File newest","updated_at":"2026-06-29T00:00:00Z"}
        """.write(to: root.url.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
        try sessionFile(id: firstID, timestamp: "2026-06-28T00:00:00Z", title: "Old file title")
            .write(to: sessionDir.appending(path: "rollout-\(firstID).jsonl"), atomically: true, encoding: .utf8)
        try sessionFile(id: secondID, timestamp: "2026-06-29T00:00:00Z", title: "New file title")
            .write(to: sessionDir.appending(path: "rollout-\(secondID).jsonl"), atomically: true, encoding: .utf8)

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 2)

        #expect(summary.items.map(\.id) == [secondID, firstID])
        #expect(summary.items.map(\.title) == ["File newest", "Index newest"])
    }

    @Test("session activity scanner includes newer unindexed sessions")
    func sessionActivityIncludesNewerUnindexedSessions() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let indexedID = "33333333-3333-4333-8333-333333333333"
        let unindexedID = "44444444-4444-4444-8444-444444444444"
        try """
        {"id":"\(indexedID)","thread_name":"Indexed session","updated_at":"2026-06-29T00:00:00Z"}
        """.write(to: root.url.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
        try sessionFile(id: indexedID, timestamp: "2026-06-29T00:00:00Z", title: "Indexed file")
            .write(to: sessionDir.appending(path: "rollout-\(indexedID).jsonl"), atomically: true, encoding: .utf8)
        try sessionFile(id: unindexedID, timestamp: "2026-07-01T00:00:00Z", title: "Unindexed newer file")
            .write(to: sessionDir.appending(path: "rollout-\(unindexedID).jsonl"), atomically: true, encoding: .utf8)

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 5)

        #expect(summary.items.map(\.id) == [unindexedID, indexedID])
        #expect(summary.items.map(\.title) == ["Unindexed newer file", "Indexed session"])
    }

    @Test("session activity scanner falls back to recent files without index")
    func sessionActivityFallsBackToRecentFilesWithoutIndex() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let oldID = "55555555-5555-4555-8555-555555555555"
        let newID = "66666666-6666-4666-8666-666666666666"
        let oldFile = sessionDir.appending(path: "rollout-\(oldID).jsonl")
        let newFile = sessionDir.appending(path: "rollout-\(newID).jsonl")
        try sessionFile(id: oldID, timestamp: "2026-06-29T00:00:00Z", title: "Old fallback")
            .write(to: oldFile, atomically: true, encoding: .utf8)
        try sessionFile(id: newID, timestamp: "2026-06-29T00:01:00Z", title: "New fallback")
            .write(to: newFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-06-29T00:00:00Z")!],
            ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-06-29T00:10:00Z")!],
            ofItemAtPath: newFile.path)

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 1)

        #expect(summary.items.map(\.id) == [newID])
        #expect(summary.items.first?.title == "New fallback")
    }

    @Test("session activity scanner maps timestamp-prefixed rollout names to index ids")
    func sessionActivityMapsTimestampPrefixedRolloutNamesToIndexIDs() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let indexedID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        try """
        {"id":"\(indexedID)","thread_name":"Index-backed candidate","updated_at":"2026-07-01T00:00:00Z"}
        """.write(to: root.url.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
        let indexedFile = sessionDir.appending(path: "rollout-2026-06-29T00-00-00-\(indexedID).jsonl")
        try sessionFile(id: indexedID, timestamp: "2026-07-01T00:00:00Z", title: "File title")
            .write(to: indexedFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!],
            ofItemAtPath: indexedFile.path)

        let fillerDate = ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!
        for index in 0..<60 {
            let id = String(format: "bbbbbbbb-bbbb-4bbb-8bbb-%012d", index)
            let file = sessionDir.appending(path: "rollout-\(id).jsonl")
            try sessionFile(id: id, timestamp: "2026-06-30T00:00:00Z", title: "Filler \(index)")
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: fillerDate], ofItemAtPath: file.path)
        }

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 1)

        #expect(summary.items.map(\.id) == [indexedID])
        #expect(summary.items.first?.title == "Index-backed candidate")
    }

    @Test("session activity scanner reads large session activity from file edges")
    func sessionActivityReadsLargeSessionActivityFromFileEdges() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let filler = String(repeating: "x", count: 180_000)
        try """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/Users/me/dev/codex-runway"}}
        {"timestamp":"2026-06-29T00:01:00Z","type":"event_msg","payload":{"type":"message","role":"user","content":"Large edge scan"}}
        {"timestamp":"2026-06-29T00:02:00Z","type":"event_msg","payload":{"type":"message","role":"assistant","content":"\(filler)"}}
        {"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"approval_request"}}
        {"timestamp":"2026-07-01T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":25,"total_tokens":1050}}},"turn_context":{"model":"gpt-5.5"}}
        """.write(to: sessionDir.appending(path: "rollout-2026-06-29T00-00-00-\(sessionID).jsonl"), atomically: true, encoding: .utf8)

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 1)
        let session = try #require(summary.items.first)

        #expect(session.id == sessionID)
        #expect(session.title == "Large edge scan")
        #expect(session.projectName == "codex-runway")
        #expect(session.state == .needsAttention)
        #expect(session.totals.totalTokens == 1_050)
        #expect(session.totals.cachedInputTokens == 200)
        #expect(session.totals.outputTokens == 50)
    }

    @Test("session activity scanner ignores stale large files outside recent candidates")
    func sessionActivityIgnoresStaleLargeFilesOutsideRecentCandidates() throws {
        let root = try TemporaryDirectory()
        let sessionDir = root.url.appending(path: "sessions/2026/06/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let recentID = "77777777-7777-4777-8777-777777777777"
        let recentFile = sessionDir.appending(path: "rollout-\(recentID).jsonl")
        try sessionFile(id: recentID, timestamp: "2026-07-01T00:00:00Z", title: "Recent candidate")
            .write(to: recentFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!],
            ofItemAtPath: recentFile.path)

        let fillerDate = ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!
        for index in 0..<55 {
            let id = String(format: "99999999-9999-4999-8999-%012d", index)
            let file = sessionDir.appending(path: "rollout-\(id).jsonl")
            try sessionFile(id: id, timestamp: "2026-06-30T00:00:00Z", title: "Filler \(index)")
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: fillerDate], ofItemAtPath: file.path)
        }

        let oldDate = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        for index in 0..<10 {
            let id = String(format: "88888888-8888-4888-8888-%012d", index)
            let file = sessionDir.appending(path: "rollout-\(id).jsonl")
            let filler = String(repeating: "x", count: 8_192)
            try """
            {"timestamp":"2035-01-01T00:00:00Z","type":"session_meta","payload":{"id":"\(id)","cwd":"/Users/me/dev/old-\(index)"}}
            {"timestamp":"2035-01-01T00:00:01Z","type":"event_msg","payload":{"type":"message","role":"user","content":"\(filler)"}}
            """.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }

        let summary = try SessionActivityScanner(codexHome: root.url).scan(limit: 1)

        #expect(summary.items.map(\.id) == [recentID])
    }

    @Test("online analytics estimates dollars from token parts even when credits are zero")
    func analyticsCreditsZeroStillPricesTokenParts() throws {
        let calculatedAt = ISO8601DateFormatter().date(from: "2026-06-30T10:00:00Z")!
        let data = """
        {"data":[{"date":"2026-06-29","totals":{"credits":0,"turns":26,"threads":4,"cached_text_input_tokens":1000000,"uncached_text_input_tokens":2000000,"text_output_tokens":300000}}]}
        """.data(using: .utf8)!

        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: data,
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!),
            calculatedAt: calculatedAt)

        #expect(summary.calculatedAt == calculatedAt)
        #expect(summary.source == .onlineAnalytics)
        #expect(summary.confidence == .priced)
        #expect(summary.rawCredits == 0)
        #expect(summary.totals.totalTokens == 3_300_000)
        #expect(summary.totals.turns == 26)
        #expect(summary.estimatedUSD ?? 0 > 0)
    }

    @Test("online analytics rejects invalid and non-finite numeric values")
    func analyticsRejectsInvalidNumericValues() throws {
        let window = DateInterval(
            start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!)
        let invalidPayloads = [
            #"{"data":[{"date":"2026-06-29","totals":{"turns":1.5}}]}"#,
            #"{"data":[{"date":"2026-06-29","totals":{"credits":"nan"}}]}"#,
            #"{"data":[{"date":"2026-06-29","models":[{"model":"gpt-5.5","turns":"invalid"}]}]}"#,
        ]
        for payload in invalidPayloads {
            do {
                _ = try ApiEquivalentSummary.decodeAnalytics(
                    from: Data(payload.utf8),
                    window: window)
                Issue.record("Expected invalid analytics number to fail")
            } catch {
                // Expected.
            }
        }

        let overflowingCredits = """
        {"data":[
          {"date":"2026-06-28","totals":{"credits":1.7976931348623157e308}},
          {"date":"2026-06-29","totals":{"credits":1.7976931348623157e308}}
        ]}
        """
        #expect(throws: UsageCostArithmeticError.self) {
            _ = try ApiEquivalentSummary.decodeAnalytics(
                from: Data(overflowingCredits.utf8),
                window: window)
        }
    }

    @Test("online analytics with only total tokens is tokens only")
    func analyticsTotalOnlyIsTokensOnly() throws {
        let data = #"{"data":[{"date":"2026-06-29","totals":{"credits":0,"turns":1,"text_total_tokens":12000}}]}"#
            .data(using: .utf8)!

        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: data,
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!))

        #expect(summary.confidence == .tokensOnly)
        #expect(summary.totals.totalTokens == 12_000)
        #expect(summary.estimatedUSD == nil)
    }

    @Test("displayable cost excludes unavailable zero token analytics")
    func displayableCostExcludesUnavailableZeroTokenAnalytics() throws {
        let window = DateInterval(
            start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!)
        let unavailable = try ApiEquivalentSummary.decodeAnalytics(
            from: #"{"data":[{"date":"2026-06-29","totals":{"credits":0,"turns":0,"text_total_tokens":0}}]}"#.data(using: .utf8)!,
            window: window)
        let tokensOnly = try ApiEquivalentSummary.decodeAnalytics(
            from: #"{"data":[{"date":"2026-06-29","totals":{"credits":0,"turns":1,"text_total_tokens":12000}}]}"#.data(using: .utf8)!,
            window: window)
        let priced = try ApiEquivalentSummary.decodeAnalytics(
            from: #"{"data":[{"date":"2026-06-29","totals":{"credits":0,"turns":1,"uncached_text_input_tokens":1000,"text_output_tokens":100}}]}"#.data(using: .utf8)!,
            window: window)

        #expect(unavailable.isDisplayableCost == false)
        #expect(tokensOnly.isDisplayableCost)
        #expect(priced.isDisplayableCost)
    }

    @Test("cost detail splits token classes and hides unknown models")
    func costDetailSplitsTokenClasses() {
        let summary = UsageCostSummary(
            window: DateInterval(start: .now, duration: 60),
            totals: TokenUsage(inputTokens: 1_000, cachedInputTokens: 300, outputTokens: 200),
            modelBreakdown: [
                ModelCostBreakdown(model: "gpt-5.5", usage: TokenUsage(inputTokens: 700, cachedInputTokens: 200, outputTokens: 100), estimatedUSD: 2),
                ModelCostBreakdown(model: "unknown-model", usage: TokenUsage(inputTokens: 300, cachedInputTokens: 100, outputTokens: 100), estimatedUSD: 0),
            ],
            estimatedUSD: 2,
            pricingVersion: "test",
            unknownModels: ["unknown-model"])

        let detail = UsageCostDetail(summary: summary)

        #expect(detail.uncachedInputTokens == 700)
        #expect(detail.cachedInputTokens == 300)
        #expect(detail.outputTokens == 200)
        #expect(detail.totalTokens == 1_200)
        #expect(detail.models.map(\.model) == ["gpt-5.5"])
        #expect(detail.models.first?.costShare == 1)
    }

    @Test("zero cost detail uses zero model share")
    func zeroCostDetailUsesZeroShare() {
        let summary = UsageCostSummary(
            window: DateInterval(start: .now, duration: 60),
            totals: TokenUsage(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1),
            modelBreakdown: [
                ModelCostBreakdown(model: "gpt-5.5", usage: TokenUsage(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1), estimatedUSD: 0),
            ],
            estimatedUSD: 0,
            pricingVersion: "test",
            unknownModels: [])

        #expect(UsageCostDetail(summary: summary).models.first?.costShare == 0)
    }

    @Test("cost cache stores and loads the calculated summary")
    func costCacheStoresSummary() throws {
        let root = try TemporaryDirectory()
        let cacheURL = root.url.appending(path: "api-equivalent-cost.json")
        let calculatedAt = ISO8601DateFormatter().date(from: "2026-06-30T10:00:00Z")!
        let summary = ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!),
            estimatedUSD: 1.25,
            totals: ApiEquivalentTotals(
                totalTokens: 1_000,
                uncachedInputTokens: 700,
                cachedInputTokens: 200,
                outputTokens: 100,
                turns: 3,
                threads: 1),
            dailyRows: [
                ApiEquivalentDailyRow(
                    date: "2026-06-29",
                    totals: ApiEquivalentTotals(
                        totalTokens: 1_000,
                        uncachedInputTokens: 700,
                        cachedInputTokens: 200,
                        outputTokens: 100,
                        turns: 3,
                        threads: 1),
                    estimatedUSD: 1.25,
                    rawCredits: 0),
            ],
            modelRows: [
                ApiEquivalentBreakdownRow(
                    name: "gpt-5.5",
                    totals: ApiEquivalentTotals(
                        totalTokens: 1_000,
                        uncachedInputTokens: 700,
                        cachedInputTokens: 200,
                        outputTokens: 100,
                        turns: 3,
                        threads: 1),
                    estimatedUSD: 1.25,
                    rawCredits: 0),
            ],
            projectRows: [
                ApiEquivalentBreakdownRow(
                    name: "codex-runway",
                    totals: ApiEquivalentTotals(
                        totalTokens: 1_000,
                        uncachedInputTokens: 700,
                        cachedInputTokens: 200,
                        outputTokens: 100,
                        turns: 3,
                        threads: 1),
                    estimatedUSD: 1.25,
                    rawCredits: 0),
            ],
            clientRows: [],
            rawCredits: 0,
            warnings: [],
            pricingVersion: PricingTable.version,
            calculatedAt: calculatedAt)
        let store = UsageCostCacheStore(cacheURL: cacheURL)

        try store.save(summary)
        let loaded = try #require(store.load())

        #expect(loaded == summary)
    }

    @Test("cost cache rejects a stale pricing version")
    func costCacheRejectsStalePricingVersion() throws {
        let root = try TemporaryDirectory()
        let cacheURL = root.url.appending(path: "api-equivalent-cost.json")
        let store = UsageCostCacheStore(cacheURL: cacheURL)
        let summary = ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60),
            estimatedUSD: 1,
            totals: .zero,
            dailyRows: [],
            modelRows: [],
            clientRows: [],
            rawCredits: 0,
            warnings: [],
            pricingVersion: "stale-pricing-version",
            calculatedAt: Date(timeIntervalSince1970: 60))

        try store.save(summary)

        #expect(store.load() == nil)
    }

    @Test("cost cache accepts an official dynamic pricing version")
    func costCacheAcceptsOfficialPricingVersion() throws {
        let root = try TemporaryDirectory()
        let cacheURL = root.url.appending(path: "api-equivalent-cost.json")
        let store = UsageCostCacheStore(cacheURL: cacheURL)
        let summary = ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60),
            estimatedUSD: 1,
            totals: .zero,
            dailyRows: [],
            modelRows: [],
            clientRows: [],
            rawCredits: 0,
            warnings: [],
            pricingVersion: "openai-docs-official-etag",
            calculatedAt: Date(timeIntervalSince1970: 60))

        try store.save(summary)

        #expect(store.load() == summary)
    }

    @Test("cost cache ignores missing or corrupt files")
    func costCacheIgnoresMissingOrCorruptFiles() throws {
        let root = try TemporaryDirectory()
        let cacheURL = root.url.appending(path: "api-equivalent-cost.json")
        let store = UsageCostCacheStore(cacheURL: cacheURL)

        #expect(store.load() == nil)
        try "not-json".write(to: cacheURL, atomically: true, encoding: .utf8)

        #expect(store.load() == nil)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        self.url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private func sessionFile(id: String, timestamp: String, title: String) -> String {
    """
    {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(id)","cwd":"/Users/me/dev/codex-runway"}}
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"message","role":"user","content":"\(title)"}}
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}},"turn_context":{"model":"gpt-5.5"}}
    """
}
