import Foundation

public struct AccountExportResult: Sendable, Equatable {
    public var pack: AccountTransferPack
    public var exportedCount: Int
    public var failures: [String]

    public init(pack: AccountTransferPack, exportedCount: Int, failures: [String] = []) {
        self.pack = pack
        self.exportedCount = exportedCount
        self.failures = failures
    }
}

/// Builds a portable Codex multi-account pack from the managed account library.
public struct AccountExporter: Sendable {
    public var store: AccountStore
    public var appVersion: String?

    public init(store: AccountStore = AccountStore(), appVersion: String? = nil) {
        self.store = store
        self.appVersion = appVersion
    }

    public func export(accountIDs: [String], now: Date = Date()) throws -> AccountExportResult {
        guard !accountIDs.isEmpty else { throw AccountTransferError.emptySelection }

        let index = try store.loadIndex()
        var entries: [AccountTransferEntry] = []
        var failures: [String] = []

        for id in accountIDs {
            guard let meta = index.account(id: id) else {
                failures.append("\(id): account not found")
                continue
            }
            do {
                let credential = try store.loadCredentialData(id: id)
                entries.append(AccountTransferEntry(
                    id: meta.id,
                    alias: meta.alias,
                    displayName: meta.displayName,
                    email: meta.email,
                    credential: credential))
            } catch {
                failures.append("\(meta.resolvedDisplayName): credential missing")
            }
        }

        guard !entries.isEmpty else {
            throw AccountTransferError.noAccountsExported
        }

        let pack = AccountTransferPack(
            provider: .codex,
            exportedAt: now,
            appVersion: appVersion,
            accounts: entries)
        return AccountExportResult(pack: pack, exportedCount: entries.count, failures: failures)
    }

    public func write(accountIDs: [String], to url: URL, now: Date = Date()) throws -> AccountExportResult {
        let result = try export(accountIDs: accountIDs, now: now)
        try AccountTransferCodec.write(result.pack, to: url)
        return result
    }
}

// MARK: - Import preview payload (Codex)

public struct CodexAccountImportCandidate: Sendable {
    public var preview: AccountTransferPreviewItem
    public var alias: String?
    /// Full auth when known without network refresh.
    public var auth: CodexAuth?
    /// Refresh-only import (materialized on commit).
    public var refreshToken: String?
    public var emailHint: String?

    public var id: String { preview.id }

    public init(
        preview: AccountTransferPreviewItem,
        alias: String? = nil,
        auth: CodexAuth? = nil,
        refreshToken: String? = nil,
        emailHint: String? = nil)
    {
        self.preview = preview
        self.alias = alias
        self.auth = auth
        self.refreshToken = refreshToken
        self.emailHint = emailHint
    }
}

public struct CodexAccountImportPreview: Sendable {
    public var items: [CodexAccountImportCandidate]
    public var failures: [String]
    public var sourceIsPack: Bool
    /// When true, the file was a Grok pack opened via the Codex entry — UI should route to Grok.
    public var routedProvider: RunwayProvider

    public init(
        items: [CodexAccountImportCandidate] = [],
        failures: [String] = [],
        sourceIsPack: Bool = false,
        routedProvider: RunwayProvider = .codex)
    {
        self.items = items
        self.failures = failures
        self.sourceIsPack = sourceIsPack
        self.routedProvider = routedProvider
    }

    public var displayPreview: AccountTransferPreview {
        AccountTransferPreview(
            provider: routedProvider,
            items: items.map(\.preview),
            failures: failures,
            sourceIsPack: sourceIsPack)
    }
}

