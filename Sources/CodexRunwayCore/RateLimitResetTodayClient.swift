import Foundation

public struct RateLimitResetTodayClient: Sendable {
    public static let siteURL = URL(string: "https://codexreset.gitcdn.top/")!
    public static let statusURL = URL(string: "https://codexreset.gitcdn.top/api/status.json")!

    public var session: URLSession
    public var statusURL: URL
    /// When set, `fetchStatus` returns a local fixture instead of calling the network.
    public var devMockKind: RateLimitResetTodaySnapshot.DevMockKind?

    public init(
        session: URLSession = RunwayNetwork.session,
        statusURL: URL = RateLimitResetTodayClient.statusURL,
        devMockKind: RateLimitResetTodaySnapshot.DevMockKind? = RateLimitResetTodayClient.resolveDevMockKind())
    {
        self.session = session
        self.statusURL = statusURL
        self.devMockKind = devMockKind
    }

    public func fetchStatus(
        now: Date = Date(),
        calendar: Calendar = .current) async throws -> RateLimitResetTodaySnapshot
    {
        if let devMockKind {
            return RateLimitResetTodaySnapshot.devMock(kind: devMockKind, now: now)
        }
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try RateLimitResetTodaySnapshot.decode(
            from: data,
            now: now,
            calendar: calendar)
    }

    /// `--mock-reset-today=yes|no|unknown` or `CODEX_RUNWAY_MOCK_RESET_TODAY=...`.
    public static func resolveDevMockKind(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> RateLimitResetTodaySnapshot.DevMockKind?
    {
        if let flag = arguments.first(where: { $0.hasPrefix("--mock-reset-today=") }) {
            let value = String(flag.dropFirst("--mock-reset-today=".count))
            return RateLimitResetTodaySnapshot.DevMockKind.parse(value)
        }
        if let value = environment["CODEX_RUNWAY_MOCK_RESET_TODAY"] {
            return RateLimitResetTodaySnapshot.DevMockKind.parse(value)
        }
        return nil
    }
}
