import Foundation

/// Portable multi-account export format for cross-machine migration.
public enum AccountTransferFormat {
    public static let magic = "codex-runway-accounts"
    public static let currentVersion = 1
}

public enum AccountTransferError: Error, Sendable, Equatable {
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case emptySelection
    case noAccountsExported
    case providerMismatch(expected: RunwayProvider, actual: RunwayProvider)
    case invalidCredential
    case io(String)
}

public enum AccountImportConflict: Sendable, Equatable {
    case willAdd
    case willUpdate(existingDisplayName: String)
}

/// One row shown in the import preview sheet (no secrets).
public struct AccountTransferPreviewItem: Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var detail: String?
    public var conflict: AccountImportConflict

    public init(
        id: String,
        displayName: String,
        detail: String? = nil,
        conflict: AccountImportConflict)
    {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.conflict = conflict
    }
}

public struct AccountTransferPreview: Sendable, Equatable {
    public var provider: RunwayProvider
    public var items: [AccountTransferPreviewItem]
    public var failures: [String]
    public var sourceIsPack: Bool

    public init(
        provider: RunwayProvider,
        items: [AccountTransferPreviewItem] = [],
        failures: [String] = [],
        sourceIsPack: Bool = false)
    {
        self.provider = provider
        self.items = items
        self.failures = failures
        self.sourceIsPack = sourceIsPack
    }

    public var isEmpty: Bool { items.isEmpty }
}

public struct AccountTransferEntry: Sendable, Equatable {
    public var id: String?
    public var alias: String?
    public var displayName: String?
    public var email: String?
    /// Raw credential JSON (auth.json shape for the provider).
    public var credential: Data

    public init(
        id: String? = nil,
        alias: String? = nil,
        displayName: String? = nil,
        email: String? = nil,
        credential: Data)
    {
        self.id = id
        self.alias = alias
        self.displayName = displayName
        self.email = email
        self.credential = credential
    }
}

public struct AccountTransferPack: Sendable, Equatable {
    public var format: String
    public var version: Int
    public var provider: RunwayProvider
    public var exportedAt: Date
    public var appVersion: String?
    public var accounts: [AccountTransferEntry]

    public init(
        format: String = AccountTransferFormat.magic,
        version: Int = AccountTransferFormat.currentVersion,
        provider: RunwayProvider,
        exportedAt: Date = Date(),
        appVersion: String? = nil,
        accounts: [AccountTransferEntry])
    {
        self.format = format
        self.version = version
        self.provider = provider
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.accounts = accounts
    }
}

public enum AccountTransferCodec {
    public static func encode(_ pack: AccountTransferPack) throws -> Data {
        guard pack.format == AccountTransferFormat.magic else {
            throw AccountTransferError.unsupportedFormat(pack.format)
        }
        guard pack.version == AccountTransferFormat.currentVersion else {
            throw AccountTransferError.unsupportedVersion(pack.version)
        }

        var root: [String: Any] = [
            "format": pack.format,
            "version": pack.version,
            "provider": pack.provider.rawValue,
            "exportedAt": iso8601String(from: pack.exportedAt),
        ]
        if let appVersion = pack.appVersion, !appVersion.isEmpty {
            root["appVersion"] = appVersion
        }

        var accountObjects: [[String: Any]] = []
        for entry in pack.accounts {
            var object: [String: Any] = [:]
            if let id = entry.id, !id.isEmpty { object["id"] = id }
            if let alias = entry.alias, !alias.isEmpty { object["alias"] = alias }
            if let displayName = entry.displayName, !displayName.isEmpty { object["displayName"] = displayName }
            if let email = entry.email, !email.isEmpty { object["email"] = email }

            let credentialObject = try jsonObject(from: entry.credential)
            object["credential"] = credentialObject
            accountObjects.append(object)
        }
        root["accounts"] = accountObjects

        guard JSONSerialization.isValidJSONObject(root) else {
            throw AccountTransferError.io("invalid JSON graph")
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func decode(_ data: Data) throws -> AccountTransferPack {
        let object = try jsonRootObject(from: data)
        let format = object["format"] as? String ?? ""
        guard format == AccountTransferFormat.magic else {
            throw AccountTransferError.unsupportedFormat(format.isEmpty ? "missing" : format)
        }
        let version = object["version"] as? Int
            ?? (object["version"] as? NSNumber)?.intValue
            ?? -1
        guard version == AccountTransferFormat.currentVersion else {
            throw AccountTransferError.unsupportedVersion(version)
        }
        guard let providerRaw = object["provider"] as? String,
              let provider = RunwayProvider(rawValue: providerRaw)
        else {
            throw AccountTransferError.unsupportedFormat("missing provider")
        }

        let exportedAt: Date
        if let text = object["exportedAt"] as? String,
           let date = parseISO8601(text)
        {
            exportedAt = date
        } else {
            exportedAt = Date()
        }
        let appVersion = object["appVersion"] as? String

        guard let accountArray = object["accounts"] as? [[String: Any]] else {
            throw AccountTransferError.invalidCredential
        }

        var accounts: [AccountTransferEntry] = []
        for item in accountArray {
            guard let credentialValue = item["credential"] else {
                throw AccountTransferError.invalidCredential
            }
            let credentialData = try jsonData(from: credentialValue)
            accounts.append(AccountTransferEntry(
                id: nonEmptyString(item["id"]),
                alias: nonEmptyString(item["alias"]),
                displayName: nonEmptyString(item["displayName"]),
                email: nonEmptyString(item["email"]),
                credential: credentialData))
        }

        return AccountTransferPack(
            format: format,
            version: version,
            provider: provider,
            exportedAt: exportedAt,
            appVersion: appVersion,
            accounts: accounts)
    }

    /// Returns a decoded pack when `data` is a transfer pack; otherwise `nil` (caller falls back to raw credentials).
    public static func decodeIfPack(_ data: Data) -> AccountTransferPack? {
        guard let object = try? jsonRootObject(from: data),
              let format = object["format"] as? String,
              format == AccountTransferFormat.magic
        else {
            return nil
        }
        return try? decode(data)
    }

    public static func write(_ pack: AccountTransferPack, to url: URL) throws {
        let data = try encode(pack)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path)
        } catch {
            throw AccountTransferError.io(error.localizedDescription)
        }
    }

    // MARK: - JSON helpers

    private static func jsonRootObject(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw AccountTransferError.invalidCredential
        }
        return object
    }

    private static func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AccountTransferError.invalidCredential
        }
    }

    private static func jsonData(from value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw AccountTransferError.invalidCredential
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func parseISO8601(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}
