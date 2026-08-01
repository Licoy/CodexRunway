import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok account paste importer")
struct GrokAccountImporterTests {
    @Test("parses full ~/.grok/auth.json OAuth payload")
    func parsesFullAuthJSON() throws {
        let text = """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "email": "paste@example.com",
                "expires_at": "2099-08-01T12:00:00Z",
                "key": "paste-access-token-for-tests-only",
                "oidc_client_id": "desktop-client",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "principal-paste",
                "refresh_token": "paste-refresh-token-for-tests-only",
                "user_id": "user-paste"
              }
            }
            """
        let payloads = GrokAccountImporter().parsePayloads(from: text)
        #expect(payloads.count == 1)
        let document = try GrokAuthDocument.parse(payloads[0])
        #expect(document.identity.email == "paste@example.com")
        #expect(document.identity.hasAccessToken)
        #expect(document.identity.hasRefreshToken)
        #expect(document.identity.kind == .oauth)
    }

    @Test("wraps a bare credential object under the OAuth desktop scope")
    func wrapsBareCredentialObject() throws {
        let text = """
            {
              "email": "body@example.com",
              "key": "body-access-token-for-tests-only",
              "refresh_token": "body-refresh-token-for-tests-only",
              "user_id": "body-user",
              "principal_id": "body-principal"
            }
            """
        let payloads = GrokAccountImporter().parsePayloads(from: text)
        #expect(payloads.count == 1)
        let document = try GrokAuthDocument.parse(payloads[0])
        #expect(document.identity.email == "body@example.com")
        #expect(document.identity.scope == "\(GrokAuthDocument.oauthScopePrefix)desktop-client")
        #expect(document.identity.kind == .oauth)
    }

    @Test("wraps legacy-style credential objects under the legacy scope")
    func wrapsLegacyCredentialObject() throws {
        let text = """
            {
              "auth_mode": "web_login",
              "email": "legacy-paste@example.com",
              "key": "legacy-session-for-tests-only",
              "user_id": "legacy-paste-user"
            }
            """
        let payloads = GrokAccountImporter().parsePayloads(from: text)
        #expect(payloads.count == 1)
        let document = try GrokAuthDocument.parse(payloads[0])
        #expect(document.identity.kind == .legacySession)
        #expect(document.identity.scope == GrokAuthDocument.legacyScope)
    }

    @Test("imports a JSON array of credential objects as multiple accounts")
    func parsesCredentialArray() throws {
        let text = """
            [
              {
                "email": "one@example.com",
                "key": "access-one-for-tests-only",
                "refresh_token": "refresh-one-for-tests-only",
                "user_id": "user-one",
                "principal_id": "principal-one"
              },
              {
                "email": "two@example.com",
                "key": "access-two-for-tests-only",
                "refresh_token": "refresh-two-for-tests-only",
                "user_id": "user-two",
                "principal_id": "principal-two"
              }
            ]
            """
        let payloads = GrokAccountImporter().parsePayloads(from: text)
        #expect(payloads.count == 2)
        let emails = try payloads.map { try GrokAuthDocument.parse($0).identity.email }
        #expect(Set(emails) == Set(["one@example.com", "two@example.com"]))
    }

    @Test("recovers JSON when paste includes surrounding notes")
    func recoversJSONFromSurroundingNotes() throws {
        let text = """
            here is my grok auth:
            {
              "email": "notes@example.com",
              "key": "notes-access-token-for-tests-only",
              "user_id": "notes-user",
              "refresh_token": "notes-refresh-for-tests-only"
            }
            thanks
            """
        let payloads = GrokAccountImporter().parsePayloads(from: text)
        #expect(payloads.count == 1)
        let document = try GrokAuthDocument.parse(payloads[0])
        #expect(document.identity.email == "notes@example.com")
    }

