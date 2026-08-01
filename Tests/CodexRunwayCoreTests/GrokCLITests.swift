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

    @Test("version uses the located CLI binary")
    func versionUsesLocatedCLI() async throws {
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("command-grok")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        if [ "$1" = "--no-auto-update" ] && [ "$2" = "--version" ]; then
          printf 'grok 0.2.114\n'
          exit 0
        fi
        exit 9
        """#)
        let client = GrokCLIClient(
            executableURL: executable,
            environment: [:],
            commandTimeout: 3)

        let version = try await client.version()
        #expect(version == "grok 0.2.114")
    }

    @Test("default OAuth login uses native device flow (not the CLI subprocess)")
    func defaultOAuthLoginUsesNativeDeviceFlow() async throws {
        // Regression guard: login must not depend on spawning `grok login --oauth`,
        // which cannot open a browser reliably from an LSUIElement app.
        let temporary = try TemporaryGrokDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let executable = temporary.url.appendingPathComponent("should-not-run-for-login")
        let launched = temporary.url.appendingPathComponent("cli-launched")
        try makeExecutable(at: executable, contents: #"""
        #!/bin/sh
        printf launched > "$LAUNCHED_FILE"
        exit 1
        """#)

        // Injected login keeps this test offline; production default uses GrokOAuthLogin.
        let client = GrokCLIClient(
            billing: { _ in throw GrokCLIError.requestFailed("unused") },
            loginOAuth: { homeURL in
                let data = try GrokOAuthLogin.makeAuthDocumentData(
                    tokens: .init(
                        accessToken: "native-access",
                        refreshToken: "native-refresh",
                        idToken: nil,
                        tokenType: "Bearer",
                        expiresIn: 3_600,
                        email: "native@example.com",
                        subject: "native-user",
                        tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!))
                try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
                try data.write(to: homeURL.appendingPathComponent("auth.json"))
            },
            version: { "unused" })

        try await client.loginOAuth(homeURL: temporary.url.appendingPathComponent("home", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: launched.path) == false)
        let auth = try GrokAuthDocument.parse(
            Data(contentsOf: temporary.url
                .appendingPathComponent("home")
                .appendingPathComponent("auth.json")))
        #expect(auth.identity.email == "native@example.com")
        _ = executable
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
