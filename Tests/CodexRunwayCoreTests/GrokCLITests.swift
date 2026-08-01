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
