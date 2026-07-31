import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Grok account UI presentation")
@MainActor
struct GrokAccountUIPresentationTests {
    @Test("missing CLI opens the current official Grok overview")
    func installGuideUsesOfficialOverview() {
        #expect(GrokDashboardView.installGuideURL.absoluteString == "https://docs.x.ai/build/overview")
    }

    @Test("external identity warning remains visible without quota data")
    func externalIdentityWarningDoesNotRequireQuota() {
        let state = GrokPanelViewState(
            availability: .ready,
            quota: nil,
            externalLoginChanged: true)

        #expect(GrokDashboardView.contentSections(for: state) == [
            .quota,
            .externalLoginWarning,
        ])
    }

    @Test("account detail actions respect ordering and protect the current account")
    func accountDetailCapabilities() {
        let first = GrokAccountDetailCapabilities.make(index: 0, count: 3, isCurrent: false)
        let current = GrokAccountDetailCapabilities.make(index: 1, count: 3, isCurrent: true)
        let last = GrokAccountDetailCapabilities.make(index: 2, count: 3, isCurrent: false)

        #expect(!first.canMoveUp)
        #expect(first.canMoveDown)
        #expect(first.canDelete)
        #expect(current.canMoveUp)
        #expect(current.canMoveDown)
        #expect(!current.canDelete)
        #expect(last.canMoveUp)
        #expect(!last.canMoveDown)
        #expect(last.canDelete)
    }

    @Test("stable account error codes are localized and legacy text is not exposed")
    func accountErrorsAreLocalized() {
        let english = L10n(language: .english)
        let chinese = L10n(language: .simplifiedChinese)

        #expect(GrokAccountLastErrorPresentation.text(for: "cli_unavailable", l10n: english)
            == "Grok CLI is not installed")
        #expect(GrokAccountLastErrorPresentation.text(for: "authentication_required", l10n: chinese)
            == "Grok 登录已失效，请重新登录。")
        #expect(GrokAccountLastErrorPresentation.text(for: "timeout", l10n: english)
            == "Grok billing request timed out.")
        #expect(GrokAccountLastErrorPresentation.text(for: "billing_parse_failed", l10n: chinese)
            == "Grok 返回了不支持的账单结构。请更新 CLI，或稍后重试。")
        #expect(GrokAccountLastErrorPresentation.text(for: "cancelled", l10n: english)
            == "Grok billing refresh was cancelled.")
        #expect(GrokAccountLastErrorPresentation.text(for: "refresh_failed", l10n: chinese)
            == "Grok 额度刷新失败")
        #expect(GrokAccountLastErrorPresentation.text(
            for: "Grok billing request timed out.",
            l10n: english) == "Could not refresh Grok billing")
    }
}
