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

        let result = try await AccountSwitcher(store: store).switchTo(accountId: current.id)

        #expect(result.account.id == current.id)
        #expect(try store.loadIndex().activeAccountId == current.id)
        #expect(try store.loadOfficialAuth().tokens.accountId == "acct-current")
        #expect(try store.loadOfficialAuth().tokens.refreshToken.hasPrefix("refresh-current"))
    }

    @Test("removing an inactive account keeps official auth and the other credentials")
    func removesOnlySelectedAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent("auth.json")
        let store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: official)
        let auth = sampleAuth(accountId: "current", email: "current@example.com", refresh: "refresh-current")
        let current = try store.upsert(auth: auth, makeActive: true)
        let removed = try store.upsert(auth: sampleAuth(accountId: "removed", email: "removed@example.com", refresh: "refresh-removed"))
        try store.saveOfficialAuth(auth)
        let before = try Data(contentsOf: official)

        try store.deleteAccount(id: removed.id)

        #expect(try Data(contentsOf: official) == before)
        #expect(try store.loadIndex().accounts.map(\.id) == [current.id])
        #expect(try store.loadIndex().activeAccountId == current.id)
        #expect(!FileManager.default.fileExists(atPath: store.credentialURL(id: removed.id).path))
        #expect(FileManager.default.fileExists(atPath: store.credentialURL(id: current.id).path))
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
