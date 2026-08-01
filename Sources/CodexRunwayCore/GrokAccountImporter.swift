import Foundation

public struct GrokAccountImportBatchResult: Sendable, Equatable {
    public var succeeded: [GrokManagedAccount]
    public var failures: [String]

    public init(succeeded: [GrokManagedAccount] = [], failures: [String] = []) {
        self.succeeded = succeeded
        self.failures = failures
    }

    public var successCount: Int { succeeded.count }
    public var failureCount: Int { failures.count }
}

/// Parses pasted Grok auth.json / credential JSON into managed-account payloads.
///
/// Accepted shapes (Grok-specific; not ChatGPT session JSON):
/// - Full `~/.grok/auth.json` with managed OAuth / legacy scopes
/// - A single credential object (`key` / `refresh_token` + identity fields)
/// - A JSON array of either form
/// - Newline-delimited JSON objects
public struct GrokAccountImporter: Sendable {
    public init() {}

    /// Returns normalized auth.json payloads that `GrokAuthDocument.parse` accepts.
    public func parsePayloads(from text: String) -> [Data] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        for payload in jsonPayloadCandidates(from: trimmed) {
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data)
            {
                let parsed = payloads(from: object)
                if !parsed.isEmpty { return uniquePayloads(parsed) }
            }
        }

        // Newline-delimited JSON objects (one account per line).
        let lines = trimmed.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if lines.count > 1 {
            var collected: [Data] = []
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                collected.append(contentsOf: payloads(from: object))
            }
            if !collected.isEmpty { return uniquePayloads(collected) }
        }

        return []
    }

    private func payloads(from value: Any) -> [Data] {
        if let array = value as? [Any] {
            return array.flatMap { payloads(from: $0) }
        }
        guard let object = value as? [String: Any] else { return [] }

        if isAuthRoot(object) {
            if let data = serializeJSON(object),
               (try? GrokAuthDocument.parse(data)) != nil
            {
                return [data]
            }
            return []
        }

        if isCredentialBody(object), let data = wrapCredentialBody(object) {
            return [data]
        }

        return []
    }

    private func isAuthRoot(_ object: [String: Any]) -> Bool {
        object.keys.contains { isManagedScope($0) }
    }

    private func isManagedScope(_ scope: String) -> Bool {
        scope.hasPrefix(GrokAuthDocument.oauthScopePrefix) || scope == GrokAuthDocument.legacyScope
    }

    private func isCredentialBody(_ object: [String: Any]) -> Bool {
        let hasToken = nonEmptyString(object["key"]) != nil
            || nonEmptyString(object["refresh_token"]) != nil
            || nonEmptyString(object["access_token"]) != nil
            || nonEmptyString(object["accessToken"]) != nil
        guard hasToken else { return false }
        return firstNonEmpty(
            nonEmptyString(object["email"]),
            nonEmptyString(object["user_id"]),
            nonEmptyString(object["principal_id"])) != nil
    }

    private func wrapCredentialBody(_ object: [String: Any]) -> Data? {
        var body = object
        // Normalize common alternate field names into the official Grok auth shape.
        if nonEmptyString(body["key"]) == nil {
            if let access = nonEmptyString(body["access_token"]) ?? nonEmptyString(body["accessToken"]) {
                body["key"] = access
            }
        }
        if nonEmptyString(body["refresh_token"]) == nil,
           let refresh = nonEmptyString(body["refreshToken"])
        {
            body["refresh_token"] = refresh
        }

        let scope = scopeForCredentialBody(body)
        if body["auth_mode"] == nil {
            body["auth_mode"] = scope == GrokAuthDocument.legacyScope ? "grok" : "oidc"
        }
        if scope != GrokAuthDocument.legacyScope {
            if body["oidc_issuer"] == nil {
                body["oidc_issuer"] = "https://auth.x.ai"
            }
            if body["oidc_client_id"] == nil {
                let client = scope.dropFirst(GrokAuthDocument.oauthScopePrefix.count)
                if !client.isEmpty {
                    body["oidc_client_id"] = String(client)
                }
            }
        }

        let root: [String: Any] = [scope: body]
        guard let data = serializeJSON(root),
              (try? GrokAuthDocument.parse(data)) != nil
        else {
            return nil
        }
        return data
    }

    private func scopeForCredentialBody(_ object: [String: Any]) -> String {
        let authMode = nonEmptyString(object["auth_mode"])?.lowercased()
        if authMode == "grok" || authMode == "web_login" {
            return GrokAuthDocument.legacyScope
        }
        if let clientID = nonEmptyString(object["oidc_client_id"]) {
            return "\(GrokAuthDocument.oauthScopePrefix)\(clientID)"
        }
        // Prefer OAuth when the body looks like an OIDC credential; otherwise legacy session.
        if authMode == "oidc"
            || nonEmptyString(object["oidc_issuer"]) != nil
            || nonEmptyString(object["refresh_token"]) != nil
            || nonEmptyString(object["refreshToken"]) != nil
            || nonEmptyString(object["principal_id"]) != nil
        {
            return "\(GrokAuthDocument.oauthScopePrefix)desktop-client"
        }
        return GrokAuthDocument.legacyScope
    }

    private func serializeJSON(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func uniquePayloads(_ payloads: [Data]) -> [Data] {
        var seen = Set<String>()
        var result: [Data] = []
        for data in payloads {
            guard let document = try? GrokAuthDocument.parse(data) else { continue }
            if seen.insert(document.stableID).inserted {
                result.append(data)
            }
        }
        return result
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whole string plus the first balanced `{...}` / `[...]` slice when paste includes extra text.
    private func jsonPayloadCandidates(from text: String) -> [String] {
        var payloads = [text]
        if let objectSlice = firstBalancedJSONSlice(in: text, open: "{", close: "}") {
            payloads.append(objectSlice)
        }
        if let arraySlice = firstBalancedJSONSlice(in: text, open: "[", close: "]") {
            payloads.append(arraySlice)
        }
        var seen = Set<String>()
        return payloads.filter { seen.insert($0).inserted }
    }

    private func firstBalancedJSONSlice(in text: String, open: Character, close: Character) -> String? {
        guard let start = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case open:
                    depth += 1
                case close:
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
