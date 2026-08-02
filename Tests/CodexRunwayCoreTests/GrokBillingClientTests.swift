import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok billing client", .serialized)
struct GrokBillingClientTests {
    @Test("enriches credits billing with settings plan and cents allowance")
    func fetchEnrichesPlanAndUSDAllowance() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        try temporary.writeAuth(accessToken: "home-access-token-for-tests")
        let recorder = BillingRequestRecorder()
        MockBillingURLProtocol.handler = { request in
            await recorder.record(request)
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let body: Data
            if path.hasSuffix("/settings") {
                body = Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)
            } else if path.hasSuffix("/billing"), query.contains("format=credits") {
                body = Data(#"""
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
            } else if path.hasSuffix("/billing") {
                body = Data(#"""
                {
                  "config": {
                    "monthlyLimit": {"val": 15000},
                    "used": {"val": 277}
                  }
                }
                """#.utf8)
            } else {
                body = Data(#"{}"#.utf8)
            }
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
            baseURL: URL(string: "https://cli-chat-proxy.grok.com/v1")!,
            clientVersionProvider: { "0.2.114" })
        let snapshot = try await client.fetch(homeURL: temporary.url)

        #expect(snapshot.includedUsagePercent == 44.0)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.plan == "SuperGrok")
        #expect(snapshot.includedLimitCents == 15_000)
        #expect(snapshot.includedUsedCents == 277)
        #expect(snapshot.includedRemainingCents == 14_723)

        let urls = await recorder.urls
        #expect(urls.contains { $0.contains("/billing?format=credits") })
        #expect(urls.contains { $0.hasSuffix("/billing") })
        #expect(urls.contains { $0.contains("/settings") })
        #expect(await recorder.authorizations.allSatisfy { $0 == "Bearer home-access-token-for-tests" })
        let userAgents = await recorder.headerValues(GrokCLIChatProxyIdentity.userAgentHeader)
        let tokenAuth = await recorder.headerValues(GrokCLIChatProxyIdentity.tokenAuthHeader)
        let clientVersions = await recorder.headerValues(GrokCLIChatProxyIdentity.clientVersionHeader)
        #expect(userAgents.allSatisfy { $0 == "xai-grok-workspace/0.2.114" })
        #expect(tokenAuth.allSatisfy { $0 == GrokCLIChatProxyIdentity.tokenAuthValue })
        #expect(clientVersions.allSatisfy { $0 == "0.2.114" })
        #expect(userAgents.count == 3)
    }

    @Test("chat-proxy identity headers track the injected CLI version")
    func identityHeadersTrackCLIVersion() async throws {
        let recorder = BillingRequestRecorder()
        MockBillingURLProtocol.handler = { request in
            await recorder.record(request)
            let body = Data(#"""
            {"config":{"creditUsagePercent":1,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-01T00:00:00Z","end":"2026-07-08T00:00:00Z"}}}
            """#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!,
                body)
        }
        defer { MockBillingURLProtocol.handler = nil }

        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            clientVersionProvider: { "1.4.0" })
        _ = try await client.fetch(accessToken: "token-for-tests")

        #expect(await recorder.headerValues("User-Agent").allSatisfy { $0 == "xai-grok-workspace/1.4.0" })
        #expect(await recorder.headerValues("x-grok-client-version").allSatisfy { $0 == "1.4.0" })
    }

    @Test("falls back to JWT tier when settings omit the plan")
    func fetchFallsBackToJWTTier() async throws {
        // payload {"tier":5} → SuperGrok Heavy
        let token = "eyJhbGciOiJub25lIn0.eyJ0aWVyIjo1fQ.sig"
        MockBillingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let body: Data
            if path.hasSuffix("/settings") {
                body = Data(#"{}"#.utf8)
            } else if path.hasSuffix("/billing"), query.contains("format=credits") {
                body = Data(#"""
                {"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-01T00:00:00Z","end":"2026-07-08T00:00:00Z"}}}
                """#.utf8)
            } else {
                body = Data(#"{"config":{"monthlyLimit":{"val":30000},"used":{"val":1000}}}"#.utf8)
            }
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
            clientVersionProvider: { "0.2.114" })
        let snapshot = try await client.fetch(accessToken: token)
        #expect(snapshot.plan == "SuperGrok Heavy")
        #expect(snapshot.includedLimitCents == 30_000)
    }

    @Test("missing auth.json is authentication required")
    func missingAuthIsAuthenticationRequired() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            clientVersionProvider: { "0.2.114" })

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
        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            clientVersionProvider: { "0.2.114" })

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
        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            clientVersionProvider: { "0.2.114" })

        await #expect(throws: GrokCLIError.malformedResponse("billing parse failed")) {
            try await client.fetch(accessToken: "token-for-tests")
        }
    }

    @Test("falls back to cents billing when credits payload is empty")
    func fallsBackToCentsWhenCreditsEmpty() async throws {
        MockBillingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let body: Data
            if path.hasSuffix("/billing"), query.contains("format=credits") {
                body = Data(#"{"config":{}}"#.utf8)
            } else if path.hasSuffix("/billing") {
                body = Data(#"""
                {
                  "config": {
                    "monthlyLimit": {"val": 15000},
                    "used": {"val": 750},
                    "billingPeriodStart": "2026-08-01T00:00:00+00:00",
                    "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
                  }
                }
                """#.utf8)
            } else if path.hasSuffix("/settings") {
                body = Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)
            } else {
                body = Data(#"{}"#.utf8)
            }
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
            clientVersionProvider: { "0.2.114" })
        let snapshot = try await client.fetch(accessToken: "token-for-tests")

        #expect(snapshot.includedUsagePercent == 5)
        #expect(snapshot.includedLimitCents == 15_000)
        #expect(snapshot.includedUsedCents == 750)
        #expect(snapshot.source == .deprecated)
        #expect(snapshot.plan == "SuperGrok")
    }

    @Test("default GrokCLIClient billing path uses the HTTP client over home auth")
    func defaultCLIClientBillingUsesHTTP() async throws {
        let temporary = try TemporaryBillingDirectory()
        defer { withExtendedLifetime(temporary) {} }
        try temporary.writeAuth(accessToken: "cli-default-token-for-tests")
        MockBillingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let body: Data
            if path.hasSuffix("/billing"), query.contains("format=credits") {
                body = Data(#"""
                {"config":{"creditUsagePercent":12.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00Z","end":"2026-08-01T00:00:00Z"}}}
                """#.utf8)
            } else if path.hasSuffix("/settings") {
                body = Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)
            } else {
                body = Data(#"{"config":{"monthlyLimit":{"val":15000},"used":{"val":0}}}"#.utf8)
            }
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
        #expect(snapshot.plan == "SuperGrok")
        #expect(snapshot.includedLimitCents == 15_000)
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
    private(set) var requests: [URLRequest] = []

    var last: URLRequest? { requests.last }
    var urls: [String] { requests.compactMap(\.url?.absoluteString) }
    var authorizations: [String?] { requests.map { $0.value(forHTTPHeaderField: "Authorization") } }

    func headerValues(_ name: String) -> [String?] {
        requests.map { $0.value(forHTTPHeaderField: name) }
    }

    func record(_ request: URLRequest) {
        requests.append(request)
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
        // Avoid capturing non-Sendable `self` in a sending Task closure.
        let request = self.request
        NonisolatedBillingURLProtocolResponder.fulfill(request: request, handler: handler, protocol: self)
    }

    override func stopLoading() {}
}

/// Bridges async mock handlers back to URLProtocol without a sending-`self` Task capture.
private enum NonisolatedBillingURLProtocolResponder {
    nonisolated static func fulfill(
        request: URLRequest,
        handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data),
        protocol urlProtocol: URLProtocol)
    {
        let client = urlProtocol.client
        // URLProtocol is not Sendable; the mock is single-session and serialised by suite.
        nonisolated(unsafe) let protocolInstance = urlProtocol
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(protocolInstance, didLoad: data)
                client?.urlProtocolDidFinishLoading(protocolInstance)
            } catch {
                client?.urlProtocol(protocolInstance, didFailWithError: error)
            }
        }
    }
}
