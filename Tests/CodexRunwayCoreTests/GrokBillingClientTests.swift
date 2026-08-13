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
        #expect(snapshot.resetCredits?.availableCount == 0)
        #expect(snapshot.resetCredits?.tokens.isEmpty == true)

        let urls = await recorder.urls
        #expect(urls.contains { $0.contains("/billing?format=credits") })
        #expect(urls.contains { $0.hasSuffix("/billing") })
        #expect(urls.contains { $0.contains("/settings") })
        #expect(urls.contains { $0.contains("GetRemainingResets") })
        #expect(await recorder.authorizations.allSatisfy { $0 == "Bearer home-access-token-for-tests" })
        let userAgents = await recorder.headerValues(GrokCLIChatProxyIdentity.userAgentHeader)
        let tokenAuth = await recorder.headerValues(GrokCLIChatProxyIdentity.tokenAuthHeader)
        let clientVersions = await recorder.headerValues(GrokCLIChatProxyIdentity.clientVersionHeader)
        let identifiers = await recorder.headerValues(GrokCLIChatProxyIdentity.clientIdentifierHeader)
        let modes = await recorder.headerValues(GrokCLIChatProxyIdentity.clientModeHeader)
        #expect(userAgents.allSatisfy { $0 == "xai-grok-workspace/0.2.114" })
        #expect(tokenAuth.allSatisfy { $0 == GrokCLIChatProxyIdentity.tokenAuthValue })
        #expect(clientVersions.allSatisfy { $0 == "0.2.114" })
        #expect(identifiers.allSatisfy { $0 == GrokCLIChatProxyIdentity.clientIdentifierValue })
        #expect(modes.allSatisfy { $0 == GrokCLIChatProxyIdentity.clientModeValue })
        #expect(userAgents.count == 4)
    }

    @Test("attaches official remaining-reset cards from GetRemainingResets")
    func fetchAttachesResetCredits() async throws {
        MockBillingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: Data
            if path.contains("GetRemainingResets") {
                body = GrokResetCreditsFixture.proto(
                    tokenID: "restok_client",
                    start: Date(timeIntervalSince1970: 1_786_560_540),
                    end: Date(timeIntervalSince1970: 1_789_238_940))
            } else if path.hasSuffix("/billing") {
                body = Data(#"""
                {"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"}}}
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
                    headerFields: ["Content-Type": "application/grpc-web+proto"])!,
                body)
        }
        defer { MockBillingURLProtocol.handler = nil }

        let now = Date(timeIntervalSince1970: 1_786_601_000)
        let client = GrokBillingClient(
            session: MockBillingURLProtocol.session(),
            clientVersionProvider: { "1.0.3" })
        let snapshot = try await client.fetch(accessToken: "token-for-tests", now: now)

        #expect(snapshot.includedUsagePercent == 10)
        #expect(snapshot.resetCredits?.availableCount == 1)
        #expect(snapshot.resetCredits?.tokens.map(\.tokenID) == ["restok_client"])
        #expect(snapshot.resetCredits?.tokens.first?.validityEnd == Date(timeIntervalSince1970: 1_789_238_940))
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
        #expect(await recorder.headerValues("x-grok-client-identifier").allSatisfy {
            $0 == GrokCLIChatProxyIdentity.clientIdentifierValue
        })
        #expect(await recorder.headerValues("x-grok-client-mode").allSatisfy {
            $0 == GrokCLIChatProxyIdentity.clientModeValue
        })
        let resetRequests = await recorder.requests.filter {
            $0.url?.absoluteString.contains("GetRemainingResets") == true
        }
        #expect(resetRequests.count == 1)
        #expect(resetRequests[0].value(forHTTPHeaderField: "User-Agent") == "xai-grok-workspace/1.4.0")
        #expect(resetRequests[0].value(forHTTPHeaderField: "x-grok-client-version") == "1.4.0")
        #expect(
            resetRequests[0].value(forHTTPHeaderField: "x-grok-client-identifier")
                == GrokCLIChatProxyIdentity.clientIdentifierValue)
        #expect(
            resetRequests[0].value(forHTTPHeaderField: "x-grok-client-mode")
                == GrokCLIChatProxyIdentity.clientModeValue)
        #expect(
            resetRequests[0].value(forHTTPHeaderField: "X-XAI-Token-Auth")
                == GrokCLIChatProxyIdentity.tokenAuthValue)
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

    @Test("post-reset credits without percent stay weekly zero and still merge USD cents")
    func postResetCreditsZeroUsedMergesUSDWithoutMonthlyPercent() async throws {
        // After weekly reset the credits shape has currentPeriod but omits
        // creditUsagePercent. Cents still carry monthly USD used/limit for a
        // different window — percent must not become used/limit.
        MockBillingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let body: Data
            if path.hasSuffix("/billing"), query.contains("format=credits") {
                body = Data(#"""
                {
                  "config": {
                    "currentPeriod": {
                      "type": "USAGE_PERIOD_TYPE_WEEKLY",
                      "start": "2026-08-06T16:46:56.082611+00:00",
                      "end": "2026-08-13T16:46:56.082611+00:00"
                    },
                    "prepaidBalance": {"val": 0},
                    "isUnifiedBillingUser": true
                  }
                }
                """#.utf8)
            } else if path.hasSuffix("/billing") {
                body = Data(#"""
                {
                  "config": {
                    "monthlyLimit": {"val": 15000},
                    "used": {"val": 2362},
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

        #expect(snapshot.includedUsagePercent == 0)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.source == .current)
        #expect(snapshot.includedLimitCents == 15_000)
        #expect(snapshot.includedUsedCents == 2_362)
        #expect(snapshot.includedRemainingCents == 12_638)
        #expect(snapshot.plan == "SuperGrok")
        // Must not be the monthly cents fallback (~15.75% used → ~84% left).
        #expect(snapshot.includedUsagePercent != Double(2_362) / Double(15_000) * 100)
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
