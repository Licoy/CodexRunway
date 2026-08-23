public extension RateLimitResetType {
    func localizedName(l10n: L10n) -> String {
        switch self {
        case .global:
            l10n.text(.rateLimitResetTypeGlobal)
        case .banked:
            l10n.text(.rateLimitResetTypeBanked)
        case .globalAndBanked:
            l10n.text(.rateLimitResetTypeGlobalAndBanked)
        }
    }
}
