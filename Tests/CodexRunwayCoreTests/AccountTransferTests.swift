import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Account transfer pack")
struct AccountTransferTests {
    @Test("codex export pack round-trips selected accounts only")
    func codexRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = AccountStore(
            rootURL: root.appendingPathComponent("source"),
            officialAuthURL: root.appendingPathComponent("src-auth.json"))
        let accountA = try source.upsert(
            auth: sampleAuth(accountId: "acct-a", email: "a@example.com", refresh: "refresh-a-token-value"),
            makeActive: true,
            alias: "Alpha")
        let accountB = try source.upsert(
            auth: sampleAuth(accountId: "acct-b", email: "b@example.com", refresh: "refresh-b-token-value"),
            makeActive: false)

        let exported = try AccountExporter(store: source, appVersion: "test").export(accountIDs: [accountA.id])
        #expect(exported.exportedCount == 1)
        #expect(exported.pack.provider == .codex)
        #expect(exported.pack.accounts.count == 1)
        #expect(exported.pack.accounts[0].alias == "Alpha")
        #expect(exported.pack.accounts[0].email == "a@example.com")

        let data = try AccountTransferCodec.encode(exported.pack)
        let decoded = try AccountTransferCodec.decode(data)
        #expect(decoded.accounts.count == 1)

        let dest = AccountStore(
            rootURL: root.appendingPathComponent("dest"),
            officialAuthURL: root.appendingPathComponent("dst-auth.json"))
        let importer = AccountImporter(store: dest)
        let preview = try importer.previewPack(decoded)
        #expect(preview.items.count == 1)
        #expect(preview.items[0].preview.conflict == .willAdd)

        let batch = await importer.importPreviewSelection(
            preview.items,
            selectedIDs: Set(preview.items.map(\.id)),
            makeActiveFirst: true)
        #expect(batch.successCount == 1)
        let index = try dest.loadIndex()
        #expect(index.accounts.count == 1)
        #expect(index.accounts[0].alias == "Alpha")
        let cred = try dest.loadCredential(id: index.accounts[0].id)
        #expect(cred.tokens.refreshToken.hasPrefix("refresh-a"))

