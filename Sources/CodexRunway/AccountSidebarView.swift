import AppKit
import CodexRunwayCore
import SwiftUI

/// Accounts list shown as a popover detail page (same navigation pattern as reset credits).
struct AccountsDetailView: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n
    var onAddAccount: () -> Void

    @State private var accountPendingSwitch: ManagedAccount?
    @State private var restartAfterSwitch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            PolishedScrollView(verticalPadding: 0, fadesEdges: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.sidebarAccounts.isEmpty {
                        Text(l10n.text(.accountsEmpty))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
                    } else {
                        ForEach(model.sidebarAccounts) { account in
                            AccountDetailCard(
                                account: account,
                                isActive: account.id == model.activeAccountId,
                                l10n: l10n,
                                isBusy: model.isSwitchingAccount,
                                isRefreshing: model.isRefreshingAccountQuota(id: account.id))
                            {
                                restartAfterSwitch = true
                                accountPendingSwitch = account
                            } onRefresh: {
                                model.refreshAccountQuota(id: account.id)
                            }
                        }
                    }
                    if let message = model.accountOperationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: Binding(
            get: { accountPendingSwitch != nil },
            set: { if !$0 { accountPendingSwitch = nil } }))
        {
            AccountSwitchConfirmSheet(
                accountName: accountPendingSwitch?.resolvedDisplayName ?? "",
                l10n: l10n,
                restartAfterSwitch: $restartAfterSwitch,
                onConfirm: {
                    if let id = accountPendingSwitch?.id {
                        model.switchAccount(id: id, restartCodex: restartAfterSwitch)
                    }
                    accountPendingSwitch = nil
                },
                onCancel: {
                    accountPendingSwitch = nil
                })
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolbarGhostButton(
                title: l10n.text(.accountsRefreshAll),
                systemImage: "arrow.clockwise",
                isLoading: model.isRefreshingAccountQuotas)
            {
                model.refreshAllAccountQuotas()
            }
            Spacer()
            ToolbarAccentButton(title: l10n.text(.accountsAdd), systemImage: "plus", action: onAddAccount)
        }
    }
}

/// Quiet toolbar action: icon + label, transparent at rest, neutral pill on hover.
private struct ToolbarGhostButton: View {
    var title: String
    var systemImage: String
    var isLoading: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.medium))
                }
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(isHovered && !isLoading ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isHovered && !isLoading ? RunwaySurface.hoverNeutral : Color.clear,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .padding(.leading, -9)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help(title)
        .accessibilityLabel(title)
        .pointingHandCursor(enabled: !isLoading)
        .onHover { isHovered = $0 }
    }
}

