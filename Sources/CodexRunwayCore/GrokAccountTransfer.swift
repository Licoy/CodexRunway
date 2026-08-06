import Foundation

/// Builds a portable Grok multi-account pack from the managed account library.
public struct GrokAccountExporter: Sendable {
    public var store: GrokAccountStore
    public var appVersion: String?

    public init(store: GrokAccountStore = GrokAccountStore(), appVersion: String? = nil) {
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
                    displayName: meta.resolvedDisplayName,
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
            provider: .grok,
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

public struct GrokAccountImportCandidate: Sendable {
    public var preview: AccountTransferPreviewItem
    public var alias: String?
    /// Normalized auth.json payload accepted by `GrokAuthDocument.parse`.
    public var credentialData: Data

    public var id: String { preview.id }

    public init(preview: AccountTransferPreviewItem, alias: String? = nil, credentialData: Data) {
        self.preview = preview
        self.alias = alias
        self.credentialData = credentialData
    }
}

public struct GrokAccountImportPreview: Sendable {
    public var items: [GrokAccountImportCandidate]
    public var failures: [String]
    public var sourceIsPack: Bool
    public var routedProvider: RunwayProvider

    public init(
        items: [GrokAccountImportCandidate] = [],
        failures: [String] = [],
        sourceIsPack: Bool = false,
        routedProvider: RunwayProvider = .grok)
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

/// Parses Grok transfer packs and raw credential files into a selectable preview.
public struct GrokAccountTransferImporter: Sendable {
    public var store: GrokAccountStore

    public init(store: GrokAccountStore = GrokAccountStore()) {
        self.store = store
    }

    public func previewFiles(at urls: [URL]) -> GrokAccountImportPreview {
        var items: [GrokAccountImportCandidate] = []
        var failures: [String] = []
        var sourceIsPack = false
        var routedProvider: RunwayProvider = .grok
        let importer = GrokAccountImporter()

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                if let pack = AccountTransferCodec.decodeIfPack(data) {
                    sourceIsPack = true
                    if pack.provider != .grok {
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
                let payloads = importer.parsePayloads(from: text)
                if payloads.isEmpty {
                    failures.append("\(url.lastPathComponent): no credentials found")
                } else {
                    items.append(contentsOf: previewPayloads(payloads, labelPrefix: url.lastPathComponent, alias: nil))
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if items.isEmpty, failures.isEmpty {
            failures.append("no_credentials")
        }
        return GrokAccountImportPreview(
            items: deduplicate(items),
            failures: failures,
            sourceIsPack: sourceIsPack,
            routedProvider: routedProvider)
    }

    public func previewPack(_ pack: AccountTransferPack) throws -> GrokAccountImportPreview {
        guard pack.provider == .grok else {
            throw AccountTransferError.providerMismatch(expected: .grok, actual: pack.provider)
        }
        let built = previewPackEntries(pack.accounts, labelPrefix: "pack")
        return GrokAccountImportPreview(
            items: deduplicate(built.items),
            failures: built.failures,
            sourceIsPack: true,
            routedProvider: .grok)
    }

    public func importPreviewSelection(
        _ candidates: [GrokAccountImportCandidate],
        selectedIDs: Set<String>,
        makeCurrentFirst: Bool = false) throws -> GrokAccountImportBatchResult
    {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else {
            return GrokAccountImportBatchResult(succeeded: [], failures: ["nothing_selected"])
        }

        let before = try store.loadIndex()
        let officialStatus = store.loadOfficialCredentialStatus()
        let canBootstrapCurrent = makeCurrentFirst && before.accounts.isEmpty && !officialStatus.hasManagedLogin

        var succeeded: [GrokManagedAccount] = []
        var failures: [String] = []
        var isFirst = true

        for candidate in selected {
            do {
                let makeCurrent = isFirst && canBootstrapCurrent
                var account = try store.upsertCredentialData(
                    candidate.credentialData,
                    makeCurrent: makeCurrent)
                if let alias = candidate.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                    account.alias = alias
                    try store.updateMetadata(account)
                }
                succeeded.append(account)
                isFirst = false
            } catch {
                failures.append("\(candidate.preview.displayName): import failed")
            }
        }
        return GrokAccountImportBatchResult(succeeded: succeeded, failures: failures)
    }

    // MARK: - Private

    private func previewPackEntries(
        _ entries: [AccountTransferEntry],
        labelPrefix: String) -> (items: [GrokAccountImportCandidate], failures: [String])
    {
        var items: [GrokAccountImportCandidate] = []
        var failures: [String] = []
        for (offset, entry) in entries.enumerated() {
            let label = "\(labelPrefix)[\(offset)]"
            do {
                let document = try GrokAuthDocument.parse(entry.credential)
                items.append(makeCandidate(
                    document: document,
                    credentialData: entry.credential,
                    alias: entry.alias,
                    displayOverride: entry.displayName,
                    emailOverride: entry.email,
                    label: label))
            } catch {
                failures.append("\(label): invalid credential")
            }
        }
        return (items, failures)
    }

    private func previewPayloads(
        _ payloads: [Data],
        labelPrefix: String,
        alias: String?) -> [GrokAccountImportCandidate]
    {
        payloads.enumerated().compactMap { offset, data in
            guard let document = try? GrokAuthDocument.parse(data) else { return nil }
            return makeCandidate(
                document: document,
                credentialData: data,
                alias: alias,
                displayOverride: nil,
                emailOverride: nil,
                label: "\(labelPrefix)[\(offset)]")
        }
    }

    private func makeCandidate(
        document: GrokAuthDocument,
        credentialData: Data,
        alias: String?,
        displayOverride: String?,
        emailOverride: String?,
        label: String) -> GrokAccountImportCandidate
    {
        let index = (try? store.loadIndex()) ?? GrokAccountIndex()
        let existing = index.accounts.first {
            $0.identity.stableID == document.identity.stableID
                || identitiesLooselyMatch($0.identity, document.identity)
        }
        let conflict: AccountImportConflict = if let existing {
            .willUpdate(existingDisplayName: existing.resolvedDisplayName)
        } else {
            .willAdd
        }
        let displayName = firstNonEmpty(
            alias,
            displayOverride,
            document.identity.resolvedDisplayName)
            ?? document.stableID
        let detail = firstNonEmpty(emailOverride, document.identity.email)
        let previewID = "grok-\(AccountIdentity.stableHash("\(label)|\(document.stableID)"))"
        return GrokAccountImportCandidate(
            preview: AccountTransferPreviewItem(
                id: previewID,
                displayName: displayName,
                detail: detail,
                conflict: conflict),
            alias: alias,
            credentialData: credentialData)
    }

    private func deduplicate(_ items: [GrokAccountImportCandidate]) -> [GrokAccountImportCandidate] {
        var seen = Set<String>()
        var result: [GrokAccountImportCandidate] = []
        for item in items {
            let key: String
            if let document = try? GrokAuthDocument.parse(item.credentialData) {
                key = document.stableID
            } else {
                key = item.id
            }
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    private func identitiesLooselyMatch(_ lhs: GrokCredentialIdentity, _ rhs: GrokCredentialIdentity) -> Bool {
        if lhs.stableID == rhs.stableID { return true }
        if let l = firstNonEmpty(lhs.userID), let r = firstNonEmpty(rhs.userID),
           l.caseInsensitiveCompare(r) == .orderedSame
        {
            return true
        }
        if let l = firstNonEmpty(lhs.principalID), let r = firstNonEmpty(rhs.principalID),
           l.caseInsensitiveCompare(r) == .orderedSame
        {
            return true
        }
        if let l = firstNonEmpty(lhs.email), let r = firstNonEmpty(rhs.email),
           l.caseInsensitiveCompare(r) == .orderedSame
        {
            return true
        }
        return false
    }
}

private extension GrokOfficialCredentialStatus {
    var hasManagedLogin: Bool {
        switch self {
        case .authenticated, .requiresReauthentication:
            true
        case .missing, .malformed, .unreadable, .apiKeyOnly, .unsupported:
            false
        }
    }
}
