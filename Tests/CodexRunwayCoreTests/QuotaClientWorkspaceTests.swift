import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Workspace metadata client", .serialized)
struct QuotaClientWorkspaceTests {
    @Test("workspace response matches the selected account id exactly")
    func decodesExactWorkspaceName() throws {
        let data = Data(#"{"items":[{"id":"workspace-a","name":" Alpha "},{"id":"workspace-b","name":"Beta"}]}"#.utf8)
        #expect(try QuotaClient.decodeWorkspaceName(from: data, accountId: "workspace-a") == "Alpha")
        #expect(try QuotaClient.decodeWorkspaceName(from: data, accountId: "workspace") == nil)

        let empty = Data(#"{"items":[{"id":"workspace-a","name":"   "},{"id":"workspace-b","name":null}]}"#.utf8)
        #expect(try QuotaClient.decodeWorkspaceName(from: empty, accountId: "workspace-a") == nil)
        #expect(try QuotaClient.decodeWorkspaceName(from: empty, accountId: "workspace-b") == nil)
    }

    @Test("workspace request sends selected auth context and reports HTTP failure")
    func fetchesWorkspaceNameBestEffort() async throws {
        let session = WorkspaceMetadataURLProtocol.session()
        let client = QuotaClient(session: session)
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [
                    "https://api.openai.com/auth": [
                        "chatgpt_account_id": "workspace-stale-claim",
                    ],
                ]),
                accessToken: "test-access-token-not-for-production",
                refreshToken: "",
                accountId: "workspace-selected"),
            lastRefresh: nil)

        WorkspaceMetadataURLProtocol.statusCode = 200
        WorkspaceMetadataURLProtocol.responseData = Data(
            #"{"items":[{"id":"workspace-selected","name":"Selected Workspace"}]}"#.utf8)
        let name = try await client.fetchWorkspaceName(auth: auth)
        #expect(name == "Selected Workspace")
        let request = try #require(WorkspaceMetadataURLProtocol.lastRequest)
        #expect(request.url?.path == "/backend-api/accounts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token-not-for-production")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-selected")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexRunway/1")

        WorkspaceMetadataURLProtocol.statusCode = 403
        WorkspaceMetadataURLProtocol.responseData = Data(#"{"error":"challenge"}"#.utf8)
        await #expect(throws: URLError.self) {
            try await client.fetchWorkspaceName(auth: auth)
        }
    }

    @Test("workspace metadata failure does not discard a successful quota refresh")
    func quotaRefreshKeepsQuotaWhenWorkspaceMetadataFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-workspace-metadata-\(UUID().uuidString)", isDirectory: true)
        defer {
            WorkspaceMetadataURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [
                    "email": "team@example.com",
                    "https://api.openai.com/auth": [
                        "chatgpt_account_id": "workspace-selected",
                        "chatgpt_plan_type": "team",
                        "chatgpt_user_id": "user-team",
                    ],
                ]),
                accessToken: Self.jwt(payload: ["exp": 4_100_000_000]),
                refreshToken: "workspace-metadata-refresh-token",
                accountId: "workspace-selected"),
            lastRefresh: nil,
            planType: "team")
        let account = try store.upsert(auth: auth)
        WorkspaceMetadataURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/wham/usage") == true {
                return (200, Data(
                    #"{"plan_type":"team","rate_limit":{"primary_window":{"used_percent":25,"reset_at":4100000000,"limit_window_seconds":18000}}}"#.utf8))
            }
            return (403, Data(#"{"error":"challenge"}"#.utf8))
        }
        let client = QuotaClient(session: WorkspaceMetadataURLProtocol.session())
        let refresher = AccountQuotaRefresher(
            store: store,
            switcher: AccountSwitcher(store: store),
            quotaClient: client,
            maxConcurrent: 1)

        let result = await refresher.refresh(accountId: account.id)
        let stored = try #require(try store.loadIndex().account(id: account.id))

        #expect(result.errorDescription == "workspace_metadata_unavailable")
        #expect(result.account?.cachedQuota?.primaryUsedPercent == 25)
        #expect(stored.cachedQuota?.primaryUsedPercent == 25)
        #expect(stored.workspaceName == nil)
        #expect(stored.lastError == nil)
        #expect(!stored.requiresReauth)
    }

    private static func jwt(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
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

private final class WorkspaceMetadataURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let stub = Self.handler?(request) ?? (Self.statusCode, Self.responseData)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.0,
            httpVersion: "HTTP/1.1",
            headerFields: stub.0 == 403 ? ["cf-mitigated": "challenge"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
