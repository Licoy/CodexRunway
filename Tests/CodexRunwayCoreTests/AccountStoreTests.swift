import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Multi-account store")
struct AccountStoreTests {
    @Test("upserts accounts, stores credentials with restricted permissions, and switches active")
    func upsertsAndSwitches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-accounts-\(UUID().uuidString)", isDirectory: true)
        let official = root.appendingPathComponent("official-auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: official)
        let authA = sampleAuth(accountId: "acct-a", email: "a@example.com", refresh: "refresh-a")
        let authB = sampleAuth(accountId: "acct-b", email: "b@example.com", refresh: "refresh-b")

        let accountA = try store.upsert(auth: authA, makeActive: true)
        let accountB = try store.upsert(auth: authB, makeActive: false)
        #expect(accountA.accountId == "acct-a")
        #expect(accountA.id != accountB.id)
        #expect(accountB.email == "b@example.com")

        var index = try store.loadIndex()
        #expect(index.accounts.count == 2)
        #expect(index.activeAccountId == accountA.id)

        let credURL = store.credentialURL(id: accountA.id)
        let perms = try FileManager.default.attributesOfItem(atPath: credURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.uint16Value == 0o600)

        let loaded = try store.loadCredential(id: accountA.id)
        #expect(loaded.tokens.refreshToken.hasPrefix("refresh-a"))
        #expect(loaded.redactedDescription.contains("refresh-a") == false)

        try store.saveOfficialAuth(authB)
        try store.setActiveAccountId(accountB.id)
        index = try store.loadIndex()
        #expect(index.activeAccountId == accountB.id)

        let officialLoaded = try store.loadOfficialAuth()
        #expect(officialLoaded.tokens.accountId == "acct-b")
    }

    @Test("deduplicates by account identity on re-import")
    func deduplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-dedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let first = try store.upsert(
            auth: sampleAuth(accountId: "same", email: "same@example.com", refresh: "rt-1"),
            makeActive: true)
        let second = try store.upsert(
            auth: sampleAuth(accountId: "same", email: "same@example.com", refresh: "rt-2"),
            makeActive: false)

