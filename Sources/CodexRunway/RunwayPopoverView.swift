import AppKit
import CodexRunwayCore
import SwiftUI

/// Root wrapper so panel visibility can refresh the environment without rebuilding
/// `RunwayPopoverView` identity from AppKit on every show/hide.
struct RunwayPopoverRootView: View {
    @ObservedObject var model: RunwayModel
    @ObservedObject var settings: RunwaySettings
    @ObservedObject var mainPanelVisibility: MainPanelVisibility
    var checkForUpdates: () -> Void
    var openGitHub: () -> Void
    var openControlPanel: (ControlPanelTab) -> Void

    var body: some View {
        RunwayPopoverView(
            model: model,
            settings: settings,
            checkForUpdates: checkForUpdates,
            openGitHub: openGitHub,
            openControlPanel: openControlPanel)
            .environment(\.runwayPanelVisible, mainPanelVisibility.isVisible)
    }
}

struct RunwayPopoverView: View {
    @ObservedObject var model: RunwayModel
    @ObservedObject var settings: RunwaySettings
    var checkForUpdates: () -> Void
    var openGitHub: () -> Void
    var openControlPanel: (ControlPanelTab) -> Void

    @State private var confirmRepair = false
    @State private var detailPage: RunwaySidePanel?
    @State private var apiCostDetailRange = ApiCostSummaryRange.today
    private var l10n: L10n { settings.l10n }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailPage == nil ? AnyView(header) : AnyView(detailHeader)
            Divider()
            if let detailPage {
                DetailPageView(
                    page: detailPage,
                    model: model,
                    l10n: l10n,
                    apiCostInitialRange: apiCostDetailRange,
                    onAddAccount: {
                        openControlPanel(.accounts)
                    })
            } else {
                mainContent
                if let message = model.accountOperationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                footer
            }
        }
        .padding(16)
        .frame(width: 390, height: 560, alignment: .topLeading)
        .preferredColorScheme(settings.colorScheme)
        .alert(l10n.text(.repairConfirmTitle), isPresented: $confirmRepair) {
            Button(l10n.text(.repair), role: .destructive) { model.repairSessions() }
            Button(l10n.text(.cancel), role: .cancel) {}
        } message: {
            Text(model.repairWarning)
        }
    }

    private var mainContent: some View {
        PolishedScrollView(verticalPadding: 4) {
            VStack(alignment: .leading, spacing: 14) {
                if RunwayDevFlags.showsTierBadgeGallery {
                    DevTierBadgeGallery(l10n: l10n)
                }
                QuotaMetersView(
                    title: l10n.text(.quota),
                    meters: model.quotaMeters,
                    l10n: l10n,
                    isRefreshing: model.isRefreshing(.quota),
                    onRefresh: { model.refreshQuota() })
                if settings.preferences.showsRateLimitResetToday {
                    RateLimitResetTodayView(
                        snapshot: model.rateLimitResetToday,
                        l10n: l10n,
                        isRefreshing: model.isRefreshing(.rateLimitResetToday),
                        onRefresh: { model.refreshRateLimitResetToday(force: true) },
                        onOpenSource: {
                            ExternalURLLauncher.open(RateLimitResetTodayClient.siteURL)
                        },
                        onOpenTweet: { url in
                            ExternalURLLauncher.open(url)
                        })
                }
                ResetCreditsSummaryView(
                    summary: model.resetCreditSummary,
                    l10n: l10n,
                    isRefreshing: model.isRefreshing(.resetCredits),
                    onRefresh: { model.refreshResetCredits() },
                    onDetailsSelect: { detailPage = .resetCredits })
                if settings.preferences.showsCostSummary {
                    CostSummaryView(
                        text: model.costText,
                        subtitle: model.costSubtitle,
                        l10n: l10n,
                        isRefreshing: model.isRefreshing(.apiCost),
                        onRefresh: { model.refreshCost() },
                        onDetailsSelect: {
                            apiCostDetailRange = settings.preferences.apiCostSummaryRange
                            detailPage = .apiCost
                        })
                }
                if settings.preferences.showsSessionRepairSummary {
                    sessionSummary
                }
                if settings.preferences.showsRecentSessions {
                    RecentSessionsView(
                        sessions: model.recentSessions,
                        l10n: l10n,
                        isRefreshing: model.isRefreshing(.recentSessions),
                        onRefresh: { model.refreshRecentSessions() })
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex Runway").font(.title3.bold())
                accountIdentityRow
                if let expiresAt = model.accountDisplay.subscriptionExpiresAt {
                    SubscriptionExpiryBadge(expiresAt: expiresAt, l10n: l10n)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                HeaderActionButton(title: l10n.text(.checkForUpdates), action: checkForUpdates) {
                    BootstrapIconImage(.cloudArrowDown)
                }
                HeaderActionButton(title: "GitHub", action: openGitHub) {
                    BootstrapIconImage(.github)
                }
                HeaderActionButton(title: l10n.text(.refresh)) {
                    model.refresh()
                } icon: {
                    Image(systemName: model.isRefreshingAll ? "hourglass" : "arrow.clockwise")
                }
            }
        }
    }

    /// Plan badge + identity text (same font / metal tint / glyph sheen as the tier, no capsule).
    private var accountIdentityRow: some View {
        let tier = model.accountDisplay.subscriptionTier
        return Button {
            detailPage = .accounts
            model.reloadAccountIndex()
        } label: {
            HStack(spacing: 6) {
                SubscriptionBadge(tier: tier, l10n: l10n)
                SubscriptionTierShimmerText(
                    tier: tier,
                    text: accountDisplayName,
                    truncationMode: .middle)
                    .frame(maxWidth: 196, alignment: .leading)
                    .layoutPriority(0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n.text(.accounts))
    }

    private var accountDisplayName: String {
        if !model.accountDisplay.displayName.isEmpty {
            return model.accountDisplay.displayName
        }
        return model.accountDisplay.isAuthenticated ? l10n.text(.unknownAccount) : l10n.text(.notLoggedIn)
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detailTitle(detailPage))
                    .font(.title3.bold())
                Text("Codex Runway")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                detailPage = nil
            } label: {
                Label(l10n.text(.back), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
        }
    }

    private func detailTitle(_ page: RunwaySidePanel?) -> String {
        switch page {
        case .accounts:
            return l10n.text(.accounts)
        case .resetCredits:
            return l10n.text(.resetCreditDetails)
        case .apiCost:
            return l10n.text(.apiCost)
        case nil:
            return ""
        }
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.sessionRepair),
                systemImage: "wrench.and.screwdriver",
                l10n: l10n,
                isRefreshing: model.isRefreshing(.sessionRepair),
                onRefresh: { model.refreshSessionReport() })
            Text(model.isRefreshing(.sessionRepair) && model.sessionLines.isEmpty ? l10n.text(.calculating) : model.sessionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button { confirmRepair = true } label: {
                HStack {
                    Label(l10n.text(.repairIndex), systemImage: "cross.case")
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openControlPanel(.general)
            } label: {
                Label(l10n.text(.settings), systemImage: "slider.horizontal.3")
            }
            .help(l10n.text(.openControlPanel))
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(l10n.text(.quit), systemImage: "power")
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct SubscriptionBadge: View {
    var tier: CodexSubscriptionTier
    var l10n: L10n

    var body: some View {
        SubscriptionTierBadge(
            tier: tier,
            label: SubscriptionTierBadge.localizedTitle(for: tier, l10n: l10n))
    }
}

/// Compact capsule under the account row: icon · label · date · optional remaining.
/// Soft tinted chip (not solid fill) so light mode stays calm next to metallic plan badges.
struct SubscriptionExpiryBadge: View {
    var expiresAt: Date
    var l10n: L10n
    var now: Date = Date()

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let look = phaseLook
        HStack(spacing: 5) {
            Image(systemName: isExpired ? "calendar.badge.exclamationmark" : "calendar")
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
            separator
            Text(dateText)
                .font(.caption2.monospacedDigit().weight(.medium))
            if let remainingText {
                separator
                Text(remainingText)
                    .font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(look.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: look.fill,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
        }
        .overlay {
            Capsule()
                .strokeBorder(look.stroke, lineWidth: colorScheme == .light ? 1.0 : 0.85)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Still active through the expiry calendar day in the local timezone.
    private var isExpired: Bool {
        SubscriptionDateFormatter.isExpired(expiresAt, now: now)
    }

    private enum Phase {
        case active
        case expiringSoon
        case expired
    }

    private var phase: Phase {
        if isExpired { return .expired }
        let endOfDay = SubscriptionDateFormatter.endOfLocalDay(expiresAt)
        if endOfDay.timeIntervalSince(now) <= 7 * 24 * 3_600 {
            return .expiringSoon
        }
        return .active
    }

    private struct Look {
        var foreground: Color
        var fill: [Color]
        var stroke: Color
    }

    private var phaseLook: Look {
        let light = colorScheme == .light
        switch phase {
        case .active:
            return softLook(
                tint: Color(nsColor: .systemGreen),
                light: light,
                deep: Color(red: 0.08, green: 0.42, blue: 0.22))
        case .expiringSoon:
            return softLook(
                tint: Color(nsColor: .systemOrange),
                light: light,
                deep: Color(red: 0.62, green: 0.32, blue: 0.04))
        case .expired:
            return softLook(
                tint: Color(nsColor: .systemRed),
                light: light,
                deep: Color(red: 0.58, green: 0.10, blue: 0.12))
        }
    }

    /// Soft wash + tinted label (light); translucent tint chip (dark). Avoids solid “paint blob” fills.
    private func softLook(tint: Color, light: Bool, deep: Color) -> Look {
        if light {
            return Look(
                foreground: deep,
                fill: [
                    tint.opacity(0.14),
                    tint.opacity(0.08),
                ],
                stroke: tint.opacity(0.34))
        }
        return Look(
            foreground: tint,
            fill: [
                tint.opacity(0.28),
                tint.opacity(0.16),
            ],
            stroke: tint.opacity(0.42))
    }

    private var statusLabel: String {
        switch phase {
        case .active:
            return l10n.text(.subscriptionExpires)
        case .expiringSoon:
            return l10n.text(.subscriptionExpiringSoon)
        case .expired:
            return l10n.text(.subscriptionExpired)
        }
    }

    private var dateText: String {
        SubscriptionDateFormatter.expiresOn(expiresAt, language: l10n.language)
    }

    private var remainingText: String? {
        guard !isExpired else { return nil }
        let endOfDay = SubscriptionDateFormatter.endOfLocalDay(expiresAt)
        return DurationFormatter.localized(
            max(0, endOfDay.timeIntervalSince(now)),
            language: l10n.language,
            includeSeconds: false)
    }

    private var separator: some View {
        Text("·")
            .font(.caption2.weight(.semibold))
            .opacity(0.55)
    }

    private var accessibilityText: String {
        [statusLabel, dateText, remainingText].compactMap(\.self).joined(separator: " ")
    }
}

private struct HeaderActionButton<Icon: View>: View {
    var title: String
    var action: () -> Void
    @ViewBuilder var icon: Icon

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            icon.frame(width: 14, height: 14)
            .foregroundStyle(isHovered ? Color.accentColor : Color.primary)
            .frame(width: 28, height: 24)
            .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
    }
}
