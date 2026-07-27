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
    /// Dev mock renders only: start on a detail page instead of the summary.
    var initialDetailPage: RunwaySidePanel? = nil

    var body: some View {
        RunwayPopoverView(
            model: model,
            settings: settings,
            checkForUpdates: checkForUpdates,
            openGitHub: openGitHub,
            openControlPanel: openControlPanel,
            initialDetailPage: initialDetailPage)
            .environment(\.runwayPanelVisible, mainPanelVisibility.isVisible)
    }
}

struct RunwayPopoverView: View {
    static let panelSize = CGSize(width: 400, height: 584)

    @ObservedObject var model: RunwayModel
    @ObservedObject var settings: RunwaySettings
    var checkForUpdates: () -> Void
    var openGitHub: () -> Void
    var openControlPanel: (ControlPanelTab) -> Void

    @State private var confirmRepair = false
    @State private var detailPage: RunwaySidePanel?
    @State private var apiCostDetailRange = ApiCostSummaryRange.today
    private var l10n: L10n { settings.l10n }

    init(
        model: RunwayModel,
        settings: RunwaySettings,
        checkForUpdates: @escaping () -> Void,
        openGitHub: @escaping () -> Void,
        openControlPanel: @escaping (ControlPanelTab) -> Void,
        initialDetailPage: RunwaySidePanel? = nil)
    {
        self.model = model
        self.settings = settings
        self.checkForUpdates = checkForUpdates
        self.openGitHub = openGitHub
        self.openControlPanel = openControlPanel
        _detailPage = State(initialValue: initialDetailPage)
        // Mock renders land on the api-cost page without a user tap; current-cycle
        // is the only range whose data is seeded on the model.
        if initialDetailPage == .apiCost {
            _apiCostDetailRange = State(initialValue: .current)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if detailPage == nil {
                    header
                } else {
                    detailHeader
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            RunwayHairline()
            if let detailPage {
                DetailPageView(
                    page: detailPage,
                    model: model,
                    l10n: l10n,
                    apiCostInitialRange: apiCostDetailRange,
                    onAddAccount: {
                        openControlPanel(.accounts)
                    })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            } else {
                mainContent
                    .padding(.horizontal, 16)
                if model.accountOperationMessage != nil || model.lastError != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        if let message = model.accountOperationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = model.lastError {
                            Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                RunwayHairline()
                footer
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: 0) {
                if RunwayDevFlags.showsTierBadgeGallery {
                    sectionBlock(isFirst: true) {
                        DevTierBadgeGallery(l10n: l10n)
                    }
                }
                sectionBlock(isFirst: !RunwayDevFlags.showsTierBadgeGallery) {
                    QuotaMetersView(
                        title: l10n.text(.quota),
                        meters: model.quotaMeters,
                        l10n: l10n,
                        isRefreshing: model.isRefreshing(.quota),
                        onRefresh: { model.refreshQuota() })
                }
                if settings.preferences.showsTokenUsageHeatmap {
                    sectionBlock {
                        TokenUsageHeatmapView(
                            allDevicesTokens: model.tokenHeatmapAllDevicesTokens,
                            localTokens: model.tokenHeatmapLocalTokens,
                            calculatedAt: model.tokenHeatmapCalculatedAt,
                            l10n: l10n,
                            isRefreshing: model.isRefreshing(.tokenHeatmap),
                            onRefresh: { model.refreshTokenHeatmap(policy: .force) })
                    }
                }
                if settings.preferences.showsRateLimitResetToday {
                    sectionBlock {
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
                }
                sectionBlock {
                    ResetCreditsSummaryView(
                        summary: model.resetCreditSummary,
                        l10n: l10n,
                        isRefreshing: model.isRefreshing(.resetCredits),
                        onRefresh: { model.refreshResetCredits() },
                        onDetailsSelect: { detailPage = .resetCredits })
                }
                if settings.preferences.showsCostSummary {
                    sectionBlock {
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
                }
                if settings.preferences.showsSessionRepairSummary {
                    sectionBlock {
                        sessionSummary
                    }
                }
                if settings.preferences.showsRecentSessions {
                    sectionBlock {
                        RecentSessionsView(
                            sessions: model.recentSessions,
                            l10n: l10n,
                            isRefreshing: model.isRefreshing(.recentSessions),
                            onRefresh: { model.refreshRecentSessions() })
                    }
                }
            }
        }
    }

    /// Ruled section rhythm: an inset hairline above every section except the first.
    @ViewBuilder
    private func sectionBlock<Content: View>(
        isFirst: Bool = false,
        @ViewBuilder content: () -> Content) -> some View
    {
        if !isFirst {
            RunwayHairline()
        }
        content()
            .padding(.top, isFirst ? 8 : 16)
            .padding(.bottom, 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("Codex Runway")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    HeaderActionButton(title: l10n.text(.checkForUpdates), action: checkForUpdates) {
                        BootstrapIconImage(.cloudArrowDown)
                    }
                    HeaderActionButton(title: "GitHub", action: openGitHub) {
                        BootstrapIconImage(.github)
                    }
                    HeaderActionButton(title: l10n.text(.refresh), isLoading: model.isRefreshing) {
                        model.refresh()
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            AccountIdentityRow(
                tier: model.accountDisplay.subscriptionTier,
                displayName: accountDisplayName,
                l10n: l10n)
            {
                detailPage = .accounts
                model.reloadAccountIndex()
            }
            .padding(.top, 10)
            if let expiresAt = model.accountDisplay.subscriptionExpiresAt {
                SubscriptionExpiryBadge(expiresAt: expiresAt, l10n: l10n)
                    .padding(.top, 6)
            }
        }
    }

    private var accountDisplayName: String {
        if !model.accountDisplay.displayName.isEmpty {
            return model.accountDisplay.displayName
        }
        return model.accountDisplay.isAuthenticated ? l10n.text(.unknownAccount) : l10n.text(.notLoggedIn)
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            DetailBackButton(title: l10n.text(.back)) {
                detailPage = nil
            }
            Text(detailTitle(detailPage))
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
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
                l10n: l10n,
                isRefreshing: model.isRefreshing(.sessionRepair),
                onRefresh: { model.refreshSessionReport() })
            Text(model.isRefreshing(.sessionRepair) && model.sessionLines.isEmpty ? l10n.text(.calculating) : model.sessionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            SidePanelDisclosureRow(
                title: l10n.text(.repairIndex),
                systemImage: "cross.case",
                showsChevron: false)
            {
                confirmRepair = true
            }
        }
    }

    private var footer: some View {
        HStack {
            FooterGhostButton(
                title: l10n.text(.settings),
                systemImage: "slider.horizontal.3",
                role: .normal,
                help: l10n.text(.openControlPanel))
            {
                openControlPanel(.general)
            }
            Spacer()
            FooterGhostButton(
                title: l10n.text(.quit),
                systemImage: "power",
                role: .destructive,
                help: l10n.text(.quit))
            {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// 1pt hairline rule in the shared stroke token.
struct RunwayHairline: View {
    var body: some View {
        Rectangle()
            .fill(RunwaySurface.hairline)
            .frame(height: 1)
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

/// Header identity row: tier plate + metallic identity text, one hover pill.
private struct AccountIdentityRow: View {
    var tier: CodexSubscriptionTier
    var displayName: String
    var l10n: L10n
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SubscriptionBadge(tier: tier, l10n: l10n)
                SubscriptionTierShimmerText(
                    tier: tier,
                    text: displayName,
                    truncationMode: .middle)
                    .frame(maxWidth: 200, alignment: .leading)
                    .layoutPriority(0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            // Negative inset keeps the badge on the 16pt grid while the pill breathes.
            .padding(.horizontal, -6)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(l10n.text(.accounts))
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

/// Two-segment "boarding pass" chip: tinted status segment with a countdown ring,
/// neutral mono-digit data segment. Static — the tier badge carries the motion.
struct SubscriptionExpiryBadge: View {
    var expiresAt: Date
    var l10n: L10n
    var now: Date = Date()

    @Environment(\.colorScheme) private var colorScheme

    private var plate: RoundedRectangle {
        RoundedRectangle(cornerRadius: RunwaySurface.radiusPlate, style: .continuous)
    }

    var body: some View {
        let look = phaseLook
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if isExpired {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                } else {
                    countdownRing(tint: look.ring)
                }
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(look.statusForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxHeight: .infinity)
            .background(look.statusFill)

            Rectangle()
                .fill(look.stroke.opacity(0.5))
                .frame(width: 1)

            HStack(spacing: 4) {
                Text(dateText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                if let remainingText {
                    Text("·")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.45)
                    Text(remainingText)
                        .font(.caption2.monospacedDigit().weight(.medium))
                }
            }
            .foregroundStyle(dataForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxHeight: .infinity)
            .background(RunwaySurface.sunken)
        }
        .fixedSize()
        .clipShape(plate)
        .overlay {
            plate.strokeBorder(look.stroke, lineWidth: 1)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Remaining fraction of a 30-day reference window (billing month), drawn as a
    /// tiny progress ring. Static per render — no animation.
    private func countdownRing(tint: Color) -> some View {
        let fraction = max(0, min(1, remainingSeconds / (30 * 24 * 3_600)))
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }

    private var remainingSeconds: TimeInterval {
        max(0, SubscriptionDateFormatter.endOfLocalDay(expiresAt).timeIntervalSince(now))
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
        if remainingSeconds <= 7 * 24 * 3_600 {
            return .expiringSoon
        }
        return .active
    }

    private struct Look {
        var ring: Color
        var statusForeground: Color
        var statusFill: Color
        var stroke: Color
    }

    private var phaseLook: Look {
        let light = colorScheme == .light
        switch phase {
        case .active:
            let tint = Color(nsColor: .systemGreen)
            return Look(
                ring: light ? Color(red: 0.10, green: 0.52, blue: 0.28) : tint,
                statusForeground: light ? Color(red: 0.08, green: 0.42, blue: 0.22) : tint,
                statusFill: tint.opacity(light ? 0.16 : 0.26),
                stroke: tint.opacity(light ? 0.35 : 0.42))
        case .expiringSoon:
            let tint = Color(nsColor: .systemOrange)
            return Look(
                ring: light ? Color(red: 0.72, green: 0.38, blue: 0.05) : tint,
                statusForeground: light ? Color(red: 0.62, green: 0.32, blue: 0.04) : tint,
                statusFill: tint.opacity(light ? 0.18 : 0.26),
                stroke: tint.opacity(light ? 0.40 : 0.46))
        case .expired:
            let tint = Color(nsColor: .systemRed)
            return Look(
                ring: tint,
                statusForeground: light ? .white : Color(red: 1.0, green: 0.80, blue: 0.80),
                // Solid alarm fill deep enough for white AA text in light mode.
                statusFill: light ? Color(red: 0.78, green: 0.13, blue: 0.11) : tint.opacity(0.42),
                stroke: tint.opacity(0.55))
        }
    }

    private var dataForeground: Color {
        colorScheme == .light ? Color(nsColor: .secondaryLabelColor) : Color.white.opacity(0.78)
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
        return DurationFormatter.localized(
            remainingSeconds,
            language: l10n.language,
            includeSeconds: false)
    }

    private var accessibilityText: String {
        [statusLabel, dateText, remainingText].compactMap(\.self).joined(separator: " ")
    }
}

private struct HeaderActionButton<Icon: View>: View {
    var title: String
    var isLoading: Bool = false
    var action: () -> Void
    @ViewBuilder var icon: Icon

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    icon.frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .frame(width: 26, height: 24)
            .background(
                isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
    }
}

/// Leading back affordance on detail pages (chevron + label, quiet until hovered).
private struct DetailBackButton: View {
    var title: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .padding(.leading, -8)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

/// Quiet borderless footer button; destructive role surfaces red only on hover.
private struct FooterGhostButton: View {
    enum Role {
        case normal
        case destructive
    }

    var title: String
    var systemImage: String
    var role: Role
    var help: String
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.medium))
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                hoverFill,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        guard isHovered else { return .secondary }
        switch role {
        case .normal:
            return .primary
        case .destructive:
            return colorScheme == .light
                ? Color(red: 0.75, green: 0.12, blue: 0.15)
                : Color(nsColor: .systemRed)
        }
    }

    private var hoverFill: Color {
        guard isHovered else { return .clear }
        switch role {
        case .normal:
            return RunwaySurface.hoverNeutral
        case .destructive:
            return Color(nsColor: .systemRed).opacity(0.10)
        }
    }
}