    @Test("rejects API-key-only and unrecognized JSON")
    func rejectsUnsupportedShapes() {
        let importer = GrokAccountImporter()
        #expect(importer.parsePayloads(from: #"{"hello":"world"}"#).isEmpty)
        #expect(importer.parsePayloads(from: #"{"xai::api_key":{"auth_mode":"api_key","key":"xai-key"}}"#).isEmpty)
        #expect(importer.parsePayloads(from: "just-a-bare-token-without-identity-fields").isEmpty)
        #expect(importer.parsePayloads(from: #"{"key":"token-only-no-identity"}"#).isEmpty)
    }

    @Test("module import upserts pasted credentials into the Grok account store")
    func moduleImportsPastedCredentials() async throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let text = """
            {
              "email": "import@example.com",
              "key": "import-access-token-for-tests-only",
              "refresh_token": "import-refresh-token-for-tests-only",
              "user_id": "import-user",
              "principal_id": "import-principal"
            }
            """
        let (batch, state) = try await module.importPastedText(text)

        #expect(batch.successCount == 1)
        #expect(batch.failureCount == 0)
        let account = try #require(batch.succeeded.first)
        #expect(account.email == "import@example.com")
        #expect(state.accounts.map(\.id) == [account.id])
        // First managed account with no official login is installed as current.
        #expect(state.currentAccountID == account.id)
        #expect(try fixture.store.loadOfficialCredentialData().isEmpty == false)
        let official = try GrokAuthDocument.parse(fixture.store.loadOfficialCredentialData())
        #expect(official.identity.email == "import@example.com")
    }

    @Test("module reports no_credentials for unrecognized paste")
    func moduleReportsNoCredentials() async throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let (batch, _) = try await module.importPastedText(#"{"hello":"world"}"#)
        #expect(batch.successCount == 0)
        #expect(batch.failures == ["no_credentials"])
    }

    @Test("module deduplicates the same identity on re-import")
    func moduleDeduplicatesIdentity() async throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let text = """
            {
              "email": "dup@example.com",
              "key": "dup-access-v1-for-tests-only",
              "refresh_token": "dup-refresh-v1-for-tests-only",
              "user_id": "dup-user",
              "principal_id": "dup-principal"
            }
            """
        let (first, _) = try await module.importPastedText(text)
        let rotated = """
            {
              "email": "dup@example.com",
              "key": "dup-access-v2-for-tests-only",
              "refresh_token": "dup-refresh-v2-for-tests-only",
              "user_id": "dup-user",
              "principal_id": "dup-principal"
            }
            """
        let (second, state) = try await module.importPastedText(rotated)

        #expect(first.successCount == 1)
        #expect(second.successCount == 1)
        #expect(state.accounts.count == 1)
        let credentialText = try String(
            contentsOf: fixture.store.credentialURL(id: first.succeeded[0].id),
            encoding: .utf8)
        #expect(credentialText.contains("dup-access-v2-for-tests-only"))
    }

    private var unusedCLI: GrokCLIClient {
        GrokCLIClient(
            billing: { _ in
                GrokQuotaSnapshot(
                    plan: "SuperGrok",
                    includedUsagePercent: 10,
                    period: GrokQuotaPeriod(kind: .weekly, startsAt: nil, resetsAt: nil),
                    prepaidBalanceCents: nil,
                    onDemandEnabled: false,
                    onDemandUsedCents: nil,
                    onDemandLimitCents: nil,
                    productUsage: [],
                    source: .current,
                    updatedAt: Date(timeIntervalSince1970: 1_785_499_200))
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
    }

    private struct ModuleFixture {
        let root: URL
        let store: GrokAccountStore
        let now: Date

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-runway-grok-import-\(UUID().uuidString)", isDirectory: true)
            let accounts = root.appendingPathComponent("accounts", isDirectory: true)
            let official = root.appendingPathComponent("official", isDirectory: true)
            try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: official, withIntermediateDirectories: true)
            store = GrokAccountStore(rootURL: accounts, officialHomeURL: official)
            now = Date(timeIntervalSince1970: 1_785_499_200)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
