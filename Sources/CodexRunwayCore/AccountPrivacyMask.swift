import Foundation

/// Display-only masking for account names, emails, and identifiers.
public enum AccountPrivacyMask {
    /// `example@qq.com` becomes `e***@***.com`.
    /// A non-email keeps its first character and replaces the rest with `***`.
    public static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        if let email = maskWholeEmail(trimmed) {
            return email
        }
        if trimmed.contains("@") {
            return maskEmails(in: trimmed)
        }
        return maskHead(trimmed)
    }

    /// Replaces email tokens inside a longer string and leaves the rest intact.
    public static func maskEmails(in text: String) -> String {
        guard text.contains("@") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let at = text[index...].firstIndex(of: "@") else {
                result.append(contentsOf: text[index...])
                break
            }
            let token = emailToken(in: text, at: at, searchFrom: index)
            result.append(contentsOf: text[index..<token.start])
            if token.local.isEmpty || token.domain.isEmpty {
                result.append(contentsOf: text[token.start..<token.end])
            } else {
                result.append(maskHead(token.local))
                result.append("@")
                result.append(maskDomain(token.domain))
            }
            index = token.end
        }
        return result
    }

    private struct EmailToken {
        var start: String.Index
        var end: String.Index
        var local: String
        var domain: String
    }

    private static func emailToken(
        in text: String,
        at: String.Index,
        searchFrom: String.Index) -> EmailToken
    {
        var localStart = at
        while localStart > searchFrom {
            let previous = text.index(before: localStart)
            if !isEmailTokenCharacter(text[previous]) { break }
            localStart = previous
        }
        var domainEnd = text.index(after: at)
        while domainEnd < text.endIndex, isEmailTokenCharacter(text[domainEnd]) {
            domainEnd = text.index(after: domainEnd)
        }
        while domainEnd > text.index(after: at), text[text.index(before: domainEnd)] == "." {
            domainEnd = text.index(before: domainEnd)
        }
        let local = String(text[localStart..<at])
        let domain = String(text[text.index(after: at)..<domainEnd])
        return EmailToken(start: localStart, end: domainEnd, local: local, domain: domain)
    }

    private static func maskWholeEmail(_ value: String) -> String? {
        guard let at = value.firstIndex(of: "@") else { return nil }
        let domainStart = value.index(after: at)
        guard domainStart < value.endIndex else { return nil }
        let local = value[..<at]
        let domain = value[domainStart...]
        guard !local.isEmpty, !domain.isEmpty, !domain.hasSuffix(".") else { return nil }
        guard !value.contains(where: \.isWhitespace), !domain.contains("@") else { return nil }
        return maskHead(String(local)) + "@" + maskDomain(String(domain))
    }

    private static func maskHead(_ value: String) -> String {
        guard let first = value.first else { return "***" }
        guard value.count > 1 else { return String(first) }
        return String(first) + "***"
    }

    /// `qq.com` and `mail.qq.com` both become `***.com`.
    private static func maskDomain(_ domain: String) -> String {
        guard let dot = domain.lastIndex(of: "."),
              dot > domain.startIndex,
              domain.index(after: dot) < domain.endIndex
        else { return "***" }
        return "***" + domain[dot...]
    }

    private static func isEmailTokenCharacter(_ character: Character) -> Bool {
        if character.isWhitespace || character == "@" { return false }
        switch character {
        case ",", ";", ":", "<", ">", "(", ")", "[", "]", "\"", "'", "{", "}":
            return false
        default:
            return true
        }
    }
}