        // account B was not exported
        #expect(index.accounts.contains { $0.email == accountB.email } == false)
    }

    @Test("codex preview marks existing identity as willUpdate")
    func codexPreviewConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let existing = try store.upsert(
            auth: sampleAuth(accountId: "same", email: "same@example.com", refresh: "refresh-old-token-value"),
            makeActive: true,
            alias: "Local")

        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [
                AccountTransferEntry(
                    id: "remote-id",
                    alias: "Imported",
                    displayName: "same@example.com",
                    email: "same@example.com",
                    credential: try JSONEncoder().encode(
                        sampleAuth(accountId: "same", email: "same@example.com", refresh: "refresh-new-token-value"))),
            ])
        let importer = AccountImporter(store: store)
        let preview = try importer.previewPack(pack)
        #expect(preview.items.count == 1)
        if case let .willUpdate(name) = preview.items[0].preview.conflict {
            #expect(name == existing.resolvedDisplayName)
        } else {
            Issue.record("expected willUpdate conflict")
        }
    }

    @Test("codex import commits only selected preview rows")
    func codexPartialSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [
                AccountTransferEntry(
                    credential: try JSONEncoder().encode(
                        sampleAuth(accountId: "one", email: "one@example.com", refresh: "refresh-one-token-value"))),
                AccountTransferEntry(
                    credential: try JSONEncoder().encode(
                        sampleAuth(accountId: "two", email: "two@example.com", refresh: "refresh-two-token-value"))),
                AccountTransferEntry(
                    credential: try JSONEncoder().encode(
                        sampleAuth(accountId: "three", email: "three@example.com", refresh: "refresh-three-token-value"))),
            ])
        let importer = AccountImporter(store: store)
        let preview = try importer.previewPack(pack)
        #expect(preview.items.count == 3)
        let selected = Set(preview.items.prefix(2).map(\.id))
        let batch = await importer.importPreviewSelection(
            preview.items,
            selectedIDs: selected,
            makeActiveFirst: true)
        #expect(batch.successCount == 2)
        #expect(try store.loadIndex().accounts.count == 2)
    }

    @Test("codex preview and import keep same-workspace users separate")
    func codexSameWorkspaceUsersRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-same-workspace-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        _ = try store.upsert(auth: sampleAuth(
            accountId: "workspace-shared",
            email: "one@example.com",
            refresh: "refresh-member-one-old",
            userId: "user-one"))
        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [
                AccountTransferEntry(credential: try JSONEncoder().encode(sampleAuth(
                    accountId: "workspace-shared",
                    email: "one@example.com",
                    refresh: "refresh-member-one-token",
                    userId: "user-one"))),
                AccountTransferEntry(credential: try JSONEncoder().encode(sampleAuth(
                    accountId: "workspace-shared",
                    email: "two@example.com",
                    refresh: "refresh-member-two-token",
                    userId: "user-two"))),
            ])
        let importer = AccountImporter(store: store)
        let preview = try importer.previewPack(pack)

        #expect(preview.items.count == 2)
        #expect(preview.items.filter { $0.preview.conflict == .willAdd }.count == 1)
        #expect(preview.items.filter {
            if case .willUpdate = $0.preview.conflict { return true }
            return false
        }.count == 1)
        let batch = await importer.importPreviewSelection(
            preview.items,
            selectedIDs: Set(preview.items.map(\.id)))
        #expect(batch.successCount == 2)
        #expect(try store.loadIndex().accounts.count == 2)
    }

    @Test("rejects unsupported pack format and version")
    func rejectsBadPack() {
        let badFormat = Data(#"{"format":"other","version":1,"provider":"codex","accounts":[]}"#.utf8)
        #expect(throws: AccountTransferError.unsupportedFormat("other")) {
            try AccountTransferCodec.decode(badFormat)
        }
        let badVersion = Data(#"{"format":"codex-runway-accounts","version":99,"provider":"codex","accounts":[]}"#.utf8)
        #expect(throws: AccountTransferError.unsupportedVersion(99)) {
            try AccountTransferCodec.decode(badVersion)
        }
    }

    @Test("previewFiles routes non-codex pack provider")
    func routesForeignPack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = AccountTransferPack(provider: .grok, accounts: [])
        let url = root.appendingPathComponent("grok.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AccountTransferCodec.write(pack, to: url)

        let store = AccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialAuthURL: root.appendingPathComponent("auth.json"))
        let preview = AccountImporter(store: store).previewFiles(at: [url])
        #expect(preview.routedProvider == .grok)
        #expect(preview.items.isEmpty)
    }

    @Test("credential packs are written with owner-only permissions")
    func writesCredentialPackWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transfer-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("accounts.json")
        try Data("old-export".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: url.path)
        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [AccountTransferEntry(credential: Data(#"{"refresh_token":"test-secret"}"#.utf8))])

        try AccountTransferCodec.write(pack, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.uint16Value == 0o600)
        let decoded = try AccountTransferCodec.decode(Data(contentsOf: url))
        #expect(decoded.provider == pack.provider)
        #expect(decoded.accounts == pack.accounts)
    }

    @Test("permission failures do not leave an exported credential pack")
    func permissionFailureDoesNotLeaveCredentialPack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transfer-permission-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("accounts.json")
        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [AccountTransferEntry(credential: Data(#"{"refresh_token":"test-secret"}"#.utf8))])

        #expect(throws: AccountTransferError.self) {
            try AccountTransferCodec.write(pack, to: url, fileManager: PermissionFailureFileManager())
        }
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("final permission failures remove a replaced credential pack")
    func finalPermissionFailureRemovesReplacedCredentialPack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transfer-final-permission-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("accounts.json")
        try Data("old-export".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: url.path)
        let pack = AccountTransferPack(
            provider: .codex,
            accounts: [AccountTransferEntry(credential: Data(#"{"refresh_token":"test-secret"}"#.utf8))])

        #expect(throws: AccountTransferError.self) {
            try AccountTransferCodec.write(
                pack,
                to: url,
                fileManager: FinalPermissionFailureFileManager(destinationPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("grok export pack round-trips")
    func grokRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = GrokAccountStore(
            rootURL: root.appendingPathComponent("source"),
            officialHomeURL: root.appendingPathComponent("src-home"))
        let dataA = oauthData(email: "a@x.ai", userID: "user-a", principalID: "p-a", token: "token-a")
        let dataB = oauthData(email: "b@x.ai", userID: "user-b", principalID: "p-b", token: "token-b")
        let accountA = try source.upsertCredentialData(dataA, makeCurrent: true)
        var withAlias = accountA
        withAlias.alias = "Grok Alpha"
        try source.updateMetadata(withAlias)
        let accountB = try source.upsertCredentialData(dataB, makeCurrent: false)

        let exported = try GrokAccountExporter(store: source).export(accountIDs: [accountA.id])
        #expect(exported.exportedCount == 1)
        #expect(exported.pack.provider == .grok)
        #expect(exported.pack.accounts[0].alias == "Grok Alpha")

        let dest = GrokAccountStore(
            rootURL: root.appendingPathComponent("dest"),
            officialHomeURL: root.appendingPathComponent("dst-home"))
        let importer = GrokAccountTransferImporter(store: dest)
        let preview = try importer.previewPack(exported.pack)
        #expect(preview.items.count == 1)
        let batch = try importer.importPreviewSelection(
            preview.items,
            selectedIDs: Set(preview.items.map(\.id)),
            makeCurrentFirst: true)
        #expect(batch.successCount == 1)
        let index = try dest.loadIndex()
        #expect(index.accounts.count == 1)
        #expect(index.accounts[0].alias == "Grok Alpha")
        #expect(index.accounts[0].email == "a@x.ai")
        #expect(index.accounts.contains { $0.id == accountB.id } == false)
    }

    @Test("grok preview willUpdate on same identity")
    func grokPreviewConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GrokAccountStore(
            rootURL: root.appendingPathComponent("accounts"),
            officialHomeURL: root.appendingPathComponent("home"))
        let data = oauthData(email: "same@x.ai", userID: "same-user", principalID: "same-p", token: "old")
        let existing = try store.upsertCredentialData(data, makeCurrent: true)

        let newer = oauthData(email: "same@x.ai", userID: "same-user", principalID: "same-p", token: "new")
        let pack = AccountTransferPack(
            provider: .grok,
            accounts: [AccountTransferEntry(alias: "New", credential: newer)])
        let preview = try GrokAccountTransferImporter(store: store).previewPack(pack)
        #expect(preview.items.count == 1)
        if case let .willUpdate(name) = preview.items[0].preview.conflict {
            #expect(name == existing.resolvedDisplayName)
        } else {
            Issue.record("expected willUpdate")
        }
    }

    // MARK: - Fixtures

    private func sampleAuth(
        accountId: String,
        email: String,
        refresh: String,
        plan: String = "plus",
        userId: String? = nil) -> CodexAuth
    {
        var authClaims: [String: Any] = [
            "chatgpt_account_id": accountId,
            "chatgpt_plan_type": plan,
        ]
        if let userId {
            authClaims["chatgpt_user_id"] = userId
        }
        let idToken = jwt(payload: [
            "email": email,
            "https://api.openai.com/auth": authClaims,
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
            planType: plan)
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

    private func oauthData(
        email: String,
        userID: String,
        principalID: String,
        token: String) -> Data
    {
        Data(
            """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "email": "\(email)",
                "expires_at": "2099-08-01T12:00:00Z",
                "key": "\(token)-access-for-tests-only",
                "oidc_client_id": "desktop-client",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "\(principalID)",
                "refresh_token": "\(token)-refresh-for-tests-only",
                "user_id": "\(userID)"
              }
            }
            """.utf8)
    }
}

private final class PermissionFailureFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any] = [:],
        ofItemAtPath path: String) throws
    {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class FinalPermissionFailureFileManager: FileManager, @unchecked Sendable {
    private let destinationPath: String

    init(destinationPath: String) {
        self.destinationPath = destinationPath
        super.init()
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any] = [:],
        ofItemAtPath path: String) throws
    {
        if path == destinationPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
