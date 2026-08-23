import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Codex auth")
struct AuthTests {
    @Test("decodes auth.json and redacts secrets")
    func decodesAuthAndRedactsSecrets() throws {
        let data = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "id_token": "id-secret",
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "account_id": "account-1"
          },
          "last_refresh": "2026-06-29T00:00:00Z"
        }
        """.data(using: .utf8)!

        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)

        #expect(auth.authMode == "chatgpt")
        #expect(auth.tokens.idToken == "id-secret")
        #expect(auth.tokens.accountId == "account-1")
        #expect(auth.redactedDescription.contains("id-secret") == false)
        #expect(auth.redactedDescription.contains("access-secret") == false)
        #expect(auth.redactedDescription.contains("refresh-secret") == false)
        #expect(auth.redactedDescription.contains("account-1"))
    }

    @Test("decodes auth.json without id token")
    func decodesAuthWithoutIDToken() throws {
        let data = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "account_id": "account-1"
          }
        }
        """.data(using: .utf8)!

        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)

        #expect(auth.tokens.idToken == nil)
        #expect(auth.tokens.accessToken == "access-secret")
    }

    @Test("detects expired access token from JWT exp")
    func detectsExpiredToken() {
        let expired = Self.jwt(exp: 1_700_000_000)
        let future = Self.jwt(exp: 4_100_000_000)

        #expect(TokenInspector.isExpired(expired, now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(TokenInspector.isExpired(future, now: Date(timeIntervalSince1970: 1_800_000_000)) == false)
        #expect(TokenInspector.isExpired("not-a-jwt", now: Date()))
    }

    @Test("merges refresh response and keeps existing refresh token when omitted")
    func mergesRefreshResponse() throws {
        var auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: "old-id", accessToken: "old-access", refreshToken: "old-refresh", accountId: "account-1"),
            lastRefresh: nil)
        let data = #"{"access_token":"new-access","id_token":"new-id","expires_in":3600}"#.data(using: .utf8)!

        try auth.mergeRefreshResponse(data, now: Date(timeIntervalSince1970: 1_782_710_000))

        #expect(auth.tokens.idToken == "new-id")
        #expect(auth.tokens.accessToken == "new-access")
        #expect(auth.tokens.refreshToken == "old-refresh")
        #expect(auth.lastRefresh == "2026-06-29T05:13:20Z")
    }

    @Test("refresh response keeps existing id token when omitted")
    func keepsIDTokenWhenRefreshOmitsIt() throws {
        var auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: "old-id", accessToken: "old-access", refreshToken: "old-refresh", accountId: nil),
            lastRefresh: nil)
        let data = #"{"access_token":"new-access"}"#.data(using: .utf8)!

        try auth.mergeRefreshResponse(data)

        #expect(auth.tokens.idToken == "old-id")
        #expect(auth.tokens.accessToken == "new-access")
    }

    @Test("extracts Codex identity claims from JWT payloads")
    func extractsIdentityClaims() throws {
        let token = Self.jwt(payload: [
            "email": "top@example.com",
            "name": "Top Name",
            "preferred_username": "top-user",
            "sub": "user-sub",
            "https://api.openai.com/profile": [
                "email": "profile@example.com",
            ],
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "prolite",
                "chatgpt_account_id": "acct_123",
                "chatgpt_user_id": "chat-user-id",
                "chatgpt_subscription_active_until": "2026-06-20T11:08:02+00:00",
            ],
        ])

        let claims = try #require(CodexIdentityClaims.decode(token))

        #expect(claims.email == "top@example.com")
        #expect(claims.username == "top-user")
        #expect(claims.subject == "user-sub")
        #expect(claims.userId == "chat-user-id")
        #expect(claims.planType == "prolite")
        #expect(claims.accountId == "acct_123")
        #expect(claims.organizationId == nil)
        #expect(claims.organizationName == nil)
        #expect(claims.subscriptionActiveUntil == RunwayDates.parse("2026-06-20T11:08:02+00:00"))
        #expect(CodexIdentityClaims.decode("not-a-jwt") == nil)
    }

    @Test("falls back to profile email when top level email is missing")
    func fallsBackToProfileEmail() throws {
        let token = Self.jwt(payload: [
            "https://api.openai.com/profile": [
                "email": "profile@example.com",
            ],
        ])

        let claims = try #require(CodexIdentityClaims.decode(token))

        #expect(claims.email == "profile@example.com")
    }

    @Test("keeps explicit account and organization fallback identities separate")
    func separatesAccountAndOrganizationIdentity() throws {
        let explicit = Self.jwt(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace-explicit",
                "organizations": [
                    ["id": "org-default", "is_default": true, "title": "Workspace Alpha"],
                ],
            ],
        ])
        let explicitClaims = try #require(CodexIdentityClaims.decode(explicit))
        #expect(explicitClaims.accountId == "workspace-explicit")
        #expect(explicitClaims.organizationId == "org-default")
        #expect(explicitClaims.organizationName == "Workspace Alpha")

        let fallback = Self.jwt(payload: [
            "https://api.openai.com/auth": [
                "organizations": [
                    ["id": "org-first", "is_default": false, "title": "First"],
                    ["id": "org-selected", "is_default": true, "title": "Selected Workspace"],
                ],
            ],
        ])
        let fallbackClaims = try #require(CodexIdentityClaims.decode(fallback))
        #expect(fallbackClaims.accountId == nil)
        #expect(fallbackClaims.organizationId == "org-selected")
        #expect(fallbackClaims.organizationName == "Selected Workspace")

        let organizationAuth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: fallback,
                accessToken: Self.jwt(payload: [:]),
                refreshToken: "organization-fallback-refresh-token",
                accountId: nil),
            lastRefresh: nil)
        let managed = ManagedAccount.make(auth: organizationAuth)
        #expect(managed.accountId == "org-selected")
        #expect(managed.workspaceName == "Selected Workspace")

        let ambiguous = Self.jwt(payload: [
            "https://api.openai.com/auth": [
                "organizations": [
                    ["id": "org-first", "title": "First"],
                    ["id": "org-second", "title": "Second"],
                ],
            ],
        ])
        let ambiguousClaims = try #require(CodexIdentityClaims.decode(ambiguous))
        #expect(ambiguousClaims.organizationId == nil)
        #expect(ambiguousClaims.organizationName == nil)
    }

    @Test("conflicting OAuth identity claims use credential fingerprint matching")
    func conflictingIdentityClaimsUseCredentialFingerprint() {
        let userConflict = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [
                    "email": "same@example.com",
                    "https://api.openai.com/auth": [
                        "chatgpt_user_id": "user-one",
                        "chatgpt_account_id": "workspace-shared",
                    ],
                ]),
                accessToken: Self.jwt(payload: [
                    "email": "same@example.com",
                    "https://api.openai.com/auth": [
                        "chatgpt_user_id": "user-two",
                        "chatgpt_account_id": "workspace-shared",
                    ],
                ]),
                refreshToken: "conflicting-user-refresh-token",
                accountId: "workspace-shared"),
            lastRefresh: nil)
        #expect(
            AccountIdentity.matchKey(for: userConflict)
                .hasPrefix("oauth:workspace:workspace-shared|credential:"))

        let workspaceConflict = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: [
                    "https://api.openai.com/auth": [
                        "chatgpt_user_id": "user-one",
                        "chatgpt_account_id": "workspace-claim",
                    ],
                ]),
                accessToken: Self.jwt(payload: [:]),
                refreshToken: "conflicting-workspace-refresh-token",
                accountId: "workspace-selected"),
            lastRefresh: nil)
        #expect(AccountIdentity.routingWorkspaceId(for: workspaceConflict) == "workspace-selected")
        #expect(
            AccountIdentity.matchKey(for: workspaceConflict)
                .hasPrefix("oauth:workspace:workspace-selected|credential:"))
    }

    @Test("maps Codex subscription tiers")
    func mapsSubscriptionTiers() {
        #expect(CodexSubscriptionTier.resolve(planType: "free", fallbackPlanType: nil) == .free)
        #expect(CodexSubscriptionTier.resolve(planType: "plus", fallbackPlanType: nil) == .plus)
        #expect(CodexSubscriptionTier.resolve(planType: "pro", fallbackPlanType: nil) == .pro20x)
        #expect(CodexSubscriptionTier.resolve(planType: "prolite", fallbackPlanType: nil) == .pro5x)
        #expect(CodexSubscriptionTier.resolve(planType: "codex-pro-5x", fallbackPlanType: nil) == .pro5x)
        #expect(CodexSubscriptionTier.resolve(planType: "pro-20x", fallbackPlanType: nil) == .pro20x)
        #expect(CodexSubscriptionTier.resolve(planType: "business", fallbackPlanType: nil) == .business)
        #expect(CodexSubscriptionTier.resolve(planType: "team", fallbackPlanType: nil) == .team)
        #expect(CodexSubscriptionTier.resolve(planType: "enterprise", fallbackPlanType: nil) == .enterprise)
        #expect(CodexSubscriptionTier.resolve(planType: "edu", fallbackPlanType: nil) == .edu)
        #expect(CodexSubscriptionTier.resolve(planType: "api_key", fallbackPlanType: nil) == .api)
        #expect(CodexSubscriptionTier.resolve(planType: nil, fallbackPlanType: "plus") == .plus)
        #expect(CodexSubscriptionTier.resolve(planType: "mystery", fallbackPlanType: nil) == .unknown)
    }

    @Test("builds account display from auth and quota plan")
    func buildsAccountDisplay() {
        // Freeze "now" so a fixed JWT period end is not projected month-by-month once wall
        // clock passes that date (projection behavior is covered by dedicated tests).
        let now = RunwayDates.parse("2026-07-15T12:00:00Z")!
        let idToken = Self.jwt(payload: [
            "email": "person@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
                "account_id": "acct_123456789",
                "chatgpt_subscription_active_until": "2026-08-01T00:00:00Z",
            ],
        ])
        let accessToken = Self.jwt(payload: ["preferred_username": "access-user"])
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: "refresh",
                accountId: "acct_123456789"),
            lastRefresh: nil)

        let display = CodexAccountDisplay.make(auth: auth, quotaPlan: "pro", now: now)

        #expect(display.displayName == "person@example.com")
        #expect(display.email == "person@example.com")
        #expect(display.accountId == "acct_123456789")
        #expect(display.subscriptionTier == .pro20x)
        #expect(display.subscriptionExpiresAt == RunwayDates.parse("2026-08-01T00:00:00Z"))
    }

    @Test("projects stale JWT subscription end forward for paid plans")
    func projectsStalePaidSubscriptionEnd() {
        // Real-world case: id_token still says June 20 after renewal; today is July 19.
        let now = RunwayDates.parse("2026-07-19T14:00:00Z")!
        let raw = RunwayDates.parse("2026-06-20T11:08:02+00:00")!
        let projected = CodexAccountDisplay.resolvedSubscriptionExpiresAt(
            raw: raw,
            tier: .pro5x,
            now: now)
        let expected = RunwayDates.parse("2026-07-20T11:08:02+00:00")
        #expect(projected == expected)
        #expect(!SubscriptionDateFormatter.isExpired(projected!, now: now))

        // Free / unknown keep the past claim as truly expired.
        #expect(
            CodexAccountDisplay.resolvedSubscriptionExpiresAt(raw: raw, tier: .free, now: now) == raw)
        #expect(SubscriptionDateFormatter.isExpired(raw, now: now))
    }

    @Test("future JWT subscription end is left unchanged")
    func keepsFutureSubscriptionEnd() {
        let now = RunwayDates.parse("2026-07-19T14:00:00Z")!
        let raw = RunwayDates.parse("2026-08-20T11:08:02+00:00")!
        #expect(
            CodexAccountDisplay.resolvedSubscriptionExpiresAt(raw: raw, tier: .pro5x, now: now) == raw)
    }

    @Test("account display falls back to username and account id")
    func accountDisplayFallbacks() {
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: Self.jwt(payload: ["preferred_username": "id-user"]),
                accessToken: Self.jwt(payload: [:]),
                refreshToken: "refresh",
                accountId: "acct_123456789"),
            lastRefresh: nil)

        #expect(CodexAccountDisplay.make(auth: auth, quotaPlan: nil).displayName == "id-user")

        let fallback = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(accessToken: Self.jwt(payload: [:]), refreshToken: "refresh", accountId: "acct_123456789"),
            lastRefresh: nil)
        #expect(CodexAccountDisplay.make(auth: fallback, quotaPlan: nil).displayName == "acct_...6789")
    }

    @Test("account display distinguishes missing auth from unknown identity")
    func accountDisplayAuthenticationState() {
        #expect(CodexAccountDisplay.make(auth: nil, quotaPlan: nil).isAuthenticated == false)

        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(accessToken: Self.jwt(payload: [:]), refreshToken: "refresh", accountId: nil),
            lastRefresh: nil)

        let display = CodexAccountDisplay.make(auth: auth, quotaPlan: nil)
        #expect(display.isAuthenticated)
        #expect(display.displayName.isEmpty)
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
        self.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
