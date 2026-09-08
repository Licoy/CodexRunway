import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Account switcher")
struct AccountSwitcherTests {
    @Test("re-applying the listed current account overwrites drifted official auth")
    func reappliesListedCurrentOverDriftedOfficial() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-switcher-\(UUID().uuidString)", isDirectory: true)
        let official = root.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: official)
        let currentAuth = sampleAuth(accountId: "acct-current", email: "current@example.com", refresh: "refresh-current")
        let driftedAuth = sampleAuth(accountId: "acct-drifted", email: "drifted@example.com", refresh: "refresh-drifted")
        let current = try store.upsert(auth: currentAuth, makeActive: true)
        try store.saveOfficialAuth(currentAuth)
        try store.saveOfficialAuth(driftedAuth)

        #expect(try store.loadIndex().activeAccountId == current.id)
        #expect(try store.loadOfficialAuth().tokens.accountId == "acct-drifted")

        let result = try await AccountSwitcher(store: store, fetchQuota: { try await SwitchQuotaURLProtocol.client().fetchQuota(auth: $0) })
            .switchTo(accountId: current.id)

        #expect(result.account.id == current.id)
        #expect(try store.loadIndex().activeAccountId == current.id)
        #expect(try store.loadOfficialAuth().tokens.accountId == "acct-current")
        #expect(try store.loadOfficialAuth().tokens.refreshToken.hasPrefix("refresh-current"))
    }

    @Test("revoked target preserves official login and marks the target for reauthorization")
    func revokedTargetDoesNotReplaceCurrentLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent("auth.json")
        let store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: official)
        let currentAuth = sampleAuth(accountId: "current", email: "current@example.com", refresh: "refresh-current")
        let current = try store.upsert(auth: currentAuth, makeActive: true)
        let target = try store.upsert(auth: sampleAuth(accountId: "revoked", email: "target@example.com", refresh: "refresh-target"))
        try store.saveOfficialAuth(currentAuth)
        let before = try Data(contentsOf: official)
        let switcher = AccountSwitcher(store: store, fetchQuota: { try await SwitchQuotaURLProtocol.client(status: 401).fetchQuota(auth: $0) })

        await #expect(throws: URLError(.userAuthenticationRequired)) {
            try await switcher.switchTo(accountId: target.id)
        }

        #expect(try Data(contentsOf: official) == before)
        #expect(try store.loadIndex().activeAccountId == current.id)
        #expect(try store.loadIndex().account(id: target.id)?.requiresReauth == true)
    }

    @Test("quota refresh recognizes revoked auth and clears stale quota")
    func revokedQuotaClearsStaleMeters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: root.appendingPathComponent("auth.json"))
        let account = try store.upsert(auth: sampleAuth(accountId: "target", email: "target@example.com", refresh: "refresh-target"))
        let client = SwitchQuotaURLProtocol.client()
        let quota = try await client.fetchQuota(auth: store.loadCredential(id: account.id))
        try store.updateMetadata(account.applying(quota: quota))
        let refresher = AccountQuotaRefresher(
            store: store,
            switcher: AccountSwitcher(store: store),
            quotaClient: SwitchQuotaURLProtocol.client(status: 401))

        _ = await refresher.refresh(accountId: account.id)
        let updated = try #require(store.loadIndex().account(id: account.id))
        #expect(updated.requiresReauth)
        #expect(updated.cachedQuota == nil)
        #expect(updated.lastQuotaAt == nil)
    }

    @Test("permission, rate limit and server errors do not request account deletion", arguments: [403, 429, 500])
    func nonAuthenticationFailuresRemainDistinct(status: Int) async throws {
        let auth = sampleAuth(accountId: "target", email: "target@example.com", refresh: "refresh-target")
        await #expect(throws: URLError(.badServerResponse)) {
            try await SwitchQuotaURLProtocol.client(status: status).fetchQuota(auth: auth)
        }
    }

    private func sampleAuth(accountId: String, email: String, refresh: String) -> CodexAuth {
        let idToken = jwt(payload: [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountId,
                "chatgpt_plan_type": "plus",
            ],
        ])
        let refreshToken = refresh.count >= 20 ? refresh : (refresh + String(repeating: "x", count: 24))
        return CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: idToken,
                accessToken: jwt(payload: ["exp": 4_100_000_000]),
                refreshToken: refreshToken,
                accountId: accountId),
            lastRefresh: nil,
            planType: "plus")
    }

    private func jwt(payload: [String: Any]) -> String {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [header, payloadData, Data()]
            .map {
                $0.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            .joined(separator: ".")
    }
}

/// Per-session responses avoid shared mutable state and never reach a real account endpoint.
final class SwitchQuotaURLProtocol: URLProtocol {
    static func client(status: Int = 200) -> QuotaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwitchQuotaURLProtocol.self]
        return QuotaClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://status-\(status).invalid/backend-api")!)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url!.host!.split(separator: ".")[0].dropFirst("status-".count))!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let body = status == 200
            ? #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"reset_at":4100000000,"limit_window_seconds":18000}}}"#
            : #"{"error":{"code":"token_revoked","message":"Test-only revoked credential"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
