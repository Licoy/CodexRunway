import Foundation

/// Grok / SuperGrok subscription tier identity for badges and plan labels.
///
/// Sources (precedence in ``GrokBillingClient``):
/// 1. CLI chat-proxy `/v1/settings` `subscription_tier_display` (e.g. `"SuperGrok"`)
/// 2. Billing response `subscription_tier` when present
/// 3. `/v1/user?include=subscription` internal keys (e.g. `"GrokPro"`)
/// 4. JWT `tier` claim on the OAuth access token (`prod_auth.SubscriptionTier`)
///
/// Mapping matches official Grok Build CLI (`jwt_tier_claim` / `normalize_tier`).
public enum GrokSubscriptionTier: Sendable, Equatable, Hashable, CaseIterable {
    case free
    case superGrok
    case superGrokHeavy
    case superGrokLite
    case superGrokPlus
    case xBasic
    case xPremium
    case xPremiumPlus
    case apiKey
    case unknown

    /// Canonical English label shown on badges (brand names stay unlocalized).
    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .superGrok: return "SuperGrok"
        case .superGrokHeavy: return "SuperGrok Heavy"
        case .superGrokLite: return "SuperGrok Lite"
        case .superGrokPlus: return "SuperGrok Plus"
        case .xBasic: return "X Basic"
        case .xPremium: return "X Premium"
        case .xPremiumPlus: return "X Premium+"
        case .apiKey: return "API Key"
        case .unknown: return "Unknown"
        }
    }

    /// Resolve a tier from API keys, JWT claim names, or display strings.
    public static func resolve(_ raw: String?) -> GrokSubscriptionTier {
        guard let trimmed = nonEmpty(raw) else { return .unknown }
        switch normalizeKey(trimmed) {
        case "free":
            return .free
        case "supergrok", "grokpro":
            return .superGrok
        case "supergrok_heavy", "supergrokpro", "supergrokheavy":
            return .superGrokHeavy
        case "supergrok_lite", "supergroklite":
            return .superGrokLite
        case "supergrok_plus", "supergrokplus":
            return .superGrokPlus
        case "x_basic", "xbasic":
            return .xBasic
        case "x_premium", "xpremium":
            return .xPremium
        case "x_premium_plus", "xpremiumplus", "x_premium_plus_":
            return .xPremiumPlus
        case "api_key", "apikey", "api":
            return .apiKey
        case "unknown":
            return .unknown
        default:
            return resolveFuzzy(normalizeKey(trimmed))
        }
    }

    /// Friendly label for UI tags, or `nil` when the raw value is empty.
    public static func displayName(from raw: String?) -> String? {
        guard let trimmed = nonEmpty(raw) else { return nil }
        let tier = resolve(trimmed)
        if tier != .unknown {
            return tier.displayName
        }
        // Already a display string such as "Tier 9" from an unknown JWT claim.
        return trimmed
    }

    /// Map `prod_auth.SubscriptionTier` numeric JWT claim to a display name.
    public static func displayName(fromJWTTierClaim tier: UInt64) -> String {
        let resolved = resolve(fromJWTTierClaim: tier)
        if resolved == .unknown {
            return "Tier \(tier)"
        }
        return resolved.displayName
    }

    public static func resolve(fromJWTTierClaim tier: UInt64) -> GrokSubscriptionTier {
        switch tier {
        case 0: return .free
        case 1: return .superGrok
        case 2: return .xBasic
        case 3: return .xPremium
        case 4: return .xPremiumPlus
        case 5: return .superGrokHeavy
        case 6: return .superGrokLite
        case 7: return .superGrokPlus
        default: return .unknown
        }
    }

    /// Decode the unsigned JWT payload and map the numeric `tier` claim when present.
    public static func displayName(fromAccessToken token: String) -> String? {
        guard let claim = jwtTierClaim(from: token) else { return nil }
        return displayName(fromJWTTierClaim: claim)
    }

    public static func resolve(fromAccessToken token: String) -> GrokSubscriptionTier? {
        guard let claim = jwtTierClaim(from: token) else { return nil }
        return resolve(fromJWTTierClaim: claim)
    }

    public static func jwtTierClaim(from token: String) -> UInt64? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let number = object["tier"] as? NSNumber {
            let value = number.int64Value
            guard value >= 0 else { return nil }
            return UInt64(value)
        }
        if let string = object["tier"] as? String, let value = UInt64(string) {
            return value
        }
        return nil
    }

    private static func resolveFuzzy(_ key: String) -> GrokSubscriptionTier {
        if key.contains("heavy") { return .superGrokHeavy }
        if key.contains("lite") && key.contains("supergrok") { return .superGrokLite }
        if key.contains("plus") && key.contains("supergrok") { return .superGrokPlus }
        if key.contains("premium") && (key.contains("plus") || key.hasSuffix("+")) {
            return .xPremiumPlus
        }
        if key.contains("premium") { return .xPremium }
        if key.contains("basic") && key.contains("x") { return .xBasic }
        if key.contains("supergrok") || key.contains("grokpro") { return .superGrok }
        if key.contains("api") { return .apiKey }
        if key.contains("free") { return .free }
        return .unknown
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var payload = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: payload)
    }

    private static func normalizeKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "+", with: "_plus")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
