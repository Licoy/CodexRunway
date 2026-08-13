import Darwin
import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok CLI chat-proxy identity")
struct GrokCLIChatProxyIdentityTests {
    @Test("parses grok --version output into a bare client version")
    func parsesVersionOutput() {
        #expect(GrokCLIChatProxyIdentity.parseClientVersion(from: "grok 0.2.114") == "0.2.114")
        #expect(GrokCLIChatProxyIdentity.parseClientVersion(from: "  grok 1.4.0-beta.1\n") == "1.4.0-beta.1")
        #expect(GrokCLIChatProxyIdentity.parseClientVersion(from: "0.2.93") == "0.2.93")
        #expect(GrokCLIChatProxyIdentity.parseClientVersion(from: "Grok CLI version 0.3.1 (build)") == "0.3.1")
        #expect(GrokCLIChatProxyIdentity.parseClientVersion(from: "   ") == nil)
    }

    @Test("user agent uses the workspace CLI form")
    func userAgentFormat() {
        #expect(
            GrokCLIChatProxyIdentity.userAgent(clientVersion: "0.2.114")
                == "xai-grok-workspace/0.2.114")
        #expect(
            GrokCLIChatProxyIdentity.userAgent(clientVersion: "grok 0.2.114")
                == "xai-grok-workspace/0.2.114")
    }

    @Test("apply stamps the official local-CLI identity set")
    func applyStampsOfficialIdentity() {
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!)
        GrokCLIChatProxyIdentity.apply(
            to: &request,
            accessToken: "token-for-tests",
            clientVersion: "grok 1.0.3")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-for-tests")
        #expect(
            request.value(forHTTPHeaderField: GrokCLIChatProxyIdentity.tokenAuthHeader)
                == GrokCLIChatProxyIdentity.tokenAuthValue)
        #expect(request.value(forHTTPHeaderField: "x-grok-client-version") == "1.0.3")
        #expect(
            request.value(forHTTPHeaderField: "x-grok-client-identifier")
                == GrokCLIChatProxyIdentity.clientIdentifierValue)
        #expect(
            request.value(forHTTPHeaderField: "x-grok-client-mode")
                == GrokCLIChatProxyIdentity.clientModeValue)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "xai-grok-workspace/1.0.3")
    }

    @Test("version provider re-reads when the executable changes")
    func versionProviderTracksExecutableChanges() async throws {
        let temporary = try TemporaryIdentityDirectory()
        defer { withExtendedLifetime(temporary) {} }

        let executable = temporary.url.appendingPathComponent("grok")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        printf 'grok 0.2.100\n'
        """#)

        let readCount = VersionReadCounter()
        let provider = GrokCLIClientVersionProvider(
            locateExecutable: { executable },
            readVersion: { url in
                await readCount.increment()
                // Companion file overrides the reported version after mtime changes.
                let companion = url.deletingLastPathComponent().appendingPathComponent("version.txt")
                if let text = try? String(contentsOf: companion, encoding: .utf8), !text.isEmpty {
                    return text
                }
                return "grok 0.2.100"
            })

        #expect(await provider.clientVersion() == "0.2.100")
        #expect(await provider.clientVersion() == "0.2.100")
        #expect(await readCount.count == 1)

        // Bump mtime and change reported version.
        try "grok 0.2.200\n".write(
            to: temporary.url.appendingPathComponent("version.txt"),
            atomically: true,
            encoding: .utf8)
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes(
            [.modificationDate: future],
            ofItemAtPath: executable.path)

        #expect(await provider.clientVersion() == "0.2.200")
        #expect(await readCount.count == 2)
    }

    @Test("version provider falls back when the CLI is missing")
    func versionProviderFallsBackWhenMissing() async {
        let provider = GrokCLIClientVersionProvider(
            locateExecutable: { nil },
            readVersion: { _ in
                Issue.record("readVersion should not run without an executable")
                return "should-not-run"
            })
        #expect(await provider.clientVersion() == GrokCLIChatProxyIdentity.fallbackClientVersion)
    }
}

private actor VersionReadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class TemporaryIdentityDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-identity-\(UUID().uuidString)", isDirectory: true)
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
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755 as UInt16)],
        ofItemAtPath: url.path)
    guard chmod(url.path, 0o755) == 0 else {
        throw GrokCLIError.launchFailed("chmod failed")
    }
}
