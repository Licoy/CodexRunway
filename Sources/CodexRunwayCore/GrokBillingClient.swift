import Foundation

/// Fetches SuperGrok / Grok Build included credits from the official CLI chat-proxy.
///
/// Primary endpoint matches the local Grok CLI (`cli-chat-proxy.grok.com/v1/billing?format=credits`)
/// and CLIProxyAPI's documented chat-proxy base URL. Uses the managed OAuth access token
/// from the account home's `auth.json` — not browser cookies.
///
/// Chat-proxy requests carry Grok CLI identity headers (`User-Agent`,
/// `X-XAI-Token-Auth`, `x-grok-client-version`). The client version is resolved
/// from the local `grok --version` output (see ``GrokCLIClientVersionProvider``).
///
/// Enrichment (best effort, same token):
/// - `/v1/settings` → `subscription_tier_display` (plan name; credits payload often omits it)
/// - `/v1/billing` (default / cents) → `monthlyLimit` / `used` USD-equivalent allowance
/// - JWT `tier` claim → plan fallback when settings/billing omit the tier
public struct GrokBillingClient: Sendable {
    public typealias ClientVersionProvider = @Sendable () async -> String

    public var session: URLSession
    public var baseURL: URL
    /// Returns the bare CLI version (e.g. `0.2.114`) used in chat-proxy identity headers.
    public var clientVersionProvider: ClientVersionProvider

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!,
        clientVersionProvider: @escaping ClientVersionProvider)
    {
        self.session = session
        self.baseURL = baseURL
        self.clientVersionProvider = clientVersionProvider
    }

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!,
        clientVersion: GrokCLIClientVersionProvider? = nil)
    {
        let provider = clientVersion ?? GrokCLIClientVersionProvider.sharedLive
        self.session = session
        self.baseURL = baseURL
        self.clientVersionProvider = { await provider.clientVersion() }
    }

    public func fetch(homeURL: URL) async throws -> GrokQuotaSnapshot {
        let authURL = homeURL.appendingPathComponent("auth.json")
        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch {
            throw GrokCLIError.authenticationRequired
        }
        let accessToken: String
        do {
            accessToken = try GrokAuthDocument.accessToken(from: data)
        } catch GrokAuthDocumentError.noManagedCredential {
            throw GrokCLIError.authenticationRequired
        } catch {
            throw GrokCLIError.authenticationRequired
        }
        return try await fetch(accessToken: accessToken)
    }

    public func fetch(accessToken: String, now: Date = Date()) async throws -> GrokQuotaSnapshot {
        // Resolve once per fetch so the three parallel chat-proxy calls share one version.
        let clientVersion = GrokCLIChatProxyIdentity.normalizedClientVersion(
            await clientVersionProvider())
        async let creditsResult = fetchData(
            path: "billing",
            query: [("format", "credits")],
            accessToken: accessToken,
            clientVersion: clientVersion)
        async let centsResult = fetchData(
            path: "billing",
            query: [],
            accessToken: accessToken,
            clientVersion: clientVersion)
        async let settingsResult = fetchData(
            path: "settings",
            query: [],
            accessToken: accessToken,
            clientVersion: clientVersion)

        let creditsData = try await creditsResult
        var snapshot = try decodeCredits(creditsData, now: now)

        if let centsData = try? await centsResult,
           let money = try? GrokQuotaSnapshot.decodeMoneyAllowance(from: centsData)
        {
            snapshot = snapshot.mergingMoneyAllowance(
                limitCents: money.limitCents,
                usedCents: money.usedCents)
        }

        if let settingsData = try? await settingsResult,
           let plan = GrokQuotaSnapshot.decodeSettingsPlan(from: settingsData)
        {
            snapshot = snapshot.mergingPlan(plan, overwrite: true)
        } else {
            snapshot = snapshot.mergingPlan(nil)
        }

        if snapshot.plan == nil || snapshot.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            snapshot = snapshot.mergingPlan(
                GrokSubscriptionTier.displayName(fromAccessToken: accessToken),
                overwrite: true)
        }

        return snapshot
    }

    private func decodeCredits(_ data: Data, now: Date) throws -> GrokQuotaSnapshot {
        do {
            return try GrokQuotaSnapshot.decodeBillingResponse(from: data, now: now)
        } catch {
            throw GrokCLIError.malformedResponse("billing parse failed")
        }
    }

    private func fetchData(
        path: String,
        query: [(String, String)],
        accessToken: String,
        clientVersion: String) async throws -> Data
    {
        guard let url = makeURL(path: path, query: query) else {
            throw GrokCLIError.requestFailed("invalid billing URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // CLI chat-proxy identity (CLIProxyAPI `applyXAIChatHeaders`).
        request.setValue(
            GrokCLIChatProxyIdentity.tokenAuthValue,
            forHTTPHeaderField: GrokCLIChatProxyIdentity.tokenAuthHeader)
        request.setValue(
            clientVersion,
            forHTTPHeaderField: GrokCLIChatProxyIdentity.clientVersionHeader)
        request.setValue(
            GrokCLIChatProxyIdentity.userAgent(clientVersion: clientVersion),
            forHTTPHeaderField: GrokCLIChatProxyIdentity.userAgentHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            if error.code == .cancelled { throw CancellationError() }
            throw GrokCLIError.timeout(operation: "billing")
        } catch {
            throw GrokCLIError.requestFailed(String(error.localizedDescription.prefix(200)))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokCLIError.requestFailed("invalid billing response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw GrokCLIError.authenticationRequired
        default:
            throw GrokCLIError.requestFailed("HTTP \(http.statusCode)")
        }
    }

    private func makeURL(path: String, query: [(String, String)]) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components?.url
    }
}
