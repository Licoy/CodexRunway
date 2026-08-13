import Foundation

/// CLI identity headers expected by official Grok HTTP (chat-proxy and sibling
/// RPCs), matching the local Grok Build CLI (`xai-grok-http` / billing fetch).
///
/// Every official request — quota, settings, and remaining-reset cards — must
/// go through ``apply(to:accessToken:clientVersion:)`` so the version and
/// client labels stay identical to the installed `grok` binary.
public enum GrokCLIChatProxyIdentity: Sendable {
    public static let tokenAuthHeader = "X-XAI-Token-Auth"
    public static let tokenAuthValue = "xai-grok-cli"
    public static let clientVersionHeader = "x-grok-client-version"
    public static let clientIdentifierHeader = "x-grok-client-identifier"
    /// Product label the official CLI sends (`GROK_CLIENT_NAME`, default `grok-shell`).
    public static let clientIdentifierValue = "grok-shell"
    public static let clientModeHeader = "x-grok-client-mode"
    /// Official CLI uses `interactive` only on a text TTY; status-bar fetches are not a TTY.
    public static let clientModeValue = "headless"
    public static let userAgentHeader = "User-Agent"

    /// Used only when the local CLI is missing or `--version` cannot be parsed.
    /// Matches CLIProxyAPI's last documented chat-proxy client version pin.
    public static let fallbackClientVersion = "0.2.93"

    public static func userAgent(clientVersion: String) -> String {
        "xai-grok-workspace/\(normalizedClientVersion(clientVersion))"
    }

    /// Apply the local Grok CLI identity to an official request.
    public static func apply(
        to request: inout URLRequest,
        accessToken: String,
        clientVersion: String)
    {
        let version = normalizedClientVersion(clientVersion)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokenAuthValue, forHTTPHeaderField: tokenAuthHeader)
        request.setValue(version, forHTTPHeaderField: clientVersionHeader)
        request.setValue(clientIdentifierValue, forHTTPHeaderField: clientIdentifierHeader)
        request.setValue(clientModeValue, forHTTPHeaderField: clientModeHeader)
        request.setValue(userAgent(clientVersion: version), forHTTPHeaderField: userAgentHeader)
    }

    /// Parse CLI `--version` output into a bare client version string.
    ///
    /// Accepts forms such as `grok 0.2.114`, `0.2.114`, or multi-line banners that
    /// embed a `x.y` / `x.y.z` token.
    public static func parseClientVersion(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Prefer an explicit "grok <version>" token when present.
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if let grokIndex = tokens.firstIndex(where: { $0.lowercased() == "grok" }),
           tokens.index(after: grokIndex) < tokens.endIndex
        {
            let candidate = String(tokens[tokens.index(after: grokIndex)])
            if let version = firstSemanticVersion(in: candidate) {
                return version
            }
        }

        return firstSemanticVersion(in: trimmed)
    }

    public static func normalizedClientVersion(_ raw: String) -> String {
        if let parsed = parseClientVersion(from: raw) {
            return parsed
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackClientVersion : trimmed
    }

    private static func firstSemanticVersion(in text: String) -> String? {
        // x.y or x.y.z (optional pre-release suffix without spaces).
        let pattern = #"\b(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }
}

/// Resolves the local Grok CLI client version for chat-proxy identity headers.
///
/// Re-reads `grok --version` when the executable path or modification time changes
/// so upgraded CLIs are picked up without restarting the app. Concurrent callers
/// share one in-flight probe.
public actor GrokCLIClientVersionProvider {
    public typealias VersionReader = @Sendable (URL) async throws -> String

    private let locateExecutable: @Sendable () -> URL?
    private let readVersion: VersionReader
    private var cachedPath: String?
    private var cachedMTime: TimeInterval?
    private var cachedVersion: String?
    private var inFlight: Task<String, Never>?

    public init(
        locateExecutable: @escaping @Sendable () -> URL? = { GrokExecutableLocator.locate() },
        readVersion: @escaping VersionReader)
    {
        self.locateExecutable = locateExecutable
        self.readVersion = readVersion
    }

    /// Process-wide live provider so multiple billing clients share one CLI version probe.
    public static let sharedLive = GrokCLIClientVersionProvider.live()

    /// Live provider: locate `grok` and run `grok --no-auto-update --version`.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandTimeout: TimeInterval = 10) -> GrokCLIClientVersionProvider
    {
        GrokCLIClientVersionProvider(
            locateExecutable: {
                GrokExecutableLocator.locate(environment: environment, homeDirectory: homeDirectory)
            },
            readVersion: { executableURL in
                let command = GrokCommandProcess(
                    executableURL: executableURL,
                    arguments: ["--no-auto-update", "--version"],
                    environment: environment,
                    homeURL: nil,
                    capturesOutput: true)
                let data = try await command.run(
                    timeout: max(1, min(commandTimeout, 10)),
                    operation: "version")
                guard let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else {
                    throw GrokCLIError.malformedResponse("empty version output")
                }
                return value
            })
    }

    public func clientVersion() async -> String {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.resolveNow() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value
    }

    private func resolveNow() async -> String {
        guard let executableURL = locateExecutable() else {
            return cachedVersion ?? GrokCLIChatProxyIdentity.fallbackClientVersion
        }
        let path = executableURL.path
        let mtime = modificationTime(at: path)
        if let cachedVersion,
           cachedPath == path,
           cachedMTime == mtime
        {
            return cachedVersion
        }

        do {
            let raw = try await readVersion(executableURL)
            let version = GrokCLIChatProxyIdentity.parseClientVersion(from: raw)
                ?? GrokCLIChatProxyIdentity.fallbackClientVersion
            cachedPath = path
            cachedMTime = mtime
            cachedVersion = version
            return version
        } catch {
            return cachedVersion ?? GrokCLIChatProxyIdentity.fallbackClientVersion
        }
    }

    private func modificationTime(at path: String) -> TimeInterval? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
    }
}
