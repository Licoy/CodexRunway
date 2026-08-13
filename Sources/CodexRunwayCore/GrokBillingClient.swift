import Foundation

/// Fetches SuperGrok / Grok Build included credits from the official CLI chat-proxy.
///
/// Primary endpoint matches the local Grok CLI (`cli-chat-proxy.grok.com/v1/billing?format=credits`)
/// and CLIProxyAPI's documented chat-proxy base URL. Uses the managed OAuth access token
/// from the account home's `auth.json` — not browser cookies.
///
/// Official requests carry the local Grok CLI identity (`User-Agent`,
/// `X-XAI-Token-Auth`, `x-grok-client-version`, `x-grok-client-identifier`,
/// `x-grok-client-mode`) via ``GrokCLIChatProxyIdentity/apply(to:accessToken:clientVersion:)``.
/// The client version is resolved from local `grok --version`.
///
/// Enrichment (best effort, same token):
/// - `/v1/settings` → `subscription_tier_display` (plan name; credits payload often omits it)
/// - `/v1/billing` (default / cents) → `monthlyLimit` / `used` USD-equivalent allowance
/// - JWT `tier` claim → plan fallback when settings/billing omit the tier
/// - grok.com `ConsumerUiSvc/GetRemainingResets` → banked SuperGrok reset cards
public struct GrokBillingClient: Sendable {
    public typealias ClientVersionProvider = @Sendable () async -> String

    public static let defaultResetCreditsURL = URL(
        string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets")!

    public var session: URLSession
    public var baseURL: URL
    /// Official Connect / gRPC-Web RPC that lists remaining usage-reset cards.
    public var resetCreditsURL: URL
    /// Returns the bare CLI version (e.g. `0.2.114`) used in chat-proxy identity headers.
    public var clientVersionProvider: ClientVersionProvider

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!,
        resetCreditsURL: URL = GrokBillingClient.defaultResetCreditsURL,
        clientVersionProvider: @escaping ClientVersionProvider)
    {
        self.session = session
        self.baseURL = baseURL
        self.resetCreditsURL = resetCreditsURL
        self.clientVersionProvider = clientVersionProvider
    }

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!,
        resetCreditsURL: URL = GrokBillingClient.defaultResetCreditsURL,
        clientVersion: GrokCLIClientVersionProvider? = nil)
    {
        let provider = clientVersion ?? GrokCLIClientVersionProvider.sharedLive
        self.session = session
        self.baseURL = baseURL
        self.resetCreditsURL = resetCreditsURL
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
        async let resetCreditsResult = fetchResetCreditsData(
            accessToken: accessToken,
            clientVersion: clientVersion)

        // Credits is preferred, but cents alone is enough for a usable snapshot when the
        // credits shape is empty/variant (common right after login / account switch).
        let creditsData: Data?
        do {
            creditsData = try await creditsResult
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GrokCLIError where error == .authenticationRequired {
            throw error
        } catch {
            creditsData = nil
        }

        let centsData: Data?
        do {
            centsData = try await centsResult
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GrokCLIError where error == .authenticationRequired {
            // Prefer surfacing auth when credits also failed for the same reason.
            if creditsData == nil { throw error }
            centsData = nil
        } catch {
            centsData = nil
        }

        var snapshot: GrokQuotaSnapshot?
        if let creditsData {
            snapshot = try? GrokQuotaSnapshot.decodeBillingResponse(from: creditsData, now: now)
        }
        if snapshot == nil, let centsData {
            snapshot = try? GrokQuotaSnapshot.decodeBillingResponse(from: centsData, now: now)
        }
        guard var snapshot else {
            throw GrokCLIError.malformedResponse("billing parse failed")
        }

        if let centsData,
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

        if let resetData = try? await resetCreditsResult,
           let resetCredits = try? GrokResetCreditsSnapshot.decode(from: resetData, now: now)
        {
            snapshot = snapshot.mergingResetCredits(resetCredits)
        }

        return snapshot
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        GrokCLIChatProxyIdentity.apply(
            to: &request,
            accessToken: accessToken,
            clientVersion: clientVersion)

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

    private func fetchResetCreditsData(accessToken: String, clientVersion: String) async throws -> Data {
        var request = URLRequest(url: resetCreditsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = GrokResetCreditsSnapshot.grpcWebRequest()
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        GrokCLIChatProxyIdentity.apply(
            to: &request,
            accessToken: accessToken,
            clientVersion: clientVersion)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            if error.code == .cancelled { throw CancellationError() }
            throw GrokCLIError.timeout(operation: "reset-credits")
        } catch {
            throw GrokCLIError.requestFailed(String(error.localizedDescription.prefix(200)))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokCLIError.requestFailed("invalid reset-credits response")
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
