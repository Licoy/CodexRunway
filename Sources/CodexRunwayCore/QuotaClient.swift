import Foundation

public struct QuotaClient: Sendable {
    public var session: URLSession
    public var baseURL: URL

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!)
    {
        self.session = session
        self.baseURL = baseURL
    }

    public func fetchQuota(auth: CodexAuth) async throws -> QuotaSnapshot {
        let data = try await data(path: "wham/usage", auth: auth)
        return try QuotaSnapshot.decode(from: data)
    }

    public func fetchResetCredits(auth: CodexAuth) async throws -> ResetCreditsSnapshot {
        let data = try await data(path: "wham/rate-limit-reset-credits", auth: auth)
        return try ResetCreditsSnapshot.decode(from: data)
    }

    public func fetchDailyWorkspaceUsage(
        auth: CodexAuth,
        startDate: String,
        endDate: String,
        window: DateInterval,
        calculatedAt: Date = Date()) async throws -> ApiEquivalentSummary
    {
        let url = try analyticsURL(startDate: startDate, endDate: endDate)
        let data = try await data(url: url, auth: auth)
        return try ApiEquivalentSummary.decodeAnalytics(
            from: data,
            window: window,
            calculatedAt: calculatedAt,
            startDate: startDate,
            endDate: endDate)
    }

    public func fetchCodexProfileTokenUsage(auth: CodexAuth) async throws -> CodexProfileTokenUsage {
        let data = try await data(path: "wham/profiles/me", auth: auth)
        return try CodexProfileTokenUsage.decode(from: data)
    }

    private func analyticsURL(startDate: String, endDate: String) throws -> URL {
        let url = baseURL.appendingPathComponent("wham/analytics/daily-workspace-usage-counts")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "group_by", value: "day"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func data(path: String, auth: CodexAuth) async throws -> Data {
        try await data(url: baseURL.appendingPathComponent(path), auth: auth)
    }

    private func data(url: URL, auth: CodexAuth) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = auth.tokens.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