/// Accent CTA matching the Calculate-button chassis.
private struct ToolbarAccentButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 11)
            .frame(minHeight: 26)
            .background(
                isHovered ? Color.accentColor.opacity(0.88) : Color.accentColor,
                in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

private struct AccountDetailCard: View {
    var account: ManagedAccount
    var isActive: Bool
    var l10n: L10n
    var isBusy: Bool
    var isRefreshing: Bool
    var onSelect: () -> Void
    var onRefresh: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if account.requiresReauth {
                statusLine(l10n.text(.accountsNeedsReauth), color: Color(nsColor: .systemRed))
            } else if let error = account.lastError {
                statusLine(error, color: Color(nsColor: .systemOrange))
            }
            quotaBlock
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: RunwaySurface.radiusCard, style: .continuous)
            if isActive {
                shape.fill(Color(nsColor: .systemGreen).opacity(colorScheme == .light ? 0.10 : 0.12))
            } else {
                shape.fill(isHovered ? RunwaySurface.hoverNeutral : RunwaySurface.raised)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: RunwaySurface.radiusCard, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1))
        .onHover { isHovered = $0 }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.resolvedDisplayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if isActive {
                        CurrentAccountTag(l10n: l10n)
                    }
                    SubscriptionTierTag(tier: account.subscriptionTier, l10n: l10n)
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                AccountIconActionButton(
                    title: isActive ? l10n.text(.accountsIsCurrentLogin) : l10n.text(.accountsMakeCurrent),
                    systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
                    isDisabled: isActive || isBusy || isRefreshing,
                    tone: isActive ? .current : .normal,
                    action: onSelect)
                AccountIconActionButton(
                    title: l10n.text(.refresh),
                    systemImage: "arrow.clockwise",
                    isDisabled: isRefreshing,
                    isLoading: isRefreshing,
                    tone: .normal,
                    action: onRefresh)
            }
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
    }

    @ViewBuilder
    private var quotaBlock: some View {
        if let quota = account.cachedQuota {
            // Titles follow the same windowMinutes / named-window rules as the main popover.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(quota.meterRows()) { row in
                    miniMeter(
                        title: row.title(l10n: l10n),
                        remaining: row.remainingPercent,
                        used: row.usedPercent,
                        resetsAt: row.resetsAt)
                }
            }
        } else if account.authMode == .apiKey {
            Text(l10n.text(.accountsAPIKeyHint))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text(l10n.text(.notLoaded))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func miniMeter(title: String, remaining: Int, used: Int, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(remaining)% \(l10n.text(.left))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(RunwayProgressBar.textColor(for: QuotaMeter.health(forUsedPercent: used)))
            }
            GeometryReader { proxy in
                let fill = max(3, proxy.size.width * CGFloat(remaining) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(meterTrack)
                    Capsule()
                        .fill(barColor(used: used))
                        .frame(width: fill)
                }
            }
            .frame(height: 5)
            if let resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(l10n.text(.nextResetIn))\(DurationFormatter.localized(resetsAt.timeIntervalSince(context.date), language: l10n.language))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func barColor(used: Int) -> Color {
        switch QuotaMeter.health(forUsedPercent: used) {
        case .green: return Color(nsColor: .systemGreen)
        case .yellow: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }

    private var cardStroke: Color {
        if isActive {
            return Color(nsColor: .systemGreen).opacity(colorScheme == .light ? 0.28 : 0.35)
        }
        return colorScheme == .dark ? RunwaySurface.hairline : Color.clear
    }

    private var meterTrack: Color {
        if isActive {
            return Color(nsColor: .systemGreen).opacity(0.12)
        }
        return RunwaySurface.sunken
    }
}

/// Icon button with the same hover treatment as the main popover header actions.
private struct AccountIconActionButton: View {
    enum Tone {
        case normal
        case current
    }

    var title: String
    var systemImage: String
    var isDisabled: Bool = false
    var isLoading: Bool = false
    var tone: Tone = .normal
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: systemImage)
                        .font(.body)
                        .frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(iconColor)
            .frame(width: 28, height: 24)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering in
            // Keep hover feedback for disabled "current" so the tooltip affordance is clear.
            isHovered = hovering && !isLoading && (tone == .current || !isDisabled)
        }
    }

    private var iconColor: Color {
        if isLoading { return Color.secondary }
        switch tone {
        case .current:
            return Color(nsColor: .systemGreen)
        case .normal:
            if isDisabled { return Color.secondary }
            return isHovered ? Color.accentColor : Color.primary
        }
    }

    private var buttonBackground: Color {
        if tone == .current {
            return isHovered
                ? Color(nsColor: .systemGreen).opacity(0.16)
                : Color(nsColor: .systemGreen).opacity(0.10)
        }
        if isDisabled || isLoading { return Color.clear }
        return isHovered ? RunwaySurface.hoverAccent : Color.clear
    }
}

/// Shared plan tag for accounts UI.
struct SubscriptionTierTag: View {
    var tier: CodexSubscriptionTier
    var l10n: L10n

    var body: some View {
        SubscriptionTierBadge(
            tier: tier,
            label: SubscriptionTierBadge.localizedTitle(for: tier, l10n: l10n),
            horizontalPadding: 5,
            verticalPadding: 1)
    }
}
