import Foundation

/// Fetches SuperGrok / Grok Build included credits from the official CLI chat-proxy.
///
/// Endpoint matches the local Grok CLI (`cli-chat-proxy.grok.com/v1/billing?format=credits`)
/// and CLIProxyAPI's documented chat-proxy base URL. Uses the managed OAuth access token
/// from the account home's `auth.json` — not browser cookies.
public struct GrokBillingClient: Sendable {
    public var session: URLSession
    public var baseURL: URL

    public init(
        session: URLSession = RunwayNetwork.session,
        baseURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1")!)
    {
        self.session = session
        self.baseURL = baseURL
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
        guard let url = billingURL else {
            throw GrokCLIError.requestFailed("invalid billing URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
            do {
                return try GrokQuotaSnapshot.decodeBillingResponse(from: data, now: now)
            } catch {
                throw GrokCLIError.malformedResponse("billing parse failed")
            }
        case 401, 403:
            throw GrokCLIError.authenticationRequired
        default:
            throw GrokCLIError.requestFailed("HTTP \(http.statusCode)")
        }
    }

    private var billingURL: URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("billing"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "credits")]
        return components?.url
    }
}
