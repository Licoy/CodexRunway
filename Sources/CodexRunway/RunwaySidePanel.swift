import AppKit
import CodexRunwayCore
import Foundation
import SwiftUI

enum RunwaySidePanel: Equatable {
    case accounts
    case resetCredits
    case apiCost
}

/// Raised interactive row: optional leading icon, title, optional trailing chevron.
/// Shared chassis for details-disclosure and inline actions (e.g. repair index).
struct SidePanelDisclosureRow: View {
    var title: String
    var systemImage: String? = nil
    var showsChevron: Bool = true
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? RunwaySurface.hairline : Color.clear,
                        lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }

    private var rowBackground: some ShapeStyle {
        if isHovered {
            return AnyShapeStyle(RunwaySurface.hoverNeutral)
        }
        return AnyShapeStyle(RunwaySurface.raised)
    }
}

struct DetailPageView: View {
    var page: RunwaySidePanel
    @ObservedObject var model: RunwayModel
    var l10n: L10n
    var apiCostInitialRange: ApiCostSummaryRange = .today
    var onAddAccount: () -> Void = {}

    var body: some View {
        switch page {
        case .accounts:
            if model.selectedProvider == .grok {
                GrokAccountsDetailView(model: model, l10n: l10n)
            } else {
                AccountsDetailView(model: model, l10n: l10n, onAddAccount: onAddAccount)
            }
        case .resetCredits:
            PolishedScrollView(verticalPadding: 4) {
                ResetCreditsDetailView(
                    summary: model.resetCreditSummary,
                    details: model.resetCreditDetails,
                    l10n: l10n)
            }
        case .apiCost:
            ApiCostDetailView(model: model, l10n: l10n, initialRange: apiCostInitialRange)
        }
    }
}

private struct ResetCreditsDetailView: View {
    var summary: ResetCreditSummary?
    var details: [ResetCreditDetail]
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary {
                RunwayPageSummaryRow(
                    title: l10n.text(.resetCredits),
                    meta: "\(l10n.text(.lastUpdated)) \(ResetCreditDateFormatter.updatedAt(summary.updatedAt, language: l10n.language))",
                    figure: "\(summary.availableCount)/\(summary.totalCount)")
                statGrid(summary)
                ResetRiskCompositionView(summary: summary, l10n: l10n)
                creditTable
            } else {
                Text(l10n.text(.notLoaded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statGrid(_ summary: ResetCreditSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            RunwayStatCard(title: l10n.text(.available), value: "\(summary.availableCount)", color: Color(nsColor: .systemGreen))
            RunwayStatCard(title: l10n.text(.expiringSoon), value: "\(summary.expiringCount)", color: Color(nsColor: .systemYellow))
            RunwayStatCard(title: l10n.text(.totalRemaining), value: duration(summary.totalRemainingDuration), color: Color(nsColor: .systemBlue))
            RunwayStatCard(title: l10n.text(.nextExpiry), value: summary.nextExpiryRemaining.map(duration) ?? "--", color: Color(nsColor: .systemOrange))
        }
    }

    @ViewBuilder
    private var creditTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.resetCreditDetails))
                .font(.headline)
            if details.isEmpty {
                Text(l10n.text(.noAvailableResetCredits))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RunwayTableContainer {
                    ResetCreditTableHeader(l10n: l10n)
                } rows: {
                    ForEach(Array(details.enumerated()), id: \.element.id) { index, credit in
                        ResetCreditTableRow(credit: credit, l10n: l10n, isFirst: index == 0)
                    }
                }
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        DurationFormatter.localized(seconds, language: l10n.language, includeSeconds: false)
    }
}

private struct ResetRiskCompositionView: View {
    var summary: ResetCreditSummary
    var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.expiryRisk))
                .font(.headline)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    segment(count: summary.stableAvailableCount, total: summary.totalCount, color: Color(nsColor: .systemGreen), width: proxy.size.width)
                    segment(count: summary.expiringCount, total: summary.totalCount, color: Color(nsColor: .systemYellow), width: proxy.size.width)
                    segment(count: summary.unavailableCount, total: summary.totalCount, color: Color(nsColor: .systemRed), width: proxy.size.width)
                }
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                legend(l10n.text(.available), summary.stableAvailableCount, Color(nsColor: .systemGreen))
                legend(l10n.text(.expiringSoon), summary.expiringCount, Color(nsColor: .systemYellow))
                legend(l10n.text(.unavailableCredits), summary.unavailableCount, Color(nsColor: .systemRed))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func segment(count: Int, total: Int, color: Color, width: CGFloat) -> some View {
        if count > 0, total > 0 {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: max(8, width * CGFloat(count) / CGFloat(total)))
        }
    }

    private func legend(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(title) \(count)")
                .monospacedDigit()
        }
    }
}

private struct ResetCreditTableHeader: View {
    var l10n: L10n

    var body: some View {
        HStack {
            Text(l10n.text(.credit)).frame(width: 62, alignment: .leading)
            Text(l10n.text(.status)).frame(maxWidth: .infinity, alignment: .leading)
            Text(l10n.text(.expiresAt)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(l10n.text(.left)).frame(width: 72, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct ResetCreditTableRow: View {
    var credit: ResetCreditDetail
    var l10n: L10n
    var isFirst: Bool

    var body: some View {
        HStack {
            Text(credit.title)
                .frame(width: 62, alignment: .leading)
            StatusPill(text: statusText, state: credit.state)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(expiryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(remainingText)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .tableRowRule(isFirst: isFirst)
    }

    private var statusText: String {
        credit.state == .expiring ? l10n.text(.expiringSoon) : credit.statusText
    }

    private var expiryText: String {
        credit.expiresAt.map { ResetCreditDateFormatter.expiresAt($0, language: l10n.language) } ?? l10n.text(.noExpiry)
    }

    private var remainingText: String {
        credit.expiresAt == nil ? "--" : DurationFormatter.localized(credit.remainingDuration, language: l10n.language, includeSeconds: false)
    }
}

private struct StatusPill: View {
    var text: String
    var state: ResetCreditState

    var body: some View {
        RunwayTag(text, tone: tone, font: .caption2.weight(.semibold))
    }

    private var tone: RunwayTagTone {
        switch state {
        case .available:
            return .green
        case .expiring:
            // Warning orange stays readable in light mode; pure yellow text does not.
            return .orange
        case .unavailable:
            return .red
        }
    }
}
