import AppKit
import CodexRunwayCore
import SwiftUI

struct QuotaMetersView: View {
    var title: String
    var meters: [QuotaMeter]
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RefreshableSectionHeader(
                title: title,
                systemImage: "speedometer",
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if meters.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded)).foregroundStyle(.secondary)
            } else {
                ForEach(meters) { meter in
                    quotaRow(meter)
                }
            }
        }
    }

    private func quotaRow(_ meter: QuotaMeter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meter.title).font(.headline)
            RunwayProgressBar(meter: meter)
                .frame(height: RunwayProgressBar.barHeight)
            HStack(alignment: .firstTextBaseline) {
                Text("\(meter.remainingPercent)% \(l10n.text(.left))")
                Spacer()
                if let resetsAt = meter.resetsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(resetText(until: resetsAt, now: context.date))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            if let projection = meter.projection {
                Text(projectionText(projection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func projectionText(_ projection: QuotaBurnProjection) -> String {
        if let exhaustsAt = projection.exhaustsAt {
            return "\(l10n.text(.burnRate)): \(l10n.text(.exhaustsIn)) \(duration(exhaustsAt.timeIntervalSince(Date())))"
        }
        return "\(l10n.text(.burnRate)): \(l10n.text(.projectedAtReset)) \(projection.projectedUsedPercentAtReset)%"
    }

    private func resetText(until date: Date, now: Date) -> String {
        "\(l10n.text(.nextResetIn))\(duration(date.timeIntervalSince(now)))"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        DurationFormatter.localized(seconds, language: l10n.language)
    }
}

struct RunwayProgressBar: View {
    static let barHeight: CGFloat = 6

    var meter: QuotaMeter
    @Environment(\.runwayPanelVisible) private var panelVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = max(4, proxy.size.width * CGFloat(meter.remainingPercent) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(RunwaySurface.subtleFill)
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth)
                    .overlay(alignment: .leading) {
                        if !reduceMotion {
                            flowingHighlight(fillWidth: fillWidth, height: proxy.size.height)
                        }
                    }
                    .clipShape(Capsule())
                ForEach(meter.markerPercents, id: \.self) { marker in
                    let x = min(max(1, proxy.size.width * CGFloat(marker) / 100), proxy.size.width - 1)
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.28))
                        .frame(width: 1, height: max(3, proxy.size.height - 2))
                        .offset(x: x)
                }
            }
        }
        .accessibilityLabel("\(meter.title) \(meter.remainingPercent)%")
    }

    /// Soft highlight that drifts across the filled segment.
    private func flowingHighlight(fillWidth: CGFloat, height: CGFloat) -> some View {
        let bandWidth = max(18, fillWidth * 0.38)
        // Pause when the status panel is hidden. Normal compositing only: `.plusLighter`
        // forces an offscreen pass per frame per bar, which starves the main thread.
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !panelVisible)) { context in
            let cycle = 1.85
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            // Travel fully across the fill, including overshoot so the band exits cleanly.
            let travel = fillWidth + bandWidth
            let x = CGFloat(t) * travel - bandWidth
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.55),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing)
                .frame(width: bandWidth, height: height)
                .offset(x: x)
        }
        .allowsHitTesting(false)
    }

    var color: Color {
        switch meter.health {
        case .green:
            return Color(nsColor: .systemGreen)
        case .yellow:
            return Color(nsColor: .systemYellow)
        case .red:
            return Color(nsColor: .systemRed)
        }
    }
}

struct RecentSessionsView: View {
    var sessions: [SessionActivityItem]
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.recentSessions),
                systemImage: "terminal",
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if sessions.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions.prefix(5)) { session in
                        row(session)
                    }
                }
                .background(RunwaySurface.subtleFill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
            }
        }
    }

    private func row(_ session: SessionActivityItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(session.projectName) · \(stateText(session.state)) · \(tokenText(session.totals.totalTokens)) \(l10n.text(.tokens))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.estimatedUSD.map(DurationFormatter.money) ?? "--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator.opacity(0.25)).frame(height: 1)
        }
    }

    private func stateText(_ state: SessionActivityState) -> String {
        switch state {
        case .recent:
            return l10n.text(.recent)
        case .needsAttention:
            return l10n.text(.needsAttention)
        case .failed:
            return l10n.text(.failed)
        }
    }

    private func color(for state: SessionActivityState) -> Color {
        switch state {
        case .recent:
            return Color(nsColor: .systemGreen)
        case .needsAttention:
            return Color(nsColor: .systemOrange)
        case .failed:
            return Color(nsColor: .systemRed)
        }
    }

    private func tokenText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// Compact reset status: large Yes/No, tight rows for tweet + timestamps.
