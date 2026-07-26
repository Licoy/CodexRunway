import Foundation

/// Process-level developer toggles (CLI flags / env). Never persisted.
enum RunwayDevFlags {
    /// `swift run CodexRunway -- --dev-tier-badges`
    /// or `CODEX_RUNWAY_DEV_TIER_BADGES=1`
    static var showsTierBadgeGallery: Bool {
        if CommandLine.arguments.contains("--dev-tier-badges") {
            return true
        }
        let env = ProcessInfo.processInfo.environment["CODEX_RUNWAY_DEV_TIER_BADGES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return env == "1" || env == "true" || env == "yes"
    }
}
