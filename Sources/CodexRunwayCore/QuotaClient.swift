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

    /// Best-effort display metadata. Failure must never block quota refresh or account switching.
    public func fetchWorkspaceName(auth: CodexAuth) async throws -> String? {
        guard !auth.tokens.accessToken.isEmpty,
              let accountId = AccountIdentity.oauthAccountId(for: auth)
        else { return nil }
        let payload = try await data(path: "accounts", auth: auth, timeoutInterval: 8)
        return try Self.decodeWorkspaceName(from: payload, accountId: accountId)
    }

    static func decodeWorkspaceName(from data: Data, accountId: String) throws -> String? {
        let response = try JSONDecoder().decode(WorkspaceAccountsResponse.self, from: data)
        guard let entry = response.items.first(where: { $0.id == accountId }),
              let rawName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty
        else { return nil }
        return rawName
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

    private func data(
        path: String,
        auth: CodexAuth,
        timeoutInterval: TimeInterval = 20) async throws -> Data
    {
        try await data(
            url: baseURL.appendingPathComponent(path),
            auth: auth,
            timeoutInterval: timeoutInterval)
    }

    private func data(
        url: URL,
        auth: CodexAuth,
        timeoutInterval: TimeInterval = 20) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexRunway/1", forHTTPHeaderField: "User-Agent")
        if let accountId = AccountIdentity.oauthAccountId(for: auth), !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private struct WorkspaceAccountsResponse: Decodable {
    var items: [WorkspaceAccountEntry]
}

private struct WorkspaceAccountEntry: Decodable {
    var id: String
    var name: String?
}
