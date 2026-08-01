import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok billing client", .serialized)
struct GrokBillingClientTests {
    @Test("reads access token from home auth.json and requests format=credits")
    func fetchUsesHomeTokenAndCreditsQuery() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        try temporary.writeAuth(accessToken: "home-access-token-for-tests")
        let recorder = BillingRequestRecorder()
        MockBillingURLProtocol.handler = { request in
            await recorder.record(request)
            let body = Data(#"""
            {
              "config": {
                "creditUsagePercent": 44.0,
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-29T09:32:35Z",
                  "end": "2026-08-05T09:32:35Z"
                },
                "prepaidBalance": {"val": 0}
              }
            }
            """#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                body)
        }
        defer { MockBillingURLProtocol.handler = nil }

        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            baseURL: URL(string: "https://cli-chat-proxy.grok.com/v1")!)
        let snapshot = try await client.fetch(homeURL: temporary.url)

        #expect(snapshot.includedUsagePercent == 44.0)
        #expect(snapshot.period?.kind == .weekly)
        let request = try #require(await recorder.last)
        #expect(request.url?.absoluteString
            == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer home-access-token-for-tests")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("missing auth.json is authentication required")
    func missingAuthIsAuthenticationRequired() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let client = GrokBillingClient(session: MockBillingURLProtocol.session())

        await #expect(throws: GrokCLIError.authenticationRequired) {
            try await client.fetch(homeURL: temporary.url)
        }
    }

    @Test("HTTP 401 is authentication required")
    func http401IsAuthenticationRequired() async throws {
        MockBillingURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil)!,
                Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer { MockBillingURLProtocol.handler = nil }
        let client = GrokBillingClient(session: MockBillingURLProtocol.session())

        await #expect(throws: GrokCLIError.authenticationRequired) {
            try await client.fetch(accessToken: "expired-token-for-tests")
        }
    }

    @Test("malformed billing payload surfaces a structured error")
    func malformedPayloadFails() async throws {
        MockBillingURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"unexpected":true}"#.utf8))
        }
        defer { MockBillingURLProtocol.handler = nil }
        let client = GrokBillingClient(session: MockBillingURLProtocol.session())

        await #expect(throws: GrokCLIError.malformedResponse("billing parse failed")) {
            try await client.fetch(accessToken: "token-for-tests")
        }
    }

    @Test("default GrokCLIClient billing path uses the HTTP client over home auth")
    func defaultCLIClientBillingUsesHTTP() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        try temporary.writeAuth(accessToken: "cli-default-token-for-tests")
        MockBillingURLProtocol.handler = { request in
            let body = Data(#"""
            {"config":{"creditUsagePercent":12.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00Z","end":"2026-08-01T00:00:00Z"}}}
            """#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                body)
        }
        defer { MockBillingURLProtocol.handler = nil }

        let client = GrokCLIClient(
            executableURL: nil,
            session: MockBillingURLProtocol.session(),
            billingBaseURL: URL(string: "https://cli-chat-proxy.grok.com/v1")!)
        let snapshot = try await client.billing(homeURL: temporary.url)
        #expect(snapshot.includedUsagePercent == 12.5)
        #expect(snapshot.period?.kind == .monthly)
    }
}

// MARK: - Test doubles

private final class TemporaryBillingDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-billing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func writeAuth(accessToken: String) throws {
        let payload = """
        {
          "https://auth.x.ai::desktop-client": {
            "key": "\(accessToken)",
            "auth_mode": "oidc",
            "email": "billing@example.com",
            "user_id": "billing-user",
            "principal_id": "billing-user",
            "principal_type": "User",
            "oidc_client_id": "desktop-client",
            "oidc_issuer": "https://auth.x.ai",
            "refresh_token": "refresh-token-for-tests-only",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """
        try Data(payload.utf8).write(to: url.appendingPathComponent("auth.json"))
    }
}

private actor BillingRequestRecorder {
    private(set) var last: URLRequest?

    func record(_ request: URLRequest) {
        last = request
    }
}

private final class MockBillingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBillingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
