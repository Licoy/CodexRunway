import Foundation

public enum GrokManagedAuthKind: String, Codable, Sendable, Equatable {
    case oauth
    case legacySession
}

public struct GrokCredentialIdentity: Codable, Sendable, Equatable {
    public var kind: GrokManagedAuthKind
    public var scope: String
    public var issuer: String?
    public var clientID: String?
    public var email: String?
    public var userID: String?
    public var principalID: String?
    public var principalType: String?
    public var teamID: String?
    public var teamName: String?
    public var expiresAt: Date?
    public var hasAccessToken: Bool
    public var hasRefreshToken: Bool

    public init(
        kind: GrokManagedAuthKind,
        scope: String,
        issuer: String? = nil,
        clientID: String? = nil,
        email: String? = nil,
        userID: String? = nil,
        principalID: String? = nil,
        principalType: String? = nil,
        teamID: String? = nil,
        teamName: String? = nil,
        expiresAt: Date? = nil,
        hasAccessToken: Bool,
        hasRefreshToken: Bool)
    {
        self.kind = kind
        self.scope = scope
        self.issuer = issuer
        self.clientID = clientID
        self.email = email
        self.userID = userID
        self.principalID = principalID
        self.principalType = principalType
        self.teamID = teamID
        self.teamName = teamName
        self.expiresAt = expiresAt
        self.hasAccessToken = hasAccessToken
        self.hasRefreshToken = hasRefreshToken
    }

    public var stableID: String {
        "grok-\(AccountIdentity.stableHash(stableIdentityKey))"
    }

    public var resolvedDisplayName: String {
        firstNonEmpty(email, teamName, userID, principalID) ?? stableID
    }

    fileprivate var stableIdentityKey: String {
        let normalizedIssuer = firstNonEmpty(issuer)?.lowercased() ?? "https://auth.x.ai"
        let team = firstNonEmpty(teamID)?.lowercased() ?? "personal"
        if let userID = firstNonEmpty(userID) {
            return "\(normalizedIssuer)|user|\(userID.lowercased())|\(team)"
        }
        if let principalID = firstNonEmpty(principalID) {
            return "\(normalizedIssuer)|principal|\(principalID.lowercased())|\(team)"
        }
        return "\(normalizedIssuer)|email|\(email?.lowercased() ?? "")|\(team)"
    }
}

public enum GrokAuthDocumentError: Error, Sendable, Equatable {
    case invalidRoot
    case noManagedCredential
    case invalidManagedCredential
}

public struct GrokAuthDocument: Sendable, Equatable {
    public static let oauthScopePrefix = "https://auth.x.ai::"
    public static let legacyScope = "https://accounts.x.ai/sign-in"
    public static let apiKeyScope = "xai::api_key"

    public var rawData: Data
    public var identity: GrokCredentialIdentity
    public var managedScopeKeys: [String]

    public init(rawData: Data, identity: GrokCredentialIdentity, managedScopeKeys: [String]) {
        self.rawData = rawData
        self.identity = identity
        self.managedScopeKeys = managedScopeKeys
    }

    public var stableID: String {
        identity.stableID
    }

    public func requiresReauthentication(at date: Date = Date()) -> Bool {
        guard identity.hasAccessToken else { return true }
        guard let expiresAt = identity.expiresAt else { return false }
        return expiresAt <= date && !identity.hasRefreshToken
    }

    public static func parse(_ data: Data) throws -> GrokAuthDocument {
        let root = try rootObject(from: data)
        let managedScopes = root.keys.filter(isManagedScope).sorted()
        guard let selectedScope = managedScopes.first(where: { $0.hasPrefix(oauthScopePrefix) })
            ?? managedScopes.first
        else {
            throw GrokAuthDocumentError.noManagedCredential
        }
        guard let object = root[selectedScope] as? [String: Any] else {
            throw GrokAuthDocumentError.invalidManagedCredential
        }

        let identity = try parseIdentity(scope: selectedScope, object: object)
        return GrokAuthDocument(rawData: data, identity: identity, managedScopeKeys: managedScopes)
    }

    public static func replacingManagedScopes(in officialData: Data?, with targetData: Data) throws -> Data {
        let targetDocument = try parse(targetData)
        var official = try officialData.map(rootObject(from:)) ?? [:]
        let target = try rootObject(from: targetData)

        let replacedScopes = official.keys.filter(isManagedScope)
        for scope in replacedScopes {
            official.removeValue(forKey: scope)
        }
        guard let targetCredential = target[targetDocument.identity.scope] else {
            throw GrokAuthDocumentError.invalidManagedCredential
        }
        official[targetDocument.identity.scope] = targetCredential

        guard JSONSerialization.isValidJSONObject(official) else {
            throw GrokAuthDocumentError.invalidRoot
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: official,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw GrokAuthDocumentError.invalidRoot
        }
    }

    private static func rootObject(from data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GrokAuthDocumentError.invalidRoot
        }
        guard let root = object as? [String: Any] else {
            throw GrokAuthDocumentError.invalidRoot
        }
        return root
    }

    private static func isManagedScope(_ scope: String) -> Bool {
        scope.hasPrefix(oauthScopePrefix) || scope == legacyScope
    }

    private static func parseIdentity(scope: String, object: [String: Any]) throws -> GrokCredentialIdentity {
        let kind: GrokManagedAuthKind = scope == legacyScope ? .legacySession : .oauth
        let email = nonEmptyString(object["email"])
        let userID = nonEmptyString(object["user_id"])
        let principalID = nonEmptyString(object["principal_id"])
        guard firstNonEmpty(principalID, userID, email) != nil else {
            throw GrokAuthDocumentError.invalidManagedCredential
        }
        let expiresAt: Date?
        if let rawExpiresAt = nonEmptyString(object["expires_at"]) {
            guard let parsed = parseDate(rawExpiresAt) else {
                throw GrokAuthDocumentError.invalidManagedCredential
            }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }
        return GrokCredentialIdentity(
            kind: kind,
            scope: scope,
            issuer: nonEmptyString(object["oidc_issuer"]),
            clientID: nonEmptyString(object["oidc_client_id"]),
            email: email,
            userID: userID,
            principalID: principalID,
            principalType: nonEmptyString(object["principal_type"]),
            teamID: nonEmptyString(object["team_id"]),
            teamName: nonEmptyString(object["team_name"]),
            expiresAt: expiresAt,
            hasAccessToken: nonEmptyString(object["key"]) != nil,
            hasRefreshToken: nonEmptyString(object["refresh_token"]) != nil)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return firstNonEmpty(value)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