        #expect(first.id == second.id)
        let index = try store.loadIndex()
        #expect(index.accounts.count == 1)
        let cred = try store.loadCredential(id: first.id)
        #expect(cred.tokens.refreshToken.hasPrefix("rt-2"))
    }

    @Test("keeps different users in the same workspace as separate managed accounts")
    func separatesUsersInSameWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-same-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let firstAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "member-a@example.com",
            refresh: "refresh-member-a",
            userId: "user-Aa1")
        let secondAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "member-b@example.com",
            refresh: "refresh-member-b",
            userId: "user-Bb2")

        let first = try store.upsert(auth: firstAuth, makeActive: true)
        let second = try store.upsert(auth: secondAuth)

        #expect(first.id != second.id)
        #expect(first.userId == "user-Aa1")
        #expect(second.userId == "user-Bb2")
        #expect(first.identityMarkerUserId != second.identityMarkerUserId)
        #expect(try store.loadIndex().accounts.count == 2)
        #expect(try store.loadCredential(id: first.id).tokens.refreshToken.hasPrefix("refresh-member-a"))
        #expect(try store.loadCredential(id: second.id).tokens.refreshToken.hasPrefix("refresh-member-b"))
    }

    @Test("keeps one user in different workspaces as separate managed accounts")
    func separatesWorkspacesForSameUser() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-multi-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let first = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-shared-workspaces",
            userId: "user-shared",
            claimAccountId: "workspace-stale-claim"))
        let second = try store.upsert(auth: sampleAuth(
            accountId: "workspace-two",
            email: "member@example.com",
            refresh: "refresh-shared-workspaces",
            userId: "user-shared",
            claimAccountId: "workspace-stale-claim"))

        #expect(first.id != second.id)
        #expect(first.userId == second.userId)
        #expect(first.accountId != second.accountId)
        #expect(first.identityMarkerWorkspaceId != second.identityMarkerWorkspaceId)
        #expect(try store.loadIndex().accounts.count == 2)
        #expect(try store.loadCredential(id: first.id).tokens.accountId == "workspace-one")
        #expect(try store.loadCredential(id: second.id).tokens.accountId == "workspace-two")
    }

    @Test("same user and workspace re-import updates the existing credential")
    func updatesSameCompoundIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-compound-dedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let first = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-original-token",
            userId: "user-one"))
        let second = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "renamed@example.com",
            refresh: "refresh-rotated-token",
            userId: "user-one"))

        #expect(first.id == second.id)
        #expect(try store.loadIndex().accounts.count == 1)
        #expect(try store.loadCredential(id: first.id).tokens.refreshToken == "refresh-rotated-token")
    }

    @Test("subject fallback upgrades without duplication when user id becomes available")
    func upgradesLegacyIdentityWithNewUserId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-legacy-user-upgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let legacyAuth = sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-before-user-id",
            subject: "legacy-subject")
        let legacy = ManagedAccount(
            id: "legacy-subject-row",
            email: "member@example.com",
            userId: "legacy-subject",
            accountId: "workspace-one",
            displayName: "member@example.com")
        try store.saveCredential(id: legacy.id, auth: legacyAuth)
        try store.saveIndex(AccountIndex(activeAccountId: legacy.id, accounts: [legacy]))

        let migrated = try #require(try store.loadIndex().account(id: legacy.id))
        #expect(migrated.userId == nil)
        #expect(migrated.subjectId == "legacy-subject")

        let upgraded = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-after-user-id",
            userId: "user-one",
            subject: "legacy-subject"))

        #expect(upgraded.id == legacy.id)
        #expect(upgraded.userId == "user-one")
        #expect(try store.loadIndex().accounts.count == 1)
        #expect(try store.loadCredential(id: legacy.id).tokens.refreshToken == "refresh-after-user-id")

        let refreshedWithoutExplicitUser = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-without-explicit-user",
            subject: "legacy-subject"))
        #expect(refreshedWithoutExplicitUser.id == upgraded.id)
        #expect(refreshedWithoutExplicitUser.userId == "user-one")
        #expect(try store.loadIndex().accounts.count == 1)

        let differentSubject = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-different-subject",
            userId: "user-two",
            subject: "different-subject"))
        #expect(differentSubject.id != upgraded.id)
        #expect(try store.loadIndex().accounts.count == 2)
        #expect(try store.loadCredential(id: upgraded.id).tokens.refreshToken == "refresh-without-explicit-user")

        let differentSubjectOnly = try store.upsert(auth: sampleAuth(
            accountId: "workspace-one",
            email: "member@example.com",
            refresh: "refresh-different-subject-only",
            subject: "subject-without-explicit-user"))
        #expect(differentSubjectOnly.id != upgraded.id)
        #expect(try store.loadIndex().accounts.count == 3)
        #expect(try store.loadCredential(id: upgraded.id).tokens.refreshToken == "refresh-without-explicit-user")
    }

    @Test("hydrates legacy identity metadata without moving the managed credential")
    func hydratesLegacyIdentityInPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-legacy-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let auth = sampleAuth(
            accountId: "workspace-selected",
            email: "legacy@example.com",
            refresh: "refresh-legacy-token",
            userId: "legacy-user",
            workspaceName: "Unrelated Organization Title")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = ManagedAccount(
            id: "legacy-row-id",
            sortIndex: 7,
            email: "legacy@example.com",
            userId: nil,
            accountId: "stale-claim-workspace",
            displayName: "Legacy",
            alias: "Keep me",
            note: "Keep note",
            createdAt: createdAt)
        try store.saveCredential(id: legacy.id, auth: auth)
        try store.saveIndex(AccountIndex(activeAccountId: legacy.id, accounts: [legacy]))

        let hydrated = try #require(try store.loadIndex().account(id: legacy.id))
        #expect(hydrated.userId == "legacy-user")
        #expect(hydrated.accountId == "workspace-selected")
        #expect(hydrated.workspaceName == nil)
        #expect(hydrated.alias == "Keep me")
        #expect(hydrated.note == "Keep note")
        #expect(hydrated.sortIndex == 7)
        #expect(hydrated.createdAt == createdAt)

        let updated = try store.upsert(auth: auth)
        let updatedIndex = try store.loadIndex()
        #expect(updated.id == legacy.id)
        #expect(updatedIndex.activeAccountId == legacy.id)
        #expect(updatedIndex.accounts.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.credentialURL(id: legacy.id).path))
    }

    @Test("legacy hydration exposes a missing credential")
    func legacyHydrationReportsMissingCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-missing-legacy-credential-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let legacy = ManagedAccount(
            id: "missing-credential",
            displayName: "Missing Credential")
        try store.saveIndex(AccountIndex(accounts: [legacy]))

        let loaded = try #require(try store.loadIndex().account(id: legacy.id))

        #expect(loaded.requiresReauth)
        #expect(loaded.lastError == "credential_missing")
    }

    @Test("legacy hydration exposes an invalid credential without decoding details")
    func legacyHydrationReportsInvalidCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-invalid-legacy-credential-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let legacy = ManagedAccount(
            id: "invalid-credential",
            displayName: "Invalid Credential")
        try store.saveIndex(AccountIndex(accounts: [legacy]))
        try FileManager.default.createDirectory(
            at: store.accountDirectory(id: legacy.id),
            withIntermediateDirectories: true)
        try Data("not valid auth json".utf8).write(to: store.credentialURL(id: legacy.id))

        let loaded = try #require(try store.loadIndex().account(id: legacy.id))

        #expect(loaded.requiresReauth)
        #expect(loaded.lastError == "invalid_credential")
    }

    @Test("weak OAuth identities never merge on a workspace-only key")
    func weakIdentitiesDoNotMergeByWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-weak-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let first = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [:]),
                accessToken: Self.jwt(exp: 4_100_000_000),
                refreshToken: "weak-refresh-token-first",
                accountId: "workspace-only"),
            lastRefresh: nil)
        let second = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [:]),
                accessToken: Self.jwt(exp: 4_100_000_000),
                refreshToken: "weak-refresh-token-second",
                accountId: "workspace-only"),
            lastRefresh: nil)

        let firstAccount = try store.upsert(auth: first)
        let secondAccount = try store.upsert(auth: second)
        let firstAgain = try store.upsert(auth: first)
        #expect(firstAccount.id != secondAccount.id)
        #expect(firstAgain.id == firstAccount.id)
        #expect(try store.loadIndex().accounts.count == 2)
    }

    @Test("ambiguous organization claims never overwrite credentials")
    func ambiguousOrganizationsRemainSeparate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-ambiguous-organizations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let idToken = Self.jwt(payload: [
            "email": "member@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "user-shared",
                "organizations": [
                    ["id": "org-first", "is_default": false],
                    ["id": "org-second", "is_default": false],
                ],
            ],
        ])
        let firstAuth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: idToken,
                accessToken: Self.jwt(exp: 4_100_000_000),
                refreshToken: "ambiguous-refresh-token-one",
                accountId: nil),
            lastRefresh: nil)
        var secondAuth = firstAuth
        secondAuth.tokens.refreshToken = "ambiguous-refresh-token-two"

        let first = try store.upsert(auth: firstAuth)
        let second = try store.upsert(auth: secondAuth)

        #expect(first.id != second.id)
        #expect(try store.loadIndex().accounts.count == 2)
        #expect(try store.loadCredential(id: first.id).tokens.refreshToken == "ambiguous-refresh-token-one")
        #expect(try store.loadCredential(id: second.id).tokens.refreshToken == "ambiguous-refresh-token-two")
    }

    @Test("session access-token-only credentials are usable while JWT is valid")
    func sessionAccessTokenOnlyUsable() {
        let access = Self.jwt(payload: [
            "email": "session@example.com",
            "exp": 4_100_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "sess-1",
                "chatgpt_plan_type": "free",
            ],
        ])
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: access, accessToken: access, refreshToken: "", accountId: "sess-1"),
            lastRefresh: nil)
        #expect(auth.isAccessTokenOnly)
        #expect(auth.loginUsability == .usable)

        let expired = Self.jwt(payload: ["exp": 1_700_000_000, "email": "x@y.z"])
        let expiredAuth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: expired, accessToken: expired, refreshToken: "", accountId: "sess-1"),
            lastRefresh: nil)
        #expect(expiredAuth.loginUsability == .expiredAccessWithoutRefresh)
    }

    @Test("withIdentity prefers JWT plan over stale metadata when quota plan is omitted")
    func withIdentityPrefersLivePlan() {
        let proAuth = sampleAuth(accountId: "acct", email: "a@example.com", refresh: "r1", plan: "pro")
        var account = ManagedAccount.make(auth: proAuth, sortIndex: 0)
        #expect(account.subscriptionTier == .pro20x || account.planType?.contains("pro") == true)

        let freeAuth = sampleAuth(accountId: "acct", email: "a@example.com", refresh: "r2", plan: "free")
        account = account.withIdentity(from: freeAuth, quotaPlan: nil)
        #expect(account.planType?.lowercased().contains("free") == true)
        #expect(account.subscriptionTier == .free)
    }

    @Test("identity refresh preserves a cached workspace name")
    func withIdentityPreservesWorkspaceName() {
        let auth = sampleAuth(
            accountId: "workspace-cached",
            email: "cached@example.com",
            refresh: "refresh-cached-workspace",
            plan: "team",
            userId: "user-cached")
        var account = ManagedAccount.make(auth: auth)
        account.workspaceName = "Cached Workspace"

        let refreshed = account.withIdentity(from: auth, quotaPlan: "team")
        #expect(refreshed.workspaceName == "Cached Workspace")
        #expect(refreshed.displaysWorkspaceIdentity)
        #expect(refreshed.identityMarkerUserId == "user-cached")
        #expect(refreshed.identityMarkerWorkspaceId == "workspace-cached")

        let personal = ManagedAccount.make(auth: sampleAuth(
            accountId: "personal-account",
            email: "personal@example.com",
            refresh: "refresh-personal-account",
            plan: "pro",
            userId: "personal-user"))
        #expect(!personal.displaysWorkspaceIdentity)
        #expect(personal.identityMarkerUserId == "personal-user")
    }

    @Test("orders sidebar with active account first")
    func sidebarOrder() {
        var index = AccountIndex(activeAccountId: "b", accounts: [
            ManagedAccount(id: "a", sortIndex: 0, displayName: "A"),
            ManagedAccount(id: "b", sortIndex: 2, displayName: "B"),
            ManagedAccount(id: "c", sortIndex: 1, displayName: "C"),
        ])
        #expect(index.orderedForSidebar().map(\.id) == ["b", "a", "c"])
        index.reindexSortOrder(["c", "a", "b"])
        #expect(index.account(id: "c")?.sortIndex == 0)
        #expect(index.account(id: "a")?.sortIndex == 1)
    }

    @Test("imports API key accounts without oauth tokens")
    func apiKeyAccount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-apikey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let importer = AccountImporter(store: store)
        let account = try importer.importAPIKey("sk-test-key-1234567890")
        #expect(account.authMode == .apiKey)
        #expect(account.subscriptionTier == .api)
        let auth = try store.loadCredential(id: account.id)
        #expect(auth.isAPIKeyAuth)
        #expect(auth.openAIAPIKey == "sk-test-key-1234567890")
        #expect(auth.redactedDescription.contains("sk-test") == false)
    }

    @Test("parses pasted auth json and bare refresh token shapes")
    func parsesPasteFormats() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-paste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        // Avoid network: import via store decode path for full auth object.
        let authJSON = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "\(Self.jwt(exp: 4_100_000_000))",
            "refresh_token": "refresh-paste",
            "account_id": "paste-1",
            "id_token": "\(Self.jwt(payload: ["email": "paste@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "paste-1"]]))"
          }
        }
        """
        let importer = AccountImporter(store: store, tokenRefresher: TokenRefresher())
        let batch = await importer.importPastedText(authJSON)
        #expect(batch.successCount == 1)
        #expect(batch.succeeded.first?.email == "paste@example.com" || batch.succeeded.first?.accountId == "paste-1")
    }

    @Test("parses ChatGPT /auth/session JSON with camelCase accessToken")
    func parsesAuthSessionJSON() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))

        let access = Self.jwt(payload: [
            "email": "session@example.com",
            "exp": 4_100_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "sess-acct-1",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let sessionJSON = """
        {
          "user": {
            "id": "user-1",
            "email": "session@example.com",
            "name": "Session User"
          },
          "expires": "2099-01-01T00:00:00.000Z",
          "account": {
            "id": "sess-acct-1",
            "planType": "plus",
            "structure": "personal"
          },
          "accessToken": "\(access)",
          "authProvider": "openai"
        }
        """
        let importer = AccountImporter(store: store, tokenRefresher: TokenRefresher())
        let batch = await importer.importPastedText(sessionJSON)
        #expect(batch.successCount == 1)
        #expect(batch.failures.isEmpty)
        #expect(batch.succeeded.first?.email == "session@example.com")
        #expect(batch.succeeded.first?.accountId == "sess-acct-1")
        let cred = try! store.loadCredential(id: batch.succeeded[0].id)
        #expect(cred.tokens.accessToken == access)
        #expect(cred.tokens.accountId == "sess-acct-1")
    }

    @Test("session credentials without workspace context remain separate")
    func sessionWithoutWorkspaceDoesNotUseSyntheticEmailIdentity() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-session-no-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let firstAccess = Self.jwt(payload: [
            "email": "shared@example.com",
            "exp": 4_100_000_000,
            "jti": "session-one",
            "https://api.openai.com/auth": ["chatgpt_user_id": "user-shared"],
        ])
        let secondAccess = Self.jwt(payload: [
            "email": "shared@example.com",
            "exp": 4_100_000_000,
            "jti": "session-two",
            "https://api.openai.com/auth": ["chatgpt_user_id": "user-shared"],
        ])
        let sessionJSON = """
        [
          {"user":{"email":"shared@example.com"},"accessToken":"\(firstAccess)","authProvider":"openai"},
          {"user":{"email":"shared@example.com"},"accessToken":"\(secondAccess)","authProvider":"openai"}
        ]
        """

        let batch = await AccountImporter(store: store).importPastedText(sessionJSON)
        #expect(batch.successCount == 2)
        #expect(try! store.loadIndex().accounts.count == 2)
        #expect(try! store.loadIndex().accounts.allSatisfy { $0.accountId == nil })
    }

    @Test("paste of unrecognized JSON reports no_credentials failure")
    func pasteUnrecognizedJSONFailsClearly() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-badpaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let importer = AccountImporter(store: store)
        let batch = await importer.importPastedText(#"{"hello":"world","foo":1}"#)
        #expect(batch.successCount == 0)
        #expect(batch.failures == ["no_credentials"])
    }

    @Test("syncs when official auth changes externally")
    func syncsOfficial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent("auth.json")
        let store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: official)

        try store.saveOfficialAuth(sampleAuth(accountId: "one", email: "one@example.com", refresh: "r1"))
        _ = try store.importOfficialAuth(makeActive: true)
        try store.saveOfficialAuth(sampleAuth(accountId: "two", email: "two@example.com", refresh: "r2"))
        let index = try store.syncFromOfficialAuth()
        #expect(index.accounts.count == 2)
        #expect(index.activeAccountId != nil)
        let active = index.account(id: index.activeAccountId!)
        #expect(active?.accountId == "two" || active?.email == "two@example.com")
    }

    @Test("external auth change to another user in the same workspace preserves both credentials")
    func syncsDifferentUserInSameWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-sync-same-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let firstAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "one@example.com",
            refresh: "refresh-first-member",
            userId: "user-one")
        let secondAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "two@example.com",
            refresh: "refresh-second-member",
            userId: "user-two")

        let first = try store.upsert(auth: firstAuth, makeActive: true)
        try store.saveOfficialAuth(firstAuth)
        try store.saveOfficialAuth(secondAuth)
        let index = try store.syncFromOfficialAuth()
        let activeId = try #require(index.activeAccountId)

        #expect(index.accounts.count == 2)
        #expect(activeId != first.id)
        #expect(try store.loadCredential(id: first.id).tokens.refreshToken == "refresh-first-member")
        #expect(try store.loadCredential(id: activeId).tokens.refreshToken == "refresh-second-member")
    }

    @Test("one-click switching between same-workspace users preserves managed snapshots")
    func switchesBetweenSameWorkspaceUsers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-switch-same-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let firstAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "one@example.com",
            refresh: "refresh-first-member",
            userId: "user-one")
        let secondAuth = sampleAuth(
            accountId: "workspace-shared",
            email: "two@example.com",
            refresh: "refresh-second-member",
            userId: "user-two")
        let first = try store.upsert(auth: firstAuth, makeActive: true)
        let second = try store.upsert(auth: secondAuth)
        let switcher = AccountSwitcher(store: store)

        _ = try await switcher.switchTo(accountId: second.id)
        #expect(CodexIdentityClaims.decode(try store.loadOfficialAuth().tokens.idToken)?.userId == "user-two")
        _ = try await switcher.switchTo(accountId: first.id)
        #expect(CodexIdentityClaims.decode(try store.loadOfficialAuth().tokens.idToken)?.userId == "user-one")
        #expect(try store.loadCredential(id: first.id).tokens.refreshToken == "refresh-first-member")
        #expect(try store.loadCredential(id: second.id).tokens.refreshToken == "refresh-second-member")
    }

    @Test("oauth session builds authorize url with pkce params")
    func oauthSession() throws {
        let session = try CodexOAuthLogin.startSession(port: 1455)
        #expect(session.authURL.absoluteString.contains("code_challenge="))
        #expect(session.authURL.absoluteString.contains("client_id="))
        #expect(session.redirectURI.contains("1455"))
        let callback = URL(string: "http://localhost:1455/auth/callback?code=abc&state=\(session.state)")!
        let code = try CodexOAuthLogin.authorizationCode(from: callback, expectedState: session.state)
        #expect(code == "abc")
    }

    private func sampleAuth(
        accountId: String,
        email: String,
        refresh: String,
        plan: String = "plus",
        userId: String? = nil,
        subject: String? = nil,
        claimAccountId: String? = nil,
        workspaceName: String? = nil) -> CodexAuth
    {
        var authClaims: [String: Any] = [
            "chatgpt_account_id": claimAccountId ?? accountId,
            "chatgpt_plan_type": plan,
        ]
        if let userId {
            authClaims["chatgpt_user_id"] = userId
        }
        if let workspaceName {
            authClaims["organizations"] = [[
                "id": "organization-\(accountId)",
                "is_default": true,
                "title": workspaceName,
            ]]
        }
        var payload: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": authClaims,
        ]
        if let subject {
            payload["sub"] = subject
        }
        let idToken = Self.jwt(payload: payload)
        // loginUsability requires a long refresh token so short fixtures pad out.
        let refreshToken = refresh.count >= 20 ? refresh : (refresh + String(repeating: "x", count: 24))
        return CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: idToken,
                accessToken: Self.jwt(exp: 4_100_000_000),
                refreshToken: refreshToken,
                accountId: accountId),
            lastRefresh: nil,
            planType: plan)
    }

    private static func jwt(exp: Int) -> String {
        jwt(payload: ["exp": exp])
    }

    private static func jwt(payload: [String: Any]) -> String {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [header, payloadData, Data()]
            .map { $0.base64EncodedString().urlSafeBase64 }
            .joined(separator: ".")
    }
}

private extension String {
    var urlSafeBase64: String {
        replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