struct RateLimitResetTodayView: View {
    var snapshot: RateLimitResetTodaySnapshot?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onOpenSource: () -> Void
    var onOpenTweet: ((URL) -> Void)?

    @State private var showsSourceInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                RefreshableSectionHeader(
                    title: l10n.text(.rateLimitResetToday),
                    systemImage: "sparkles",
                    l10n: l10n,
                    isRefreshing: isRefreshing,
                    onRefresh: onRefresh,
                    trailingCaption: lastFetchedCaption(now: context.date),
                    onInfo: { showsSourceInfo = true },
                    infoHelp: l10n.text(.rateLimitResetTodaySourceTitle))
            }

            VStack(spacing: 8) {
                hero
                if hasNextResetCountdown {
                    nextResetCountdownRow
                }
                if hasTweetRow {
                    tweetRow
                }
                if let footerText = footerMetaText {
                    Text(footerText)
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                heroBackground
                    .clipShape(RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
            }
            .overlay {
                RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius)
                    .strokeBorder(heroColor.opacity(0.16), lineWidth: 1)
            }
        }
        .sheet(isPresented: $showsSourceInfo) {
            RateLimitResetTodaySourceSheet(
                l10n: l10n,
                onOpenSource: {
                    showsSourceInfo = false
                    onOpenSource()
                },
                onDismiss: { showsSourceInfo = false })
        }
    }

    /// Large answer on the left, hint on the right — one row instead of a tall centered stack.
    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(heroTitle)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(heroColor)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .layoutPriority(1)

            Text(heroSubtitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasNextResetCountdown: Bool {
        snapshot?.nextResetRemaining() != nil
    }

    private var nextResetCountdownRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = snapshot?.nextResetRemaining(now: context.date)
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(heroColor)

                Text(l10n.text(.nextResetIn))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                Spacer(minLength: 4)

                Text(remaining.map { DurationFormatter.localized($0, language: l10n.language) } ?? "—")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(heroColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(heroColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var tweetRow: some View {
        Group {
            if let url = snapshot?.tweetURL, let onOpenTweet {
                Button {
                    onOpenTweet(url)
                } label: {
                    tweetRowContent
                }
                .buttonStyle(.plain)
                .help(l10n.text(.rateLimitResetTodayOpenTweet))
            } else {
                tweetRowContent
            }
        }
    }

    private var tweetRowContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(heroColor.opacity(0.9))

            Text(tweetLineText)
                .font(.caption)
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if snapshot?.tweetURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RunwaySurface.fill.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func lastFetchedCaption(now: Date) -> String? {
        guard let snapshot else { return nil }
        let relative = DurationFormatter.relativePast(
            since: snapshot.fetchedAt,
            now: now,
            language: l10n.language)
        return "\(l10n.text(.rateLimitResetTodayLastFetched)) \(relative)"
    }

    /// Site-side meta only (last local refresh lives in the section header).
    private var footerMetaText: String? {
        guard let snapshot else {
            return l10n.text(isRefreshing ? .calculating : .notLoaded)
        }
        var parts: [String] = []
        if let checkedAt = snapshot.latestCheckedAt ?? snapshot.updatedAt {
            parts.append(
                "\(l10n.text(.rateLimitResetTodayLastCheck)) \(DurationFormatter.relativePast(since: checkedAt, language: l10n.language))")
        }
        if let resetAt = snapshot.resetAt {
            parts.append(
                "\(l10n.text(.lastReset)) \(DurationFormatter.relativePast(since: resetAt, language: l10n.language))")
        } else if snapshot.state == .no {
            parts.append(l10n.text(.rateLimitResetTodayAwaiting))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hasTweetRow: Bool {
        snapshot?.tweetURL != nil || snapshot?.displayTweetLine != nil
    }

    private var tweetLineText: String {
        if let line = snapshot?.displayTweetLine, !line.isEmpty {
            return line
        }
        return l10n.text(.rateLimitResetTodayLatestTweet)
    }

    private var heroTitle: String {
        guard let snapshot else {
            return isRefreshing ? "…" : "—"
        }
        switch snapshot.state {
        case .yes:
            return l10n.text(.rateLimitResetTodayYes)
        case .no:
            return l10n.text(.rateLimitResetTodayNo)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknown)
        }
    }

    private var heroSubtitle: String {
        if snapshot == nil {
            return l10n.text(isRefreshing ? .calculating : .notLoaded)
        }
        switch snapshot?.state {
        case .yes:
            return l10n.text(.rateLimitResetTodayYesHint)
        case .no:
            return l10n.text(.rateLimitResetTodayNoHint)
        case .unknown, .none:
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
    }

    private var heroColor: Color {
        guard let snapshot else { return Color(nsColor: .secondaryLabelColor) }
        switch snapshot.state {
        case .yes:
            return Color(nsColor: .systemGreen)
        case .no:
            return Color(nsColor: .systemOrange)
        case .unknown:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var heroBackground: some View {
        LinearGradient(
            colors: [
                heroColor.opacity(0.12),
                Color(nsColor: .systemBlue).opacity(0.05),
                RunwaySurface.subtleFill,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

struct ResetCreditsSummaryView: View {
    var summary: ResetCreditSummary?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onDetailsSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.resetCredits),
                systemImage: "clock.arrow.circlepath",
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if let summary {
                Text("\(summary.availableCount) \(l10n.text(.available)) / \(summary.totalCount) \(l10n.text(.total))")
                    .font(.title3)
                HStack {
                    Text("\(l10n.text(.totalRemaining)): \(duration(summary.totalRemainingDuration))")
                    Spacer()
                    if let remaining = summary.nextExpiryRemaining {
                        Text("\(l10n.text(.left)) \(duration(remaining))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                SidePanelDisclosureRow(
                    title: "\(summary.availableCount) \(l10n.text(.availableResets))",
                    action: onDetailsSelect)
            } else {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded)).foregroundStyle(.secondary)
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        DurationFormatter.localized(seconds, language: l10n.language)
    }
}

struct CostSummaryView: View {
    var text: String
    var subtitle: String
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onDetailsSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RefreshableSectionHeader(
                title: l10n.text(.apiCost),
                systemImage: "dollarsign.circle",
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            VStack(alignment: .leading, spacing: 3) {
                Text(isRefreshing && subtitle.isEmpty ? l10n.text(.calculating) : text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            SidePanelDisclosureRow(title: l10n.text(.showDetails), action: onDetailsSelect)
        }
    }
}

struct RefreshableSectionHeader: View {
    var title: String
    var systemImage: String
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    /// Small caption shown before the info / refresh controls (e.g. last refreshed).
    var trailingCaption: String? = nil
    var onInfo: (() -> Void)? = nil
    var infoHelp: String? = nil

    @State private var isRefreshHovered = false
    @State private var isInfoHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer(minLength: 0)
            if let trailingCaption, !trailingCaption.isEmpty {
                Text(trailingCaption)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if let onInfo {
                headerIconButton(
                    systemImage: "exclamationmark.circle",
                    isHovered: isInfoHovered,
                    help: infoHelp ?? l10n.text(.rateLimitResetTodaySourceTitle),
                    action: onInfo)
                .onHover { hovering in
                    isInfoHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            Button(action: onRefresh) {
                Group {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .foregroundStyle(isRefreshHovered && !isRefreshing ? Color.accentColor : Color.primary)
                .frame(width: 24, height: 24)
                .background(
                    isRefreshHovered && !isRefreshing ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(l10n.text(.refresh))
            .accessibilityLabel(l10n.text(.refresh))
            .onHover { hovering in
                isRefreshHovered = hovering
                if hovering, !isRefreshing {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    private func headerIconButton(
        systemImage: String,
        isHovered: Bool,
        help: String,
        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(
                    isHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RateLimitResetTodaySourceSheet: View {
    var l10n: L10n
    var onOpenSource: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.rateLimitResetTodaySourceTitle))
                .font(.title3.weight(.semibold))

            Text(l10n.text(.rateLimitResetTodaySourceInfo))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenSource) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text(l10n.text(.rateLimitResetTodaySource))
                        .underline()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(Color(nsColor: .linkColor))
            }
            .buttonStyle(.plain)
            .help(l10n.text(.rateLimitResetTodayOpenSource))

            HStack {
                Spacer()
                Button(l10n.text(.ok), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
