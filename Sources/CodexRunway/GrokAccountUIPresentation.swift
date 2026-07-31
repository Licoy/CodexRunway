import CodexRunwayCore

struct GrokAccountDetailCapabilities: Equatable {
    var canMoveUp: Bool
    var canMoveDown: Bool
    var canDelete: Bool

    static func make(index: Int, count: Int, isCurrent: Bool) -> Self {
        Self(
            canMoveUp: index > 0,
            canMoveDown: index >= 0 && index + 1 < count,
            canDelete: !isCurrent)
    }
}

enum GrokAccountLastErrorPresentation {
    static func text(for code: String, l10n: L10n) -> String {
        switch code {
        case "cli_unavailable":
            return l10n.text(.grokCLIUnavailable)
        case "authentication_required":
            return l10n.text(.grokReauthenticationRequired)
        case "timeout":
            return l10n.text(.grokRefreshTimedOut)
        case "billing_parse_failed":
            return l10n.text(.grokBillingParseFailed)
        case "cancelled":
            return l10n.text(.grokRefreshCancelled)
        case "refresh_failed":
            return l10n.text(.grokRefreshFailed)
        default:
            return l10n.text(.grokRefreshFailed)
        }
    }
}
