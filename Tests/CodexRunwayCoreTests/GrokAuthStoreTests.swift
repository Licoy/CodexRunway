import Darwin
import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok auth and account store")
struct GrokAuthStoreTests {
    @Test("parses current xAI OAuth credentials without changing their bytes")
    func parsesCurrentOAuthCredential() throws {
        let data = Data(
            """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "create_time": "2026-07-30T12:00:00Z",
                "email": "person@example.com",
                "expires_at": "2099-08-01T12:00:00Z",
                "key": "test-access-token-not-a-secret",
                "oidc_client_id": "desktop-client",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "principal-123",
                "principal_type": "User",
                "refresh_token": "test-refresh-token-not-a-secret",
                "team_id": "team-456",
                "team_name": "Example Team",
                "user_id": "user-789"
              }
            }
            """.utf8)

        let document = try GrokAuthDocument.parse(data)

        #expect(document.rawData == data)
        #expect(document.identity.kind == .oauth)
        #expect(document.identity.email == "person@example.com")
        #expect(document.identity.principalID == "principal-123")
        #expect(document.identity.teamID == "team-456")
        #expect(document.stableID.hasPrefix("grok-"))
        #expect(document.requiresReauthentication(at: Date(timeIntervalSince1970: 1_800_000_000)) == false)
    }

    @Test("parses the known legacy Grok session scope")
    func parsesLegacySessionCredential() throws {
        let data = Data(
            """
            {
              "https://accounts.x.ai/sign-in": {
                "auth_mode": "grok",
                "create_time": "2025-01-01T00:00:00Z",
                "email": "legacy@example.com",
                "key": "test-legacy-session-not-a-secret",
                "user_id": "legacy-user"
              }
            }
            """.utf8)

        let document = try GrokAuthDocument.parse(data)

        #expect(document.identity.kind == .legacySession)
        #expect(document.identity.userID == "legacy-user")
        #expect(document.managedScopeKeys == [GrokAuthDocument.legacyScope])
    }

    @Test("keeps the stable identity when a legacy session is upgraded to OAuth")
    func keepsStableIdentityAcrossAuthUpgrade() throws {
        let legacy = try GrokAuthDocument.parse(Data(
            """
            {
              "https://accounts.x.ai/sign-in": {
                "auth_mode": "web_login",
                "email": "upgrade@example.com",
                "key": "legacy-session-for-tests-only",
                "user_id": "upgrade-user"
              }
            }
            """.utf8))
        let oauth = try GrokAuthDocument.parse(Self.oauthCredentialData(
            email: "upgrade@example.com",
            userID: "upgrade-user",
            principalID: "newly-enriched-principal",
            accessToken: "oauth-access-for-tests-only",
            refreshToken: "oauth-refresh-for-tests-only"))

        #expect(legacy.stableID == oauth.stableID)
    }