extension AccountImporter {
    /// Parse files into a selectable preview without writing the account library.
    public func previewFiles(at urls: [URL]) -> CodexAccountImportPreview {
        var items: [CodexAccountImportCandidate] = []
        var failures: [String] = []
        var sourceIsPack = false
        var routedProvider: RunwayProvider = .codex

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                if let pack = AccountTransferCodec.decodeIfPack(data) {
                    sourceIsPack = true
                    if pack.provider != .codex {
                        // Leave empty codex items; caller should re-route using the pack.
                        routedProvider = pack.provider
                        failures.append("\(url.lastPathComponent): provider is \(pack.provider.rawValue)")
                        continue
                    }
                    let built = previewPackEntries(pack.accounts, labelPrefix: url.lastPathComponent)
                    items.append(contentsOf: built.items)
                    failures.append(contentsOf: built.failures)
                    continue
                }

                let text = String(data: data, encoding: .utf8) ?? ""
                let candidates = parseCandidates(from: text)
                if candidates.isEmpty {
                    failures.append("\(url.lastPathComponent): no credentials found")
                } else {
                    items.append(contentsOf: previewRawCandidates(candidates, labelPrefix: url.lastPathComponent))
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if items.isEmpty, failures.isEmpty {
            failures.append("no_credentials")
        }

        // Deduplicate by match key while preserving order.
        items = deduplicateCandidates(items)
        return CodexAccountImportPreview(
            items: items,
            failures: failures,
            sourceIsPack: sourceIsPack,
            routedProvider: routedProvider)
    }

    /// Preview a pack already decoded as Codex.
    public func previewPack(_ pack: AccountTransferPack) throws -> CodexAccountImportPreview {
        guard pack.provider == .codex else {
            throw AccountTransferError.providerMismatch(expected: .codex, actual: pack.provider)
        }
        let built = previewPackEntries(pack.accounts, labelPrefix: "pack")
        return CodexAccountImportPreview(
            items: deduplicateCandidates(built.items),
            failures: built.failures,
            sourceIsPack: true,
            routedProvider: .codex)
    }

    /// Commit previously previewed candidates (by selection ids).
    public func importPreviewSelection(
        _ candidates: [CodexAccountImportCandidate],
        selectedIDs: Set<String>,
        makeActiveFirst: Bool = false) async -> AccountImportBatchResult
    {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else {
            return AccountImportBatchResult(succeeded: [], failures: ["nothing_selected"])
        }

        var succeeded: [ManagedAccount] = []
        var failures: [String] = []
        var isFirst = true

        for candidate in selected {
            do {
                let auth = try await materializePreview(candidate)
                var account = try store.upsert(
                    auth: auth,
                    makeActive: makeActiveFirst && isFirst,
                    alias: candidate.alias)
                if account.email == nil, let email = candidate.emailHint, !email.isEmpty {
                    account.email = email
                    if account.displayName.isEmpty || account.displayName == account.id {
                        account.displayName = email
                    }
                    try store.updateMetadata(account)
                }
                succeeded.append(account)
                isFirst = false
            } catch {
                failures.append("\(candidate.preview.displayName): \(error.localizedDescription)")
            }
        }
        return AccountImportBatchResult(succeeded: succeeded, failures: failures)
    }

    // MARK: - Private helpers

    private func previewPackEntries(
        _ entries: [AccountTransferEntry],
        labelPrefix: String) -> (items: [CodexAccountImportCandidate], failures: [String])
    {
        var items: [CodexAccountImportCandidate] = []
        var failures: [String] = []
        let index = (try? store.loadIndex()) ?? AccountIndex()

        for (offset, entry) in entries.enumerated() {
            let label = "\(labelPrefix)[\(offset)]"
            do {
                let auth = try JSONDecoder().decode(CodexAuth.self, from: entry.credential)
                let display = ManagedAccount.make(auth: auth, alias: entry.alias)
                let match = AccountIdentity.matchKey(for: auth)
                let existing = index.accounts.first { AccountIdentity.matchKey(for: $0) == match }
                let conflict: AccountImportConflict = if let existing {
                    .willUpdate(existingDisplayName: existing.resolvedDisplayName)
                } else {
                    .willAdd
                }
                let displayName = firstNonEmpty(entry.alias, entry.displayName, display.resolvedDisplayName)
                    ?? display.id
                let detail = firstNonEmpty(entry.email, display.email)
                let previewID = "codex-\(AccountIdentity.stableHash("\(label)|\(match)"))"
                items.append(CodexAccountImportCandidate(
                    preview: AccountTransferPreviewItem(
                        id: previewID,
                        displayName: displayName,
                        detail: detail,
                        conflict: conflict),
                    alias: entry.alias,
                    auth: auth,
                    refreshToken: nil,
                    emailHint: entry.email ?? display.email))
            } catch {
                failures.append("\(label): invalid credential")
            }
        }
        return (items, failures)
    }

    private func previewRawCandidates(
        _ candidates: [ImportCandidate],
        labelPrefix: String) -> [CodexAccountImportCandidate]
    {
        let index = (try? store.loadIndex()) ?? AccountIndex()
        var items: [CodexAccountImportCandidate] = []

        for (offset, candidate) in candidates.enumerated() {
            let label = "\(labelPrefix)[\(offset)]"
            if let auth = candidate.auth {
                let display = ManagedAccount.make(auth: auth)
                let match = AccountIdentity.matchKey(for: auth)
                let existing = index.accounts.first { AccountIdentity.matchKey(for: $0) == match }
                let conflict: AccountImportConflict = if let existing {
                    .willUpdate(existingDisplayName: existing.resolvedDisplayName)
                } else {
                    .willAdd
                }
                let previewID = "codex-\(AccountIdentity.stableHash("\(label)|\(match)"))"
                items.append(CodexAccountImportCandidate(
                    preview: AccountTransferPreviewItem(
                        id: previewID,
                        displayName: firstNonEmpty(display.resolvedDisplayName, candidate.emailHint, candidate.label)
                            ?? candidate.label,
                        detail: candidate.emailHint ?? display.email,
                        conflict: conflict),
                    alias: nil,
                    auth: auth,
                    refreshToken: nil,
                    emailHint: candidate.emailHint))
            } else if let refresh = candidate.refreshToken {
                let hint = candidate.emailHint
                let match = "rt:\(AccountIdentity.stableHash(refresh))"
                let previewID = "codex-\(AccountIdentity.stableHash("\(label)|\(match)"))"
                items.append(CodexAccountImportCandidate(
                    preview: AccountTransferPreviewItem(
                        id: previewID,
                        displayName: firstNonEmpty(hint, candidate.label) ?? "token",
                        detail: hint,
                        conflict: .willAdd),
                    alias: nil,
                    auth: nil,
                    refreshToken: refresh,
                    emailHint: hint))
            }
        }
        return items
    }

    private func deduplicateCandidates(_ items: [CodexAccountImportCandidate]) -> [CodexAccountImportCandidate] {
        var seen = Set<String>()
        var result: [CodexAccountImportCandidate] = []
        for item in items {
            let key: String
            if let auth = item.auth {
                key = AccountIdentity.matchKey(for: auth)
            } else if let refresh = item.refreshToken {
                key = "rt:\(AccountIdentity.stableHash(refresh))"
            } else {
                key = item.id
            }
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    private func materializePreview(_ candidate: CodexAccountImportCandidate) async throws -> CodexAuth {
        if var auth = candidate.auth {
            if auth.isAPIKeyAuth {
                return auth
            }
            if auth.canRefreshOAuth,
               auth.tokens.accessToken.isEmpty || TokenInspector.isExpired(auth.tokens.accessToken)
            {
                try await tokenRefresher.refresh(&auth, store: nil)
            } else if auth.tokens.accessToken.isEmpty {
                throw AccountStoreError.invalidCredential
            } else if TokenInspector.isExpired(auth.tokens.accessToken), !auth.canRefreshOAuth {
                throw URLError(.userAuthenticationRequired)
            }
            return auth
        }
        guard let refresh = candidate.refreshToken, !refresh.isEmpty else {
            throw AccountStoreError.invalidCredential
        }
        var auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(idToken: nil, accessToken: "", refreshToken: refresh, accountId: nil),
            lastRefresh: nil)
        try await tokenRefresher.refresh(&auth, store: nil)
        return auth
    }
}
