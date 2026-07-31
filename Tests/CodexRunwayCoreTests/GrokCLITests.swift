import Darwin
import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok CLI", .serialized)
struct GrokCLITests {
    @Test("executable locator prefers inherited PATH then the Grok home bin")
    func executableLocatorSearchOrder() throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let pathDirectory = temporary.url.appendingPathComponent("path-bin", isDirectory: true)
        let grokHomeBinary = temporary.url.appendingPathComponent(".grok/bin/grok")
        let pathBinary = pathDirectory.appendingPathComponent("grok")
        try makeExecutable(at: grokHomeBinary, contents: "#!/bin/sh\nexit 0\n")
        try makeExecutable(at: pathBinary, contents: "#!/bin/sh\nexit 0\n")

        let fromPath = GrokExecutableLocator.locate(
            environment: ["PATH": pathDirectory.path],
            homeDirectory: temporary.url)
        let fromHome = GrokExecutableLocator.locate(
            environment: ["PATH": ""],
            homeDirectory: temporary.url)

        #expect(fromPath == pathBinary)
        #expect(fromHome == grokHomeBinary)
    }

    @Test("billing RPC initializes first, uses a real slash, and skips unrelated messages")
    func billingRPCSequenceAndRouting() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("fake-grok")
        let trace = temporary.url.appendingPathComponent("trace.ndjson")
        let isolatedHome = temporary.url.appendingPathComponent("account-home", isDirectory: true)
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        IFS= read -r initialize || exit 2
        printf '%s\n' "$initialize" >> "$TRACE_FILE"
        printf '{"jsonrpc":"2.0","method":"session/update","params":{}}\n'
        printf '{"jsonrpc":"2.0","id":99,"result":{}}\n'
        printf '{"jsonrpc":"2.0","id":1,"result":{}}\n'
        IFS= read -r billing || exit 3
        printf '%s\n' "$billing" >> "$TRACE_FILE"
        printf 'home=%s\n' "$GROK_HOME" >> "$TRACE_FILE"
        case "$billing" in
          *'"method":"x.ai/billing"'*) ;;
          *) printf '{"jsonrpc":"2.0","id":2,"error":{"message":"wrong method"}}\n'; exit 4 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":37.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"}}}}'
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: ["TRACE_FILE": trace.path],
            initializeTimeout: 3,
            requestTimeout: 3)

        let snapshot = try await client.billing(homeURL: isolatedHome)
        let traceText = try String(contentsOf: trace, encoding: .utf8)
        let initializeLine = try #require(traceText.split(whereSeparator: \.isNewline).first)
        let initialize = try #require(
            JSONSerialization.jsonObject(with: Data(initializeLine.utf8)) as? [String: Any])
        let initializeParams = try #require(initialize["params"] as? [String: Any])

        #expect(snapshot.includedUsagePercent == 37.5)
        #expect(traceText.contains(#""method":"initialize""#))
        #expect(initializeParams["protocolVersion"] as? Int == 1)
        #expect(initializeParams["protocolVersion"] is String == false)
        #expect(traceText.contains(#""method":"x.ai/billing""#))
        #expect(traceText.contains(#"x.ai\/billing"#) == false)
        #expect(traceText.contains("home=\(isolatedHome.path)"))
    }

    @Test("billing timeout terminates the agent process")
    func billingTimeoutTerminatesProcess() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("slow-grok")
        let pidFile = temporary.url.appendingPathComponent("pid")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        printf '%s' "$$" > "$PID_FILE"
        IFS= read -r initialize || exit 2
        while :; do :; done
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: ["PID_FILE": pidFile.path],
            initializeTimeout: 2,
            requestTimeout: 0.1)

        await #expect(throws: GrokCLIError.timeout(operation: "initialize")) {
            try await client.billing(homeURL: temporary.url)
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        #expect(kill(pid, 0) == -1)
    }

    @Test("billing timeout force-kills an agent that ignores SIGTERM")
    func billingTimeoutForceKillsTermIgnoringProcess() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("term-ignoring-grok")
        let pidFile = temporary.url.appendingPathComponent("term-ignoring-pid")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$PID_FILE"
        IFS= read -r initialize || exit 2
        while :; do :; done
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: ["PID_FILE": pidFile.path],
            initializeTimeout: 0.5,
            requestTimeout: 0.1)
        let startedAt = Date()
        let task = Task {
            try await client.billing(homeURL: temporary.url)
        }
        try await waitForFile(pidFile)

        await #expect(throws: GrokCLIError.timeout(operation: "initialize")) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(startedAt) < 2)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        try await waitForProcessExit(pid)
    }

    @Test("cancelling billing terminates the agent process")
    func billingCancellationTerminatesProcess() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("cancel-grok")
        let ready = temporary.url.appendingPathComponent("ready")
        let terminated = temporary.url.appendingPathComponent("terminated")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        trap 'printf stopped > "$TERMINATED_FILE"; exit 0' TERM
        IFS= read -r initialize || exit 2
        printf ready > "$READY_FILE"
        while :; do :; done
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: [
                "READY_FILE": ready.path,
                "TERMINATED_FILE": terminated.path,
            ],
            initializeTimeout: 20,
            requestTimeout: 20)
        let task = Task {
            try await client.billing(homeURL: temporary.url)
        }
        try await waitForFile(ready)

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled billing unexpectedly succeeded")
        } catch is CancellationError {
            // Expected public cancellation behavior.
        } catch {
            Issue.record("cancelled billing returned \(error) instead of CancellationError")
        }
        try await waitForFile(terminated)
    }

    @Test("closing stdout before a response fails explicitly")
    func prematureStdoutCloseFails() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("eof-grok")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        IFS= read -r initialize || exit 2
        exit 0
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            initializeTimeout: 3,
            requestTimeout: 3)

        await #expect(throws: GrokCLIError.unexpectedEOF) {
            try await client.billing(homeURL: temporary.url)
        }
    }

    @Test("billing authentication failures have a distinct error")
    func billingAuthenticationFailure() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("auth-grok")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        IFS= read -r initialize || exit 2
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r billing || exit 3
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"Authentication required; run grok login"}}'
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            initializeTimeout: 3,
            requestTimeout: 3)

        await #expect(throws: GrokCLIError.authenticationRequired) {
            try await client.billing(homeURL: temporary.url)
        }
    }

    @Test("version and OAuth login use the located CLI and isolated home")
    func versionAndOAuthLogin() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("command-grok")
        let loginTrace = temporary.url.appendingPathComponent("login-home")
        let isolatedHome = temporary.url.appendingPathComponent("pending", isDirectory: true)
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        if [ "$1" = "--no-auto-update" ] && [ "$2" = "--version" ]; then
          printf 'grok 0.2.114\n'
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "--oauth" ]; then
          printf '%s' "$GROK_HOME" > "$LOGIN_TRACE"
          exit 0
        fi
        exit 9
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: ["LOGIN_TRACE": loginTrace.path],
            commandTimeout: 3)

        let version = try await client.version()
        try await client.loginOAuth(homeURL: isolatedHome)

        #expect(version == "grok 0.2.114")
        #expect(try String(contentsOf: loginTrace, encoding: .utf8) == isolatedHome.path)
    }

    @Test("cancelling OAuth login terminates the CLI")
    func cancellingOAuthLoginTerminatesCLI() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("login-grok")
        let ready = temporary.url.appendingPathComponent("login-ready")
        let terminated = temporary.url.appendingPathComponent("login-terminated")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        trap 'printf stopped > "$TERMINATED_FILE"; exit 0' TERM
        printf ready > "$READY_FILE"
        while :; do :; done
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: [
                "READY_FILE": ready.path,
                "TERMINATED_FILE": terminated.path,
            ],
            commandTimeout: 20)
        let task = Task {
            try await client.loginOAuth(homeURL: temporary.url)
        }
        try await waitForFile(ready)

        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled login unexpectedly succeeded")
        } catch is CancellationError {
            // Expected public cancellation behavior.
        } catch {
            Issue.record("cancelled login returned \(error) instead of CancellationError")
        }
        try await waitForFile(terminated)
    }

    @Test("cancelling OAuth force-kills a CLI that ignores SIGTERM")
    func cancellingOAuthForceKillsTermIgnoringCLI() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("term-ignoring-login-grok")
        let ready = temporary.url.appendingPathComponent("term-ignoring-login-ready")
        let pidFile = temporary.url.appendingPathComponent("term-ignoring-login-pid")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$PID_FILE"
        printf ready > "$READY_FILE"
        while :; do :; done
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: [
                "PID_FILE": pidFile.path,
                "READY_FILE": ready.path,
            ],
            commandTimeout: 20)
        let task = Task {
            try await client.loginOAuth(homeURL: temporary.url)
        }
        try await waitForFile(ready)
        let startedAt = Date()

        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled login unexpectedly succeeded")
        } catch is CancellationError {
            // Expected public cancellation behavior.
        } catch {
            Issue.record("cancelled login returned \(error) instead of CancellationError")
        }
        #expect(Date().timeIntervalSince(startedAt) < 2)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        try await waitForProcessExit(pid)
    }
}

private final class TemporaryGrokDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeExecutable(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private func waitForFile(_ url: URL) async throws {
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CocoaError(.fileReadUnknown)
}

private func waitForProcessExit(_ processIdentifier: Int32) async throws {
    for _ in 0..<300 {
        if kill(processIdentifier, 0) == -1 { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CocoaError(.fileReadUnknown)
}
