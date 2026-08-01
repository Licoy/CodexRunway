import Foundation

public enum GrokExecutableLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> URL?
    {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("grok") }
        let candidates = pathCandidates + [
            homeDirectory.appendingPathComponent(".grok/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

public enum GrokCLIError: Error, LocalizedError, Sendable, Equatable {
    case binaryNotFound
    case launchFailed(String)
    case processFailed(exitCode: Int32)
    case requestFailed(String)
    case authenticationRequired
    case timeout(operation: String)
    case unexpectedEOF
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Grok CLI was not found."
        case let .launchFailed(message):
            "Grok CLI failed to start: \(message)"
        case let .processFailed(exitCode):
            "Grok CLI exited with status \(exitCode)."
        case let .requestFailed(message):
            "Grok CLI request failed: \(message)"
        case .authenticationRequired:
            "Grok authentication is required."
        case let .timeout(operation):
            "Grok CLI timed out during \(operation)."
        case .unexpectedEOF:
            "Grok CLI closed its response stream unexpectedly."
        case let .malformedResponse(message):
            "Grok CLI returned an invalid response: \(message)"
        }
    }
}

public struct GrokCLIClient: Sendable {
    public typealias BillingOperation = @Sendable (URL) async throws -> GrokQuotaSnapshot
    public typealias LoginOperation = @Sendable (URL) async throws -> Void
    public typealias VersionOperation = @Sendable () async throws -> String

    private let billingOperation: BillingOperation
    private let loginOperation: LoginOperation
    private let versionOperation: VersionOperation

    public init(
        billing: @escaping BillingOperation,
        loginOAuth: @escaping LoginOperation,
        version: @escaping VersionOperation)
    {
        billingOperation = billing
        loginOperation = loginOAuth
        versionOperation = version
    }

    public init(
        executableURL: URL? = GrokExecutableLocator.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = RunwayNetwork.session,
        billingBaseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!,
        commandTimeout: TimeInterval = 300)
    {
        let billingClient = GrokBillingClient(session: session, baseURL: billingBaseURL)
        self.init(
            billing: { homeURL in
                // Official Grok CLI fetches credits via cli-chat-proxy HTTP, not agent stdio RPC.
                // `x.ai/billing` over stdio is no longer registered on current CLI builds.
                try await billingClient.fetch(homeURL: homeURL)
            },
            loginOAuth: { homeURL in
                guard let executableURL else { throw GrokCLIError.binaryNotFound }
                let command = GrokCommandProcess(
                    executableURL: executableURL,
                    arguments: ["login", "--oauth"],
                    environment: environment,
                    homeURL: homeURL,
                    capturesOutput: false)
                _ = try await command.run(timeout: commandTimeout, operation: "login")
            },
            version: {
                guard let executableURL else { throw GrokCLIError.binaryNotFound }
                let command = GrokCommandProcess(
                    executableURL: executableURL,
                    arguments: ["--no-auto-update", "--version"],
                    environment: environment,
                    homeURL: nil,
                    capturesOutput: true)
                let data = try await command.run(timeout: min(commandTimeout, 10), operation: "version")
                guard let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else {
                    throw GrokCLIError.malformedResponse("empty version output")
                }
                return value
            })
    }

    public func billing(homeURL: URL) async throws -> GrokQuotaSnapshot {
        try await billingOperation(homeURL)
    }

    public func loginOAuth(homeURL: URL) async throws {
        try await loginOperation(homeURL)
    }

    public func version() async throws -> String {
        try await versionOperation()
    }
}
