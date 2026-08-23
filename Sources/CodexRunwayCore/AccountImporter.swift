import Foundation

public struct AccountImportItemResult: Sendable, Equatable {
    public var account: ManagedAccount?
    public var errorDescription: String?

    public var isSuccess: Bool { account != nil }
}

public struct AccountImportBatchResult: Sendable, Equatable {
    public var succeeded: [ManagedAccount]
    public var failures: [String]

    public var successCount: Int { succeeded.count }
    public var failureCount: Int { failures.count }
}

/// Parses local auth, pasted token/JSON, files, and API keys into managed accounts.
public struct AccountImporter: Sendable {
    public var store: AccountStore
    public var tokenRefresher: TokenRefresher

    public init(store: AccountStore = AccountStore(), tokenRefresher: TokenRefresher = TokenRefresher()) {
        self.store = store
        self.tokenRefresher = tokenRefresher
    }

    public func importOfficial(makeActive: Bool = true) throws -> ManagedAccount {
        try store.importOfficialAuth(makeActive: makeActive)
    }

    public func importAPIKey(_ apiKey: String, makeActive: Bool = false) throws -> ManagedAccount {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountStoreError.invalidCredential }
        let auth = CodexAuth.apiKey(apiKey: trimmed)
        return try store.upsert(auth: auth, makeActive: makeActive)
    }

    public func importPastedText(_ text: String, makeActiveFirst: Bool = false) async -> AccountImportBatchResult {
        let candidates = parseCandidates(from: text)
        if candidates.isEmpty {
            return AccountImportBatchResult(succeeded: [], failures: ["no_credentials"])
        }
        return await importCandidates(candidates, makeActiveFirst: makeActiveFirst)
    }

    public func importFiles(at urls: [URL], makeActiveFirst: Bool = false) async -> AccountImportBatchResult {
        var candidates: [ImportCandidate] = []
        var failures: [String] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? ""
                let parsed = parseCandidates(from: text)
                if parsed.isEmpty {
                    failures.append("\(url.lastPathComponent): no credentials found")
                } else {
                    candidates.append(contentsOf: parsed)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if candidates.isEmpty, failures.isEmpty {
            failures.append("no_credentials")
        }
        var batch = await importCandidates(candidates, makeActiveFirst: makeActiveFirst)
        batch = AccountImportBatchResult(succeeded: batch.succeeded, failures: failures + batch.failures)
        return batch
    }

    struct ImportCandidate: Sendable {
        var auth: CodexAuth?
        var refreshToken: String?
        var emailHint: String?
        var label: String
    }

    private func importCandidates(
        _ candidates: [ImportCandidate],
        makeActiveFirst: Bool) async -> AccountImportBatchResult
    {
        var succeeded: [ManagedAccount] = []
        var failures: [String] = []
        var isFirst = true
        for candidate in candidates {
            do {
                let auth = try await materialize(candidate)
                var account = try store.upsert(
                    auth: auth,
                    makeActive: makeActiveFirst && isFirst)
                // Session JSON often has user.email outside the JWT.
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
                failures.append("\(candidate.label): \(error.localizedDescription)")
            }
        }
        return AccountImportBatchResult(succeeded: succeeded, failures: failures)
    }

    private func materialize(_ candidate: ImportCandidate) async throws -> CodexAuth {
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

    func parseCandidates(from text: String) -> [ImportCandidate] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Prefer whole-text JSON; also recover when users paste with surrounding notes.
        for payload in jsonPayloadCandidates(from: trimmed) {
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data)
            {
                let parsed = parseJSONValue(object, label: "json")
                if !parsed.isEmpty { return parsed }
            }
        }

        // Newline-delimited JSON objects or bare refresh tokens.
        var candidates: [ImportCandidate] = []
        let lines = trimmed.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if lines.count > 1 {
            for (index, line) in lines.enumerated() {
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data)
                {
                    candidates.append(contentsOf: parseJSONValue(object, label: "line \(index + 1)"))
                } else if looksLikeToken(line) {
                    candidates.append(ImportCandidate(
                        auth: nil,
                        refreshToken: line,
                        emailHint: nil,
                        label: "line \(index + 1)"))
                }
            }
            if !candidates.isEmpty { return candidates }
        }

        if looksLikeToken(trimmed) {
            return [ImportCandidate(auth: nil, refreshToken: trimmed, emailHint: nil, label: "token")]
        }
        return []
    }

    private func parseJSONValue(_ value: Any, label: String) -> [ImportCandidate] {
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, item in
                parseJSONValue(item, label: "\(label)[\(index)]")
            }
        }
        guard let object = value as? [String: Any] else { return [] }

        // Full auth.json (snake_case Codex format)
        if object["tokens"] != nil || object["OPENAI_API_KEY"] != nil || object["auth_mode"] != nil {
            if let data = try? JSONSerialization.data(withJSONObject: object),
               let auth = try? JSONDecoder().decode(CodexAuth.self, from: data)
            {
                return [ImportCandidate(auth: auth, refreshToken: nil, emailHint: nil, label: label)]
            }
        }

        // ChatGPT /api/auth/session and similar browser session payloads.
        if let sessionAuth = parseSessionLikeObject(object) {
            let email = firstString(in: object, keys: ["email"])
                ?? nestedString(object["user"], keys: ["email"])
            return [ImportCandidate(auth: sessionAuth, refreshToken: nil, emailHint: email, label: label)]
        }

        // Simplified { email, refresh_token }
        let refresh = stringValue(object["refresh_token"])
            ?? stringValue(object["refreshToken"])
            ?? nestedRefreshToken(object["token"])
            ?? nestedRefreshToken(object["tokens"])
        if let refresh, !refresh.isEmpty {
            return [ImportCandidate(
                auth: nil,
                refreshToken: refresh,
                emailHint: stringValue(object["email"]),
                label: label)]
        }

        // API key object
        if let apiKey = stringValue(object["OPENAI_API_KEY"])
            ?? stringValue(object["api_key"])
            ?? stringValue(object["apiKey"])
        {
            return [ImportCandidate(
                auth: CodexAuth.apiKey(apiKey: apiKey),
                refreshToken: nil,
                emailHint: nil,
                label: label)]
        }
        return []
    }

    /// ChatGPT web session JSON typically looks like:
    /// `{ "user": { "email": "..." }, "account": { "id": "...", "planType": "plus" }, "accessToken": "eyJ..." }`
    private func parseSessionLikeObject(_ object: [String: Any]) -> CodexAuth? {
        let access = firstString(in: object, keys: [
            "accessToken", "access_token", "access_token_jwt",
        ])
            ?? nestedString(object["user"], keys: ["accessToken", "access_token"])
            ?? nestedString(object["session"], keys: ["accessToken", "access_token"])
            ?? nestedString(object["data"], keys: ["accessToken", "access_token"])

        let refresh = firstString(in: object, keys: ["refreshToken", "refresh_token"])
            ?? nestedString(object["session"], keys: ["refreshToken", "refresh_token"])
            ?? nestedString(object["tokens"], keys: ["refreshToken", "refresh_token"])
            ?? nestedString(object["token"], keys: ["refreshToken", "refresh_token"])

        let idToken = firstString(in: object, keys: ["idToken", "id_token"])
            ?? nestedString(object["session"], keys: ["idToken", "id_token"])

        guard let accessToken = firstNonEmpty(access), !accessToken.isEmpty else {
            // Refresh-only session fragment.
            if let refresh, !refresh.isEmpty {
                return CodexAuth(
                    authMode: "chatgpt",
                    tokens: .init(idToken: idToken, accessToken: "", refreshToken: refresh, accountId: nil),
                    lastRefresh: nil)
            }
            return nil
        }

        // Avoid treating random JWT-looking blobs as sessions without account/user context
        // when they also look like unrelated JSON — require at least token + one identity hint,
        // OR a clearly named accessToken field (already matched).
        let accountObject = object["account"] as? [String: Any]
        let userObject = object["user"] as? [String: Any]
        let accessClaims = CodexIdentityClaims.decode(accessToken)
        let idClaims = CodexIdentityClaims.decode(idToken)
        let accountId = firstNonEmpty(
            firstString(in: object, keys: ["account_id", "accountId", "chatgpt_account_id"]),
            firstString(in: accountObject ?? [:], keys: ["id", "account_id", "accountId"]),
            accessClaims?.accountId,
            idClaims?.accountId,
            accessClaims?.organizationId,
            idClaims?.organizationId)

        let plan = firstNonEmpty(
            firstString(in: object, keys: ["plan_type", "planType", "chatgpt_plan_type"]),
            firstString(in: accountObject ?? [:], keys: ["planType", "plan_type", "chatgpt_plan_type"]))

        // If this is only an access token string field with no other session shape, still accept
        // when the key was explicitly accessToken/access_token (handled by caller keys).
        let hasSessionShape = accountObject != nil
            || userObject != nil
            || object["expires"] != nil
            || object["authProvider"] != nil
            || object["accessToken"] != nil
            || object["access_token"] != nil
            || refresh != nil
        guard hasSessionShape else { return nil }

        return CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: firstNonEmpty(idToken, accessToken),
                accessToken: accessToken,
                refreshToken: refresh ?? "",
                accountId: accountId),
            lastRefresh: nil,
            planType: plan,
            authFilePlanType: plan)
    }

    private func nestedRefreshToken(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        return stringValue(object["refresh_token"]) ?? stringValue(object["refreshToken"])
    }

    private func nestedString(_ value: Any?, keys: [String]) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        return firstString(in: object, keys: keys)
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func looksLikeToken(_ value: String) -> Bool {
        // Refresh tokens are long opaque strings without spaces.
        value.count >= 20
            && !value.contains(" ")
            && !value.contains("{")
            && !value.contains("[")
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
        // Unique while preserving order.
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
