import Darwin
import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok account module", .serialized)
struct GrokAccountModuleTests {
    @Test("load imports the official OAuth identity as the current managed account")
    func loadImportsOfficialIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let official = Self.credential(email: "current@example.com", userID: "current-user")
        try fixture.writeOfficial(official)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let state = try await module.load()

        let account = try #require(state.accounts.first)
        #expect(state.currentAccountID == account.id)
        #expect(account.email == "current@example.com")
        #expect(try fixture.store.loadCredentialData(id: account.id) == official)
        #expect(state.officialCredentialStatus.identity?.stableID == account.id)
    }

    @Test("expired non-current OAuth tokens are refreshed without touching official auth")
    func refreshesExpiredNonCurrentTokenSilently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(
            email: "other@example.com",
            userID: "other-user",
            accessToken: "expired-other-access",
            expiresAt: "2020-01-01T00:00:00Z",
            refreshToken: "other-refresh-token-for-tests",
            clientID: GrokOAuthLogin.clientID)
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, makeCurrent: false, now: fixture.now)

        MockGrokModuleTokenURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            let response = Data(
                #"""
                {
                  "access_token": "renewed-other-access-token",
                  "refresh_token": "rotated-other-refresh-token",
                  "expires_in": 7200
                }
                """#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!,
                response)
        }
        defer { MockGrokModuleTokenURLProtocol.handler = nil }

        let seenHomes = HomeRecorder()
        let cli = GrokCLIClient(
            billing: { homeURL in
                await seenHomes.append(homeURL)
                let token = try GrokAuthDocument.accessToken(
                    from: Data(contentsOf: homeURL.appendingPathComponent("auth.json")))
                #expect(token == "renewed-other-access-token")
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now },
            tokenRefresher: GrokTokenRefresher(
                session: MockGrokModuleTokenURLProtocol.session(),
                tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!))

        let report = await module.refresh(.account(id: other.id))

        #expect(report.outcomes.first?.snapshot?.includedUsagePercent == 42.25)
        #expect(try fixture.store.loadOfficialCredentialData() == currentData)
        let renewed = try fixture.store.loadCredentialData(id: other.id)
        #expect(try GrokAuthDocument.accessToken(from: renewed) == "renewed-other-access-token")
        #expect(try GrokAuthDocument.parse(renewed).refreshToken() == "rotated-other-refresh-token")
        #expect(await seenHomes.values == [fixture.store.accountDirectory(id: other.id)])
    }

    @Test("refreshing current also keep-alives non-current tokens without billing them")
    func currentRefreshKeepAlivesOtherTokens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(
            email: "other@example.com",
            userID: "other-user",
            accessToken: "stale-other-access",
            expiresAt: "2020-01-01T00:00:00Z",
            refreshToken: "keep-alive-refresh-token",
            clientID: GrokOAuthLogin.clientID)
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, makeCurrent: false, now: fixture.now)

        let hits = TokenRefreshHitCounter()
        MockGrokModuleTokenURLProtocol.handler = { _ in
            await hits.increment()
            let response = Data(#"{"access_token":"kept-alive-access","expires_in":3600}"#.utf8)
            return (
                HTTPURLResponse(
                    url: URL(string: "https://auth.x.ai/oauth2/token")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!,
                response)
        }
        defer { MockGrokModuleTokenURLProtocol.handler = nil }

        let seenHomes = HomeRecorder()
        let cli = GrokCLIClient(
            billing: { homeURL in
                await seenHomes.append(homeURL)
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now },
            tokenRefresher: GrokTokenRefresher(
                session: MockGrokModuleTokenURLProtocol.session(),
                tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!))

        let report = await module.refresh(.current)

        let currentID = try fixture.store.loadIndex().currentAccountID
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.accountID == currentID)
        #expect(await seenHomes.values == [fixture.store.officialHomeURL])
        #expect(await hits.count >= 1)
        #expect(
            try GrokAuthDocument.accessToken(from: fixture.store.loadCredentialData(id: other.id))
                == "kept-alive-access")
        #expect(try fixture.store.loadIndex().account(id: other.id)?.cachedQuota == nil)
    }

    @Test("refreshing a non-current account uses its isolated home and preserves official auth bytes")
    func refreshNonCurrentAccountIsIsolated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        let rotatedOtherData = Self.credential(
            email: "other@example.com",
            userID: "other-user",
            accessToken: "rotated-other-access-token-for-tests")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, makeCurrent: false, now: fixture.now)
        let recorder = HomeRecorder()
        let cli = GrokCLIClient(
            billing: { homeURL in
                await recorder.append(homeURL)
                let authURL = homeURL.appendingPathComponent("auth.json")
                try rotatedOtherData.write(to: authURL)
                guard chmod(authURL.path, 0o644) == 0 else {
                    throw GrokCLIError.requestFailed("could not loosen fixture permissions")
                }
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.account(id: other.id))

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.accountID == other.id)
        #expect(report.outcomes.first?.snapshot?.includedUsagePercent == 42.25)
        #expect(await recorder.values == [fixture.store.accountDirectory(id: other.id)])
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == currentData)
        #expect(try fixture.store.loadCredentialData(id: other.id) == rotatedOtherData)
        let permissions = try #require(FileManager.default.attributesOfItem(
            atPath: fixture.store.credentialURL(id: other.id).path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(try fixture.store.loadIndex().account(id: other.id)?.cachedQuota?.includedUsagePercent == 42.25)
    }

    @Test("a failed non-current refresh keeps a valid token rotation and restores restricted permissions")
    func failedNonCurrentRefreshFinalizesValidRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        let rotatedOtherData = Self.credential(
            email: "other@example.com",
            userID: "other-user",
            accessToken: "rotated-after-failed-billing-for-tests")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let cli = GrokCLIClient(
            billing: { homeURL in
                let authURL = homeURL.appendingPathComponent("auth.json")
                try rotatedOtherData.write(to: authURL)
                guard chmod(authURL.path, 0o644) == 0 else {
                    throw GrokCLIError.requestFailed("could not loosen fixture permissions")
                }
                throw GrokCLIError.timeout(operation: "billing")
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.account(id: other.id))

        #expect(report.outcomes.first?.error == .refreshFailed(
            accountID: other.id,
            message: "timeout"))
        #expect(try fixture.store.loadCredentialData(id: other.id) == rotatedOtherData)
        let permissions = try #require(FileManager.default.attributesOfItem(
            atPath: fixture.store.credentialURL(id: other.id).path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(try fixture.store.loadOfficialCredentialData() == currentData)
    }

    @Test("a cancelled non-current refresh finalizes a valid token rotation before returning")
    func cancelledNonCurrentRefreshFinalizesValidRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        let rotatedOtherData = Self.credential(
            email: "other@example.com",
            userID: "other-user",
            accessToken: "rotated-before-cancellation-for-tests")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let started = RefreshStartedSignal()
        let cli = GrokCLIClient(
            billing: { homeURL in
                let authURL = homeURL.appendingPathComponent("auth.json")
                try rotatedOtherData.write(to: authURL)
                guard chmod(authURL.path, 0o644) == 0 else {
                    throw GrokCLIError.requestFailed("could not loosen fixture permissions")
                }
                await started.signal()
                try await Task.sleep(for: .seconds(30))
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let refresh = Task { await module.refresh(.account(id: other.id)) }

        await started.wait()
        refresh.cancel()
        let report = await refresh.value

        #expect(report.outcomes.first?.error == .refreshFailed(
            accountID: other.id,
            message: "cancelled"))
        #expect(try fixture.store.loadCredentialData(id: other.id) == rotatedOtherData)
        let permissions = try #require(FileManager.default.attributesOfItem(
            atPath: fixture.store.credentialURL(id: other.id).path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(try fixture.store.loadOfficialCredentialData() == currentData)
    }

    @Test("a failed non-current refresh restores the snapshot after an identity-changing write")
    func failedNonCurrentRefreshRollsBackWrongIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        let wrongIdentity = Self.credential(email: "intruder@example.com", userID: "intruder-user")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let cli = GrokCLIClient(
            billing: { homeURL in
                try wrongIdentity.write(to: homeURL.appendingPathComponent("auth.json"))
                throw GrokCLIError.timeout(operation: "billing")
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.account(id: other.id))

        #expect(report.outcomes.first?.error == .refreshFailed(
            accountID: other.id,
            message: "timeout"))
        #expect(try fixture.store.loadCredentialData(id: other.id) == otherData)
        #expect(try fixture.store.loadOfficialCredentialData() == currentData)
    }

    @Test("a successful billing response cannot commit after the CLI corrupts managed auth")
    func successfulNonCurrentRefreshRollsBackMalformedCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let cli = GrokCLIClient(
            billing: { homeURL in
                try Data("{malformed".utf8).write(
                    to: homeURL.appendingPathComponent("auth.json"))
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.account(id: other.id))

        #expect(report.outcomes.first?.snapshot == nil)
        #expect(report.outcomes.first?.error == .invalidCredential)
        #expect(try fixture.store.loadCredentialData(id: other.id) == otherData)
        #expect(try fixture.store.loadIndex().account(id: other.id)?.cachedQuota == nil)
    }

    @Test("a non-current credential rollback failure is reported as a partial write")
    func nonCurrentRefreshReportsCredentialRollbackFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        try fixture.writeOfficial(currentData)
        _ = try fixture.store.upsertCredentialData(currentData, makeCurrent: true, now: fixture.now)
        let other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let authURL = fixture.store.credentialURL(id: other.id)
        defer { _ = chflags(authURL.path, 0) }
        let cli = GrokCLIClient(
            billing: { _ in
                try Data("{malformed".utf8).write(to: authURL)
                guard chflags(authURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
                    throw GrokCLIError.requestFailed("could not protect failure fixture")
                }
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.account(id: other.id))

        let error = try #require(report.outcomes.first?.error)
        guard case .partialWrite = error else {
            Issue.record("Expected a partial-write error, received \(error).")
            return
        }
        #expect(try Data(contentsOf: authURL) == Data("{malformed".utf8))
    }

    @Test("refreshing the current account uses official home and mirrors rotated credentials")
    func refreshCurrentAccountMirrorsRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Self.credential(
            email: "current@example.com",
            userID: "current-user",
            accessToken: "original-access-token-for-tests")
        let rotated = Self.credential(
            email: "current@example.com",
            userID: "current-user",
            accessToken: "rotated-access-token-for-tests")
        try fixture.writeOfficial(original)
        let recorder = HomeRecorder()
        let cli = GrokCLIClient(
            billing: { homeURL in
                await recorder.append(homeURL)
                try rotated.write(to: homeURL.appendingPathComponent("auth.json"))
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let initial = try await module.load()
        let currentID = try #require(initial.currentAccountID)

        let report = await module.refresh(.current)

        #expect(report.outcomes.first?.snapshot?.includedUsagePercent == 42.25)
        #expect(await recorder.values == [fixture.store.officialHomeURL])
        #expect(try fixture.store.loadCredentialData(id: currentID) == rotated)
    }

    @Test("a failed current refresh still mirrors a valid token rotation")
    func failedCurrentRefreshMirrorsRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Self.credential(
            email: "current@example.com",
            userID: "current-user",
            accessToken: "original-access-token-for-tests")
        let rotated = Self.credential(
            email: "current@example.com",
            userID: "current-user",
            accessToken: "rotated-before-failure-for-tests")
        try fixture.writeOfficial(original)
        let cli = GrokCLIClient(
            billing: { homeURL in
                try rotated.write(to: homeURL.appendingPathComponent("auth.json"))
                throw GrokCLIError.timeout(operation: "billing")
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let initial = try await module.load()
        let currentID = try #require(initial.currentAccountID)

        let report = await module.refresh(.current)

        #expect(report.outcomes.first?.error == .refreshFailed(
            accountID: currentID,
            message: "timeout"))
        #expect(try fixture.store.loadCredentialData(id: currentID) == rotated)
    }

    @Test("account switching warns for running processes and preserves non-managed scopes")
    func switchWarnsAndPreservesScopes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Self.withAPIKey(
            Self.credential(email: "first@example.com", userID: "first-user"),
            key: "official-api-key-for-tests")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(first)
        let second = try fixture.store.upsertCredentialData(secondData, makeCurrent: false, now: fixture.now)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [42] },
            now: { fixture.now })
        _ = try await module.load()

        await #expect(throws: GrokAccountError.grokProcessesRunning([42])) {
            try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: false))
        }
        let switched = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))
        let officialData = try fixture.store.loadOfficialCredentialData()
        let installed = try GrokAuthDocument.parse(officialData)
        let officialRoot = try #require(JSONSerialization.jsonObject(with: officialData) as? [String: Any])
        let apiKey = try #require(officialRoot[GrokAuthDocument.apiKeyScope] as? [String: Any])

        #expect(switched.currentAccountID == second.id)
        #expect(installed.stableID == second.id)
        #expect(apiKey["key"] as? String == "official-api-key-for-tests")
    }

    @Test("re-applying the listed current account overwrites a drifted official credential")
    func reappliesListedCurrentOverDriftedOfficial() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let driftedData = Self.credential(email: "drifted@example.com", userID: "drifted-user")
        try fixture.writeOfficial(firstData)
        let first = try fixture.store.upsertCredentialData(firstData, makeCurrent: true, now: fixture.now)
        try fixture.writeOfficial(driftedData)
        #expect(try fixture.store.loadIndex().currentAccountID == first.id)

        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let state = try await module.apply(.makeCurrent(id: first.id, allowWhileRunning: true))
        let official = try GrokAuthDocument.parse(fixture.store.loadOfficialCredentialData())

        #expect(state.currentAccountID == first.id)
        #expect(official.stableID == first.id)
    }

    @Test("isolated OAuth login makes only the first account current")
    func isolatedLoginOnlyMakesFirstCurrent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = LoginCredentialWriter(credentials: [
            Self.credential(email: "first@example.com", userID: "first-user"),
            Self.credential(email: "second@example.com", userID: "second-user"),
        ])
        let cli = GrokCLIClient(
            billing: { _ in Self.quota(now: fixture.now) },
            loginOAuth: { homeURL in try await writer.writeNext(to: homeURL) },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let firstState = try await module.apply(.loginOAuth)
        let firstID = try #require(firstState.currentAccountID)
        let firstOfficial = try fixture.store.loadOfficialCredentialData()
        let secondState = try await module.apply(.loginOAuth)

        #expect(firstState.accounts.count == 1)
        #expect(secondState.accounts.count == 2)
        #expect(secondState.currentAccountID == firstID)
        #expect(try fixture.store.loadOfficialCredentialData() == firstOfficial)
        let pending = try FileManager.default.contentsOfDirectory(
            at: fixture.store.rootURL,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".grok-pending-") }
        #expect(pending.isEmpty)
    }

    @Test("load follows an external official identity rollback")
    func loadFollowsExternalIdentityChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(firstData)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let first = try await module.load()
        let second = try fixture.store.upsertCredentialData(secondData, makeCurrent: false, now: fixture.now)
        _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))

        try fixture.writeOfficial(firstData)
        let rolledBack = try await module.load()

        #expect(rolledBack.currentAccountID == first.currentAccountID)
        #expect(rolledBack.officialIdentityChangedExternally)
    }

    @Test("refresh preserves an external identity change until the next load consumes it")
    func refreshPreservesExternalIdentityChangeForLoad() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(firstData)
        let cli = GrokCLIClient(
            billing: { _ in Self.quota(now: fixture.now) },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let first = try await module.load()
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))

        try fixture.writeOfficial(firstData)
        _ = await module.refresh(.current)
        _ = try await module.apply(.setAlias(
            id: try #require(first.currentAccountID),
            alias: "First"))
        let observed = try await module.load()
        let consumed = try await module.load()

        #expect(observed.currentAccountID == first.currentAccountID)
        #expect(observed.officialIdentityChangedExternally)
        #expect(!consumed.officialIdentityChangedExternally)
    }

    @Test("an explicit identity command acknowledges a pending external login change")
    func identityCommandAcknowledgesPendingExternalChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(firstData)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let first = try await module.load()
        let firstID = try #require(first.currentAccountID)
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))

        try fixture.writeOfficial(firstData)
        let detected = try await module.apply(.setAlias(id: firstID, alias: "First"))
        let acknowledged = try await module.apply(.importOfficial)
        let nextLoad = try await module.load()

        #expect(detected.officialIdentityChangedExternally)
        #expect(!acknowledged.officialIdentityChangedExternally)
        #expect(!nextLoad.officialIdentityChangedExternally)
    }

    @Test("OAuth cancellation cleans the isolated pending home")
    func cancelledLoginCleansPendingHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cli = GrokCLIClient(
            billing: { _ in Self.quota(now: fixture.now) },
            loginOAuth: { _ in
                try await Task.sleep(for: .seconds(30))
            },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let login = Task { try await module.apply(.loginOAuth) }

        try await Self.waitForPendingHome(in: fixture.store.rootURL)
        login.cancel()

        await #expect(throws: GrokAccountError.loginCancelled) {
            try await login.value
        }
        #expect(try Self.pendingHomes(in: fixture.store.rootURL).isEmpty)
    }

    @Test("a held official auth lock leaves identity and index unchanged")
    func switchFailsAtomicallyWhenAuthLockIsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(firstData)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let initial = try await module.load()
        let firstID = try #require(initial.currentAccountID)
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        let lockPath = fixture.store.officialAuthURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }

        await #expect(throws: GrokAccountError.authFileLocked) {
            try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))
        }

        #expect(try fixture.store.loadIndex().currentAccountID == firstID)
        #expect(try fixture.store.loadOfficialCredentialData() == firstData)
    }

    @Test("cancelling account switching after process inspection never writes credentials")
    func cancelledSwitchAfterInspectionDoesNotWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        try fixture.writeOfficial(firstData)
        let inspector = ProcessInspectionGate()
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { try await inspector.inspect() },
            now: { fixture.now })
        let initial = try await module.load()
        let firstID = try #require(initial.currentAccountID)
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        let switching = Task {
            try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: false))
        }

        await inspector.waitUntilStarted()
        switching.cancel()
        await inspector.release()

        await #expect(throws: CancellationError.self) {
            try await switching.value
        }
        #expect(try fixture.store.loadOfficialCredentialData() == firstData)
        #expect(try fixture.store.loadIndex().currentAccountID == firstID)
    }

    @Test("a failed index commit restores and verifies the original official auth bytes")
    func failedIndexCommitRollsBackOfficialAuth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        let apiKeyOnly = Self.withAPIKey(Data("{}".utf8), key: "official-api-key-for-tests")
        try fixture.writeOfficial(apiKeyOnly)
        let first = try fixture.store.upsertCredentialData(
            firstData,
            makeCurrent: true,
            now: fixture.now)
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        guard chflags(fixture.store.indexURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
            Issue.record("Unable to make the index immutable for the failure fixture.")
            return
        }
        defer { _ = chflags(fixture.store.indexURL.path, 0) }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        do {
            _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))
            Issue.record("Expected the immutable index commit to fail.")
        } catch let error as GrokAccountError {
            if case .partialWrite = error {
                Issue.record("A successful rollback must preserve the original commit error.")
            }
        } catch {
            // The original file-system commit error is expected after rollback succeeds.
        }

        #expect(try fixture.store.loadOfficialCredentialData() == apiKeyOnly)
        #expect(try fixture.store.loadIndex().currentAccountID == first.id)
    }

    @Test("a failed index commit restores an originally missing official auth file")
    func failedIndexCommitRestoresMissingOfficialAuth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstData = Self.credential(email: "first@example.com", userID: "first-user")
        let secondData = Self.credential(email: "second@example.com", userID: "second-user")
        let first = try fixture.store.upsertCredentialData(
            firstData,
            makeCurrent: true,
            now: fixture.now)
        let second = try fixture.store.upsertCredentialData(secondData, now: fixture.now)
        guard chflags(fixture.store.indexURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
            Issue.record("Unable to make the index immutable for the failure fixture.")
            return
        }
        defer { _ = chflags(fixture.store.indexURL.path, 0) }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: Self.unusedCLI,
            runningProcessIDs: { [] },
            now: { fixture.now })

        do {
            _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))
            Issue.record("Expected the immutable index commit to fail.")
        } catch let error as GrokAccountError {
            if case .partialWrite = error {
                Issue.record("A successful rollback must preserve the original commit error.")
            }
        } catch {
            // The original file-system commit error is expected after rollback succeeds.
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.store.officialAuthURL.path))
        #expect(try fixture.store.loadIndex().currentAccountID == first.id)
    }

    @Test("refresh all keeps stale quota when one account fails")
    func refreshAllRetainsStaleQuotaOnPartialFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let currentData = Self.credential(email: "current@example.com", userID: "current-user")
        let otherData = Self.credential(email: "other@example.com", userID: "other-user")
        try fixture.writeOfficial(currentData)
        let current = try fixture.store.upsertCredentialData(
            currentData,
            makeCurrent: true,
            now: fixture.now)
        var other = try fixture.store.upsertCredentialData(otherData, now: fixture.now)
        let stale = Self.quota(percent: 17.5, now: fixture.now.addingTimeInterval(-3_600))
        other = other.applying(snapshot: stale)
        try fixture.store.updateMetadata(other)
        let isolatedHome = fixture.store.accountDirectory(id: other.id)
        let recorder = HomeRecorder()
        let cli = GrokCLIClient(
            billing: { homeURL in
                await recorder.append(homeURL)
                if homeURL == isolatedHome {
                    throw GrokCLIError.timeout(operation: "billing")
                }
                return Self.quota(now: fixture.now)
            },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })

        let report = await module.refresh(.all)

        #expect(report.outcomes.map(\.accountID) == [current.id, other.id])
        #expect(report.outcomes[0].snapshot?.includedUsagePercent == 42.25)
        #expect(report.outcomes[1].error != nil)
        #expect(report.outcomes[1].retainedStaleSnapshot)
        #expect(await recorder.values == [fixture.store.officialHomeURL, isolatedHome])
        let retained = try #require(fixture.store.loadIndex().account(id: other.id))
        #expect(retained.cachedQuota == stale)
        #expect(retained.lastError == "timeout")
    }

    @Test(
        "refresh failures persist stable non-localized error codes",
        arguments: RefreshFailureFixture.allCases)
    private func refreshPersistsStableErrorCodes(_ failure: RefreshFailureFixture) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credential = Self.credential(email: "current@example.com", userID: "current-user")
        try fixture.writeOfficial(credential)
        let cli = GrokCLIClient(
            billing: { _ in try failure.raise() },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let state = try await module.load()
        let accountID = try #require(state.currentAccountID)

        _ = await module.refresh(.current)

        let reloaded = try await module.load()
        let account = try #require(reloaded.accounts.first { $0.id == accountID })
        #expect(account.lastError == failure.code)
        let expectsReauth = failure == .authenticationRequired || failure == .tokenRefreshMalformed
        #expect(account.requiresReauth == expectsReauth)
    }

    private static let unusedCLI = GrokCLIClient(
        billing: { _ in throw GrokCLIError.requestFailed("unexpected billing") },
        loginOAuth: { _ in throw GrokCLIError.requestFailed("unexpected login") },
        version: { "grok 0.2.114" })

    private static func quota(now: Date) -> GrokQuotaSnapshot {
        quota(percent: 42.25, now: now)
    }

    private static func quota(percent: Double, now: Date) -> GrokQuotaSnapshot {
        GrokQuotaSnapshot(
            plan: "SuperGrok",
            includedUsagePercent: percent,
            period: GrokQuotaPeriod(
                kind: .weekly,
                startsAt: now,
                resetsAt: now.addingTimeInterval(7 * 24 * 3_600)),
            prepaidBalanceCents: 500,
            onDemandEnabled: true,
            onDemandUsedCents: 25,
            onDemandLimitCents: 1_000,
            source: .current,
            updatedAt: now)
    }

    private static func pendingHomes(in rootURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".grok-pending-") }
    }

    private static func waitForPendingHome(in rootURL: URL) async throws {
        for _ in 0..<100 {
            if try !pendingHomes(in: rootURL).isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the isolated Grok login home.")
    }

    private static func credential(
        email: String,
        userID: String,
        accessToken: String = "access-token-for-tests-only",
        expiresAt: String = "2099-08-01T12:00:00Z",
        refreshToken: String = "refresh-token-for-tests-only",
        clientID: String = "desktop-client"
    ) -> Data {
        Data(
            """
            {
              "https://auth.x.ai::\(clientID)": {
                "auth_mode": "oidc",
                "email": "\(email)",
                "expires_at": "\(expiresAt)",
                "key": "\(accessToken)",
                "oidc_client_id": "\(clientID)",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "principal-\(userID)",
                "principal_type": "User",
                "refresh_token": "\(refreshToken)",
                "user_id": "\(userID)"
              }
            }
            """.utf8)
    }

    private static func withAPIKey(_ credential: Data, key: String) -> Data {
        var root = (try? JSONSerialization.jsonObject(with: credential) as? [String: Any]) ?? [:]
        root[GrokAuthDocument.apiKeyScope] = [
            "auth_mode": "api_key",
            "key": key,
        ]
        return (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? credential
    }
}

private actor HomeRecorder {
    private(set) var values: [URL] = []

    func append(_ value: URL) {
        values.append(value)
    }
}

private actor TokenRefreshHitCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class MockGrokModuleTokenURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGrokModuleTokenURLProtocol.self]
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
        NonisolatedModuleTokenURLProtocolResponder.fulfill(request: request, handler: handler, protocol: self)
    }

    override func stopLoading() {}
}

/// Bridges async mock handlers back to URLProtocol without a sending-`self` Task capture.
private enum NonisolatedModuleTokenURLProtocolResponder {
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

private actor RefreshStartedSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor LoginCredentialWriter {
    private var credentials: [Data]

    init(credentials: [Data]) {
        self.credentials = credentials
    }

    func writeNext(to homeURL: URL) throws {
        guard !credentials.isEmpty else { throw GrokCLIError.requestFailed("missing fixture") }
        try credentials.removeFirst().write(to: homeURL.appendingPathComponent("auth.json"))
    }
}

private actor ProcessInspectionGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func inspect() async throws -> [Int32] {
        started = true
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return []
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum RefreshFailureFixture: CaseIterable, Equatable, Sendable {
    case cliUnavailable
    case authenticationRequired
    case timeout
    case billingParseFailed
    case tokenRefreshMalformed
    case cancelled
    case refreshFailed

    var code: String {
        switch self {
        case .cliUnavailable: "cli_unavailable"
        case .authenticationRequired: "authentication_required"
        case .timeout: "timeout"
        case .billingParseFailed: "billing_parse_failed"
        case .tokenRefreshMalformed: "authentication_required"
        case .cancelled: "cancelled"
        case .refreshFailed: "refresh_failed"
        }
    }

    func raise() throws -> Never {
        switch self {
        case .cliUnavailable:
            throw GrokCLIError.binaryNotFound
        case .authenticationRequired:
            throw GrokCLIError.authenticationRequired
        case .timeout:
            throw GrokCLIError.timeout(operation: "billing")
        case .billingParseFailed:
            throw GrokBillingDecodingError.unknownStructure
        case .tokenRefreshMalformed:
            throw GrokCLIError.malformedResponse("token refresh parse failed")
        case .cancelled:
            throw CancellationError()
        case .refreshFailed:
            throw GrokCLIError.requestFailed("fixture failure")
        }
    }
}

private struct Fixture {
    let root: URL
    let officialHome: URL
    let store: GrokAccountStore
    let now = Date(timeIntervalSince1970: 1_785_499_200)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-module-tests-\(UUID().uuidString)", isDirectory: true)
        officialHome = root.appendingPathComponent("official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialHome, withIntermediateDirectories: true)
        store = GrokAccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialHomeURL: officialHome)
    }

    func writeOfficial(_ data: Data) throws {
        try data.write(to: store.officialAuthURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
