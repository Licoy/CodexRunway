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

    @Test("workspace request sends auth context and ignores HTTP failure")
    func fetchesWorkspaceNameBestEffort() async throws {
        let session = WorkspaceMetadataURLProtocol.session()
        let client = QuotaClient(session: session)
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                accessToken: "test-access-token-not-for-production",
                refreshToken: "",
                accountId: "workspace-selected"),
            lastRefresh: nil)

        WorkspaceMetadataURLProtocol.statusCode = 200
        WorkspaceMetadataURLProtocol.responseData = Data(
            #"{"items":[{"id":"workspace-selected","name":"Selected Workspace"}]}"#.utf8)
        let name = await client.fetchWorkspaceName(auth: auth)
        #expect(name == "Selected Workspace")
        let request = try #require(WorkspaceMetadataURLProtocol.lastRequest)
        #expect(request.url?.path == "/backend-api/accounts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token-not-for-production")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-selected")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexRunway/1")

        let conflictingAuth = CodexAuth(
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
        let conflictingName = await client.fetchWorkspaceName(auth: conflictingAuth)
        #expect(conflictingName == "Selected Workspace")
        let conflictingRequest = try #require(WorkspaceMetadataURLProtocol.lastRequest)
        #expect(conflictingRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-selected")

        WorkspaceMetadataURLProtocol.statusCode = 403
        WorkspaceMetadataURLProtocol.responseData = Data(#"{"error":"challenge"}"#.utf8)
        let failedName = await client.fetchWorkspaceName(auth: auth)
        #expect(failedName == nil)
    }

    private static func jwt(payload: [String: Any]) -> String {
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

private final class WorkspaceMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.statusCode == 403 ? ["cf-mitigated": "challenge"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
