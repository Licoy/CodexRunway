import AppKit
import CodexRunwayCore
import SwiftUI

enum GrokPanelAvailability: Equatable {
    case loading
    case ready
    case cliUnavailable
    case notLoggedIn
    case reauthenticationRequired
    case cliTooOld
    case billingParseFailed
    case failed(String)
}

struct GrokPanelViewState: Equatable {
    var availability: GrokPanelAvailability = .loading
    var identityName: String?
    var planName: String?
    var quota: GrokQuotaPresentation?
    var externalLoginChanged = false

    static let loading = GrokPanelViewState()
}

struct GrokAccountIdentityRow: View {
    var plan: String?
    var displayName: String
    var l10n: L10n
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RunwayTag(plan ?? l10n.text(.providerGrok), tone: .neutral)
                Text(displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
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
            .padding(.horizontal, -6)
        }
        .buttonStyle(.plain)
        .help(l10n.text(.grokAccountsTitle))
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

struct GrokDashboardView: View {
    enum ContentSection: Equatable {
        case quota
        case billing
        case externalLoginWarning
    }

    static let installGuideURL = URL(string: "https://docs.x.ai/build/overview")!

    static func contentSections(for state: GrokPanelViewState) -> [ContentSection] {
        var sections: [ContentSection] = [.quota]
        if state.quota != nil {
            sections.append(.billing)
        }
        if state.externalLoginChanged {
            sections.append(.externalLoginWarning)
        }
        return sections
    }

    var state: GrokPanelViewState
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionBlock(isFirst: true) {
                quotaSection
            }
            if Self.contentSections(for: state).contains(.billing), let quota = state.quota {
                sectionBlock {
                    billingDetails(quota)
                }
            }
            if Self.contentSections(for: state).contains(.externalLoginWarning) {
                sectionBlock {
                    externalLoginWarning
                }
            }
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.grokIncludedQuota),
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if let quota = state.quota {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(quota.meters) { meter in
                        GrokQuotaMeterRow(meter: meter, l10n: l10n)
                    }
                }
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(emptyStateTitle, systemImage: emptyStateIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(emptyStateColor)
            if let detail = emptyStateDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.availability == .cliUnavailable {
                Button(l10n.text(.grokCLIOpenInstallGuide)) {
                    ExternalURLLauncher.open(Self.installGuideURL)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .runwayCard(.sunken)
    }

    private func billingDetails(_ quota: GrokQuotaPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.grokBillingPeriod))
                .font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(quota.lines.enumerated()), id: \.element.id) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(line.title)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(line.value)
                            .font(.callout.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .tableRowRule(isFirst: index == 0)
                }
                HStack {
                    Text(l10n.text(.grokUpdatedAt))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(quota.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.monospacedDigit())
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .tableRowRule(isFirst: quota.lines.isEmpty)
            }
            .runwayCard(.sunken)
        }
    }

    private var externalLoginWarning: some View {
        Label(l10n.text(.grokExternalLoginChanged), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionBlock<Content: View>(
        isFirst: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                RunwayHairline()
            }
            content()
                .padding(.top, isFirst ? 8 : 16)
                .padding(.bottom, 16)
        }
    }

    private var emptyStateTitle: String {
        switch state.availability {
        case .loading:
            return l10n.text(.grokRefreshing)
        case .ready:
            return l10n.text(.grokNoQuotaData)
        case .cliUnavailable:
            return l10n.text(.grokCLIUnavailable)
        case .notLoggedIn:
            return l10n.text(.grokNotLoggedIn)
        case .reauthenticationRequired:
            return l10n.text(.grokReauthenticationRequired)
        case .cliTooOld:
            return l10n.text(.grokCLITooOld)
        case .billingParseFailed:
            return l10n.text(.grokBillingParseFailed)
        case .failed:
            return l10n.text(.grokRefreshFailed)
        }
    }

    private var emptyStateDetail: String? {
        switch state.availability {
        case .cliUnavailable:
            return l10n.text(.grokCLIInstallHint)
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var emptyStateIcon: String {
        switch state.availability {
        case .loading:
            return "arrow.clockwise"
        case .ready, .notLoggedIn:
            return "person.crop.circle.badge.questionmark"
        case .cliUnavailable, .cliTooOld:
            return "terminal"
        case .reauthenticationRequired:
            return "person.badge.key"
        case .billingParseFailed, .failed:
            return "exclamationmark.triangle"
        }
    }

    private var emptyStateColor: Color {
        switch state.availability {
        case .billingParseFailed, .failed, .reauthenticationRequired:
            return Color(nsColor: .systemOrange)
        default:
            return .secondary
        }
    }
}

private struct GrokQuotaMeterRow: View {
    var meter: QuotaMeter
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(meter.remainingPercent)% \(l10n.text(.left))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(RunwayProgressBar.textColor(for: meter.health))
            }
            RunwayProgressBar(meter: meter)
                .frame(height: RunwayProgressBar.barHeight)
            if let resetsAt = meter.resetsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(l10n.text(.nextResetIn))\(DurationFormatter.localized(resetsAt.timeIntervalSince(context.date), language: l10n.language))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}
