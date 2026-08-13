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
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: title,
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if meters.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(meters) { meter in
                        quotaRow(meter)
                    }
                }
            }
        }
    }

    private func quotaRow(_ meter: QuotaMeter) -> some View {
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
            HStack(alignment: .firstTextBaseline) {
                if let projection = meter.projection {
                    Text(projectionText(projection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let resetsAt = meter.resetsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(resetText(until: resetsAt, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
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
    static let barHeight: CGFloat = 5

    var meter: QuotaMeter
    @Environment(\.runwayPanelVisible) private var panelVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = max(4, proxy.size.width * CGFloat(meter.remainingPercent) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(RunwaySurface.sunken)
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
            // Shared sheen rhythm: during the rest phase t parks at 1, the band sits
            // fully outside the clip, and identical frames skip the repaint.
            let t = RunwaySheen.progress(at: context.date)
            // Travel fully across the fill, including overshoot so the band exits cleanly.
            let travel = fillWidth + bandWidth
            let x = t * travel - bandWidth
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
        Self.color(for: meter.health)
    }

    static func color(for health: QuotaHealth) -> Color {
        switch health {
        case .green:
            return Color(nsColor: .systemGreen)
        case .yellow:
            return Color(nsColor: .systemYellow)
        case .red:
            return Color(nsColor: .systemRed)
        }
    }

    /// Text-safe variant of the bar palette: the bar fills stay system colors, but
    /// labels need deeper ink in light mode (systemYellow on white is ~1.5:1).
    static func textColor(for health: QuotaHealth) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor
            switch health {
            case .green:
                base = .systemGreen
            case .yellow:
                base = dark ? .systemYellow : .systemOrange
            case .red:
                base = .systemRed
            }
            if dark { return base }
            return base.blended(withFraction: 0.35, of: .black) ?? base
        })
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
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if sessions.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        row(session, isFirst: index == 0)
                    }
                }
                .runwayCard(.sunken)
            }
        }
    }

    private func row(_ session: SessionActivityItem, isFirst: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(session.projectName) · \(stateText(session.state)) · \(tokenText(session.totals.totalTokens)) \(l10n.text(.tokens))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(session.estimatedUSD.map(DurationFormatter.money) ?? "--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(RunwaySurface.hairlineFaint)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
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

/// Reset status card: flat raised surface, hairline-ruled zones, one 28pt hero answer.
struct RateLimitResetTodayView: View {
    static let countdownRefreshInterval: TimeInterval = 1

    var snapshot: RateLimitResetTodaySnapshot?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onOpenSource: () -> Void
    var onOpenEvidence: ((URL) -> Void)?

    @State private var showsSourceInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                RefreshableSectionHeader(
                    title: l10n.text(.rateLimitResetToday),
                    l10n: l10n,
                    isRefreshing: isRefreshing,
                    onRefresh: onRefresh,
                    trailingCaption: lastFetchedCaption(now: context.date),
                    onInfo: { showsSourceInfo = true },
                    infoHelp: l10n.text(.rateLimitResetTodaySourceTitle))
            }

            // The expected reset window is a live, second-level countdown.
            TimelineView(.periodic(from: .now, by: Self.countdownRefreshInterval)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    hero(now: context.date)
                    nextScheduledSection(now: context.date)
                    scopeSummarySection(now: context.date)
                    if hasEvidenceRow {
                        dividedSection {
                            evidenceRowContent
                        }
                    }
                    if let footerText = footerMetaText {
                        dividedSection {
                            Text(footerText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .runwayCard(.raised)
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

    /// Hairline only — spacing is owned by `dividedSection`.
    private var zoneRule: some View {
        Rectangle()
            .fill(RunwaySurface.hairlineFaint)
            .frame(height: 1)
    }

    /// 8pt above the rule, 8pt between rule and content (same for every block).
    private func dividedSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            zoneRule
            content()
        }
        .padding(.top, 8)
    }

    /// Large answer on the left, detail on the right — time/countdown stay caption-sized.
    private func hero(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(heroTitle(now: now))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(heroColor(now: now))
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .layoutPriority(1)

            heroSubtitleView(now: now)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heroSubtitleView(now: Date) -> some View {
        // First row: keep absolute time only (no relative countdown) so it stays single-line aligned.
        if let detail = heroYesTimeDetail(now: now) {
            let prefix = heroYesPrefix(now: now)
            (
                Text("\(prefix) · ")
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                + Text(detail.text)
                    .foregroundColor(detail.color)
            )
            .font(.caption2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        } else {
            Text(heroSubtitle(now: now))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    /// "Already reset" vs "scheduled later today" prefix for the yes hero line.
    private func heroYesPrefix(now: Date) -> String {
        guard let snapshot else { return l10n.text(.rateLimitResetTodayYesHint) }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        if snapshot.prefersSameDayScheduleExplanation(now: now, calendar: calendar) {
            return l10n.text(.rateLimitResetTodayYesHintScheduled)
        }
        return l10n.text(.rateLimitResetTodayYesHint)
    }

    private func heroYesTimeDetail(now: Date) -> (text: String, color: Color)? {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        guard let snapshot, snapshot.resolvedState(now: now, calendar: calendar) == .yes else {
            return nil
        }
        if snapshot.prefersSameDayScheduleExplanation(now: now, calendar: calendar),
           let next = snapshot.nextScheduledReset(onLocalDayOf: now, calendar: calendar)
        {
            let when = ResetLabelFormatter.scheduledLabel(
                for: RateLimitResetScheduleWindow(
                    startAt: next.effectiveAt,
                    endAt: next.effectiveUntil,
                    isRange: next.isRange),
                language: l10n.language,
                calendar: calendar)
            return (when, Color(nsColor: .systemGreen))
        }
        guard let resetAt = snapshot.latestResetAt(now: now) else { return nil }
        let when = ResetLabelFormatter.shortLabel(
            for: resetAt,
            now: now,
            language: l10n.language,
            calendar: calendar)
        // Past reset → muted gray; (defensive) future same-day effective → green.
        let color: Color = resetAt <= now
            ? Color(nsColor: .secondaryLabelColor)
            : Color(nsColor: .systemGreen)
        return (when, color)
    }

    @ViewBuilder
    private func scopeSummarySection(now: Date) -> some View {
        if let scope = scopeSummaryText(now: now) {
            dividedSection {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(scope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func nextScheduledSection(now: Date) -> some View {
        if let next = snapshot?.nextScheduledReset(now: now) {
            let calendar = RateLimitResetTodaySnapshot.localDayCalendar
            let window = RateLimitResetScheduleWindow(
                startAt: next.effectiveAt,
                endAt: next.effectiveUntil,
                isRange: next.isRange)
            let absolute = ResetLabelFormatter.scheduledLabel(
                for: window,
                language: l10n.language,
                calendar: calendar)
            let remaining = ResetLabelFormatter.scheduledCountdown(
                for: window,
                now: now,
                language: l10n.language)
            let countdown = String(format: l10n.text(.rateLimitResetTodayUntilReset), remaining)
            let separator = l10n.language == .simplifiedChinese ? "：" : ": "
            let openParen = l10n.language == .simplifiedChinese ? "（" : " ("
            let closeParen = l10n.language == .simplifiedChinese ? "）" : ")"
            dividedSection {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    (
                        Text("\(l10n.text(.rateLimitResetTodayNextScheduled))\(separator)")
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        + Text(absolute)
                            .foregroundColor(Color(nsColor: .systemBlue))
                            .fontWeight(.bold)
                        + Text("\(openParen)\(countdown)\(closeParen)")
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    )
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var evidenceRowContent: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(evidenceLineText)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if snapshot?.evidenceURL(
                calendar: RateLimitResetTodaySnapshot.localDayCalendar) != nil
            {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if let url = snapshot?.evidenceURL(
            calendar: RateLimitResetTodaySnapshot.localDayCalendar),
           let onOpenEvidence
        {
            EvidenceRowButton(
                action: { onOpenEvidence(url) },
                help: l10n.text(.rateLimitResetTodayOpenEvidence))
            {
                row
            }
        } else {
            row
        }
    }

    private func scopeSummaryText(now: Date) -> String? {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        guard let snapshot,
              let event = snapshot.primaryEvidenceEvent(now: now, calendar: calendar)
        else { return nil }
        return snapshot.scopeSummary(for: event, l10n: l10n)
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
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        var parts: [String] = []
        if let checkedAt = snapshot.lastSuccessfulCheckAt {
            parts.append(
                "\(l10n.text(.rateLimitResetTodayLastCheck)) \(DurationFormatter.relativePast(since: checkedAt, language: l10n.language))")
        }
        if let resetAt = snapshot.latestResetAt() {
            parts.append(
                "\(l10n.text(.lastReset)) \(DurationFormatter.relativePast(since: resetAt, language: l10n.language))")
        } else if snapshot.resolvedState(calendar: calendar) == .no,
                  snapshot.nextScheduledReset() == nil
        {
            parts.append(l10n.text(.rateLimitResetTodayAwaiting))
        }
        if let confidence = snapshot.primaryEvidenceEvent(calendar: calendar)?.confidence {
            parts.append(
                "\(l10n.text(.rateLimitResetTodayConfidence)) \(Int((confidence * 100).rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hasEvidenceRow: Bool {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        return snapshot?.evidenceURL(calendar: calendar) != nil
            || snapshot?.evidenceLine(l10n: l10n, calendar: calendar) != nil
    }

    private var evidenceLineText: String {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        if let line = snapshot?.evidenceLine(l10n: l10n, calendar: calendar), !line.isEmpty {
            return line
        }
        return l10n.text(.rateLimitResetTodayLatestEvidence)
    }

    private func heroTitle(now: Date) -> String {
        guard let snapshot else {
            return isRefreshing ? "…" : "—"
        }
        switch snapshot.resolvedState(
            now: now,
            calendar: RateLimitResetTodaySnapshot.localDayCalendar)
        {
        case .yes:
            return l10n.text(.rateLimitResetTodayYes)
        case .no:
            return l10n.text(.rateLimitResetTodayNo)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknown)
        }
    }

    private func heroSubtitle(now: Date) -> String {
        if snapshot == nil {
            return l10n.text(isRefreshing ? .calculating : .notLoaded)
        }
        guard let snapshot else {
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        switch snapshot.resolvedState(now: now, calendar: calendar) {
        case .yes:
            // Time detail is rendered separately in small type via heroYesTimeDetail.
            // When only a same-day schedule remains (no past reset yet), use scheduled copy.
            if snapshot.prefersSameDayScheduleExplanation(now: now, calendar: calendar),
               snapshot.latestResetAt(now: now) == nil
            {
                return l10n.text(.rateLimitResetTodayYesHintScheduled)
            }
            return l10n.text(.rateLimitResetTodayYesHint)
        case .no:
            if let next = snapshot.nextScheduledReset(now: now) {
                let window = RateLimitResetScheduleWindow(
                    startAt: next.effectiveAt,
                    endAt: next.effectiveUntil,
                    isRange: next.isRange)
                let when = ResetLabelFormatter.scheduledLabel(
                    for: window,
                    language: l10n.language,
                    calendar: calendar)
                let remaining = ResetLabelFormatter.scheduledCountdown(
                    for: window,
                    now: now,
                    language: l10n.language)
                let countdown = String(format: l10n.text(.rateLimitResetTodayUntilReset), remaining)
                let openParen = l10n.language == .simplifiedChinese ? "（" : " ("
                let closeParen = l10n.language == .simplifiedChinese ? "）" : ")"
                return "\(String(format: l10n.text(.rateLimitResetTodayNoHintWithNext), when))\(openParen)\(countdown)\(closeParen)"
            }
            if snapshot.hasUncertainNoSignalToday(now: now, calendar: calendar) {
                return l10n.text(.rateLimitResetTodayNoHintUncertain)
            }
            return l10n.text(.rateLimitResetTodayNoHint)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
    }

    private func heroColor(now: Date) -> Color {
        guard let snapshot else { return Color(nsColor: .secondaryLabelColor) }
        switch snapshot.resolvedState(
            now: now,
            calendar: RateLimitResetTodaySnapshot.localDayCalendar)
        {
        case .yes:
            return Color(nsColor: .systemGreen)
        case .no:
            return Color(nsColor: .systemOrange)
        case .unknown:
            return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// Hoverable wrapper for the evidence line (quiet pill highlight, no chrome at rest).
private struct EvidenceRowButton<Content: View>: View {
    var action: () -> Void
    var help: String
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                    in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(help)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
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
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh)
            if let summary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(summary.availableCount)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("\(l10n.text(.available)) / \(summary.totalCount) \(l10n.text(.total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(l10n.text(.totalRemaining)): \(duration(summary.totalRemainingDuration))")
                    Spacer(minLength: 8)
                    if let remaining = summary.nextExpiryRemaining {
                        Text("\(l10n.text(.left)) \(duration(remaining))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                SidePanelDisclosureRow(
                    title: "\(summary.availableCount) \(l10n.text(.availableResets))",
                    action: onDetailsSelect)
            } else {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.apiCost),
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            SidePanelDisclosureRow(title: l10n.text(.showDetails), action: onDetailsSelect)
        }
    }
}

/// Typographic section header: title, optional trailing caption, info + refresh
/// controls with monochrome hover.
struct RefreshableSectionHeader: View {
    var title: String
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
            Text(title)
                .font(.headline)
            Spacer(minLength: 0)
            if let trailingCaption, !trailingCaption.isEmpty {
                Text(trailingCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                .pointingHandCursor()
                .onHover { isInfoHovered = $0 }
            }
            Button(action: onRefresh) {
                Group {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.callout.weight(.medium))
                    }
                }
                .foregroundStyle(isRefreshHovered && !isRefreshing ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(
                    isRefreshHovered && !isRefreshing ? RunwaySurface.hoverNeutral : Color.clear,
                    in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(l10n.text(.refresh))
            .accessibilityLabel(l10n.text(.refresh))
            .pointingHandCursor(enabled: !isRefreshing)
            .onHover { isRefreshHovered = $0 }
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
                .font(.callout.weight(.medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(
                    isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                    in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
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

            Text(l10n.text(.rateLimitResetTodayLocalDayHint))
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