    @Test("does not treat an API-key-only auth file as a managed account")
    func excludesAPIKeyOnlyCredential() throws {
        let data = Data(
            """
            {
              "xai::api_key": {
                "auth_mode": "api_key",
                "key": "test-api-key-not-a-secret",
                "user_id": ""
              }
            }
            """.utf8)

        #expect(throws: GrokAuthDocumentError.noManagedCredential) {
            try GrokAuthDocument.parse(data)
        }
    }

    @Test("replaces only Grok login scopes and preserves official API-key and unknown scopes")
    func mergesManagedScopesForAccountSwitch() throws {
        let official = Data(
            """
            {
              "https://auth.x.ai::old-client": {
                "auth_mode": "oidc",
                "email": "old@example.com",
                "key": "old-session",
                "user_id": "old-user"
              },
              "xai::api_key": {
                "auth_mode": "api_key",
                "key": "official-api-key"
              },
              "https://idp.example.com::custom-client": {
                "auth_mode": "oidc",
                "key": "official-custom-token",
                "user_id": "custom-user"
              }
            }
            """.utf8)
        let target = Data(
            """
            {
              "https://auth.x.ai::new-client": {
                "auth_mode": "oidc",
                "email": "new@example.com",
                "key": "new-session",
                "user_id": "new-user"
              },
              "https://accounts.x.ai/sign-in": {
                "auth_mode": "web_login",
                "email": "stale-legacy@example.com",
                "key": "stale-legacy-session",
                "user_id": "stale-legacy-user"
              },
              "xai::api_key": {
                "auth_mode": "api_key",
                "key": "target-api-key"
              }
            }
            """.utf8)

        let merged = try GrokAuthDocument.replacingManagedScopes(in: official, with: target)
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])

        #expect(root["https://auth.x.ai::old-client"] == nil)
        #expect(Self.string("key", in: root["https://auth.x.ai::new-client"]) == "new-session")
        #expect(root[GrokAuthDocument.legacyScope] == nil)
        #expect(Self.string("key", in: root[GrokAuthDocument.apiKeyScope]) == "official-api-key")
        #expect(Self.string("key", in: root["https://idp.example.com::custom-client"]) == "official-custom-token")
    }

    @Test("stores raw Grok credentials in a separate restricted account library")
    func storesCredentialDataAndSecretFreeIndex() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let accounts = temporary.appendingPathComponent("accounts", isDirectory: true)
        let officialHome = temporary.appendingPathComponent("official-grok", isDirectory: true)
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        let codexIndex = accounts.appendingPathComponent("index.json")
        try Data(#"{"version":1,"sentinel":"codex"}"#.utf8).write(to: codexIndex)
        let credential = Self.oauthCredentialData(
            email: "stored@example.com",
            userID: "stored-user",
            principalID: "stored-principal",
            accessToken: "stored-access-token-not-a-secret",
            refreshToken: "stored-refresh-token-not-a-secret")
        let now = Date(timeIntervalSince1970: 1_785_499_200)
        let store = GrokAccountStore(rootURL: accounts, officialHomeURL: officialHome)

        let account = try store.upsertCredentialData(credential, makeCurrent: true, now: now)

        #expect(account.id.hasPrefix("grok-"))
        #expect(try store.loadCredentialData(id: account.id) == credential)
        let index = try store.loadIndex()
        #expect(index.currentAccountID == account.id)
        #expect(index.accounts.map(\.id) == [account.id])
        #expect(store.indexURL.lastPathComponent == "grok-index.json")
        #expect(try Data(contentsOf: codexIndex) == Data(#"{"version":1,"sentinel":"codex"}"#.utf8))

        let indexText = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(indexText.contains("stored-access-token") == false)
        #expect(indexText.contains("stored-refresh-token") == false)
        #expect(Self.permissions(of: accounts) == 0o700)
        #expect(Self.permissions(of: store.accountDirectory(id: account.id)) == 0o700)
        #expect(Self.permissions(of: store.credentialURL(id: account.id)) == 0o600)
        #expect(Self.permissions(of: store.indexURL) == 0o600)
    }

    @Test("deduplicates a Grok identity when OAuth tokens rotate")
    func deduplicatesStableIdentity() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-dedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = GrokAccountStore(
            rootURL: temporary.appendingPathComponent("accounts", isDirectory: true),
            officialHomeURL: temporary.appendingPathComponent("official", isDirectory: true))
        let firstData = Self.oauthCredentialData(
            email: "same@example.com",
            userID: "same-user",
            principalID: "same-principal",
            accessToken: "first-access-token",
            refreshToken: "first-refresh-token")
        let rotatedData = Self.oauthCredentialData(
            email: "same@example.com",
            userID: "same-user",
            principalID: "same-principal",
            accessToken: "rotated-access-token",
            refreshToken: "rotated-refresh-token")

        let first = try store.upsertCredentialData(firstData)
        let rotated = try store.upsertCredentialData(rotatedData)

        #expect(rotated.id == first.id)
        #expect(try store.loadIndex().accounts.count == 1)
        #expect(try store.loadCredentialData(id: first.id) == rotatedData)
    }

    @Test("account removal restores the index and credential directory when cleanup fails")
    func accountRemovalRollsBackAfterCleanupFailure() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-remove-\(UUID().uuidString)", isDirectory: true)
        let store = GrokAccountStore(
            rootURL: temporary.appendingPathComponent("accounts", isDirectory: true),
            officialHomeURL: temporary.appendingPathComponent("official", isDirectory: true))
        let currentData = Self.oauthCredentialData(
            email: "current@example.com",
            userID: "current-user",
            principalID: "current-principal",
            accessToken: "current-access-token",
            refreshToken: "current-refresh-token")
        let removableData = Self.oauthCredentialData(
            email: "removable@example.com",
            userID: "removable-user",
            principalID: "removable-principal",
            accessToken: "removable-access-token",
            refreshToken: "removable-refresh-token")
        let current = try store.upsertCredentialData(currentData, makeCurrent: true)
        let removable = try store.upsertCredentialData(removableData)
        let credentialURL = store.credentialURL(id: removable.id)
        let blockerURL = store.accountDirectory(id: removable.id)
            .appendingPathComponent("zz-immutable-blocker")
        try Data("blocker".utf8).write(to: blockerURL)
        guard chflags(blockerURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer {
            if let children = try? FileManager.default.contentsOfDirectory(
                at: store.rootURL,
                includingPropertiesForKeys: nil)
            {
                for child in children where child.lastPathComponent.hasPrefix(".grok-remove-") {
                    _ = chflags(child.appendingPathComponent("zz-immutable-blocker").path, 0)
                }
            }
            _ = chflags(blockerURL.path, 0)
            try? FileManager.default.removeItem(at: temporary)
        }

        #expect(throws: GrokAccountError.io("Unable to remove the Grok account.")) {
            try store.remove(id: removable.id)
        }

        let restoredIndex = try store.loadIndex()
        #expect(restoredIndex.currentAccountID == current.id)
        #expect(restoredIndex.account(id: removable.id) != nil)
        #expect(try store.loadCredentialData(id: removable.id) == removableData)
        #expect(FileManager.default.fileExists(atPath: store.accountDirectory(id: removable.id).path))
        #expect(Self.permissions(of: credentialURL) == 0o600)
    }

    @Test("resolves the official Grok home from GROK_HOME before the user home fallback")
    func resolvesOfficialHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(
            GrokAccountStore.resolveOfficialHome(
                environment: ["GROK_HOME": "/Volumes/isolated-grok"],
                homeDirectory: home).path == "/Volumes/isolated-grok")
        #expect(
            GrokAccountStore.resolveOfficialHome(
                environment: [:],
                homeDirectory: home).path == "/Users/example/.grok")
        #expect(
            GrokAccountStore.resolveOfficialHome(
                environment: ["GROK_HOME": "~/alternate-grok"],
                homeDirectory: home).path == "/Users/example/alternate-grok")
    }

    @Test("reports missing, API-key-only, and expired official credential states without exposing tokens")
    func reportsOfficialCredentialStatus() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let officialHome = temporary.appendingPathComponent("official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialHome, withIntermediateDirectories: true)
        let store = GrokAccountStore(
            rootURL: temporary.appendingPathComponent("accounts", isDirectory: true),
            officialHomeURL: officialHome)

        #expect(store.loadOfficialCredentialStatus() == .missing)

        try Data(
            #"{"xai::api_key":{"auth_mode":"api_key","key":"api-key-for-tests-only"}}"#.utf8)
            .write(to: store.officialAuthURL)
        #expect(store.loadOfficialCredentialStatus() == .apiKeyOnly)

        let expired = Data(
            """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "email": "expired@example.com",
                "expires_at": "2020-01-01T00:00:00Z",
                "key": "expired-access-for-tests-only",
                "user_id": "expired-user"
              }
            }
            """.utf8)
        try expired.write(to: store.officialAuthURL)
        let status = store.loadOfficialCredentialStatus(
            now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .requiresReauthentication(identity) = status else {
            Issue.record("Expected an expired credential status")
            return
        }
        #expect(identity.email == "expired@example.com")
        #expect(identity.hasAccessToken)
        #expect(identity.hasRefreshToken == false)
    }

    private static func string(_ key: String, in object: Any?) -> String? {
        (object as? [String: Any])?[key] as? String
    }

    private static func oauthCredentialData(
        email: String,
        userID: String,
        principalID: String,
        accessToken: String,
        refreshToken: String) -> Data
    {
        Data(
            """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "create_time": "2026-07-30T12:00:00Z",
                "email": "\(email)",
                "expires_at": "2099-08-01T12:00:00Z",
                "key": "\(accessToken)",
                "oidc_client_id": "desktop-client",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "\(principalID)",
                "principal_type": "User",
                "refresh_token": "\(refreshToken)",
                "user_id": "\(userID)"
              }
            }
            """.utf8)
    }

    private static func permissions(of url: URL) -> UInt16? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber
        else {
            return nil
        }
        return value.uint16Value
    }
}
