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
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(meter.remainingPercent)% \(l10n.text(.left))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(RunwayProgressBar.textColor(for: meter.health))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
            RunwayProgressBar(meter: meter)
                .frame(height: RunwayProgressBar.barHeight)
            HStack(alignment: .firstTextBaseline) {
                if let projection = meter.projection {
                    Text(projectionText(projection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    var reaction: RateLimitResetTodayReactionSnapshot? = nil
    var isReactionBusy: Bool = false
    var isReactionLoading: Bool = false
    var isReactionFresh: Bool = true
    var reactionDelta: RateLimitResetTodayReactionDelta = .none
    var onReactionClick: () -> Void = {}
    var onReactionPollingEnabledChange: (Bool) -> Void = { _ in }

    @Environment(\.runwayPanelVisible) private var panelVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                RefreshableSectionHeader(
                    title: l10n.text(.rateLimitResetToday),
                    l10n: l10n,
                    isRefreshing: isRefreshing,
                    onRefresh: onRefresh,
                    trailingCaption: lastFetchedCaption(now: context.date),
                    infoHelp: l10n.text(.rateLimitResetTodaySourceTitle),
                    infoAccessibilityIdentifier: "rate-limit-reset-today-info",
                    infoContent: {
                        AnyView(RateLimitResetTodaySourcePopover(
                            l10n: l10n,
                            onOpenSource: onOpenSource))
                    })
            }

            // The expected reset window is a live, second-level countdown.
            TimelineView(.periodic(from: .now, by: Self.countdownRefreshInterval)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    hero(now: context.date)
                    nextScheduledSection(now: context.date)
                    scopeSummarySection(now: context.date)
                    if hasEvidenceRow(now: context.date) {
                        dividedSection {
                            evidenceRowContent(now: context.date)
                        }
                    }
                    if let footerText = footerMetaText(now: context.date) {
                        dividedSection {
                            Text(footerText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    dividedSection {
                        websiteLink
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .runwayCard(.raised)
        }
        .onAppear { onReactionPollingEnabledChange(panelVisible) }
        .onChange(of: panelVisible) { onReactionPollingEnabledChange($0) }
        .onDisappear { onReactionPollingEnabledChange(false) }
    }

    private var isReactionAwaitingCount: Bool {
        isReactionLoading || (panelVisible && !isReactionFresh)
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

    /// Verdict + reaction on the first row; hint copy wraps on the line below.
    private func hero(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                heroTitleView(now: now)
                    .layoutPriority(1)

                if let reaction, reaction.isVisible {
                    RateLimitResetTodayReactionButton(
                        snapshot: reaction,
                        l10n: l10n,
                        isBusy: isReactionBusy,
                        isLoading: isReactionAwaitingCount,
                        delta: reactionDelta,
                        onClick: onReactionClick)
                        .fixedSize()
                } else if isReactionAwaitingCount {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RunwaySurface.raised, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(RunwaySurface.hairline, lineWidth: 1))
                }

                Spacer(minLength: 0)
            }

            heroSubtitleView(now: now)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heroSubtitleView(now: Date) -> some View {
        if let detail = snapshot?.verdictDetail(l10n: l10n, now: now) {
            verdictDetailText(detail, now: now)
                .fixedSize(horizontal: false, vertical: true)
        } else if let unconfirmed = heroUnconfirmedScheduleDetail(now: now) {
            unconfirmedScheduleHintText(type: unconfirmed)
                .fixedSize(horizontal: false, vertical: true)
        } else if let last = heroNoneLastDetail(now: now) {
            noneLastHintText(type: last.resetType, ago: last.ago)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(heroSubtitle(now: now))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var websiteLink: some View {
        RateLimitResetTodayWebsiteLink(
            title: l10n.text(.rateLimitResetTodayOpenWebsite),
            help: l10n.text(.rateLimitResetTodayOpenSource),
            action: onOpenSource)
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
            let separator = l10n.language.colonSeparator
            let openParen = l10n.language.openParen
            let closeParen = l10n.language.closeParen
            dividedSection {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    (
                        Text("\(l10n.text(.rateLimitResetTodayNextScheduled))\(separator)")
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        + Text("\(next.event.resetType.localizedName(l10n: l10n)) · ")
                            .foregroundColor(resetTypeColor(next.event.resetType))
                            .fontWeight(.semibold)
                        + Text(absolute)
                            .foregroundColor(scheduleTimeColor(for: next.event))
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
    private func evidenceRowContent(now: Date) -> some View {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        let row = HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(evidenceLineText(now: now))
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if snapshot?.evidenceURL(
                now: now,
                calendar: calendar,
                language: l10n.language) != nil
            {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if let url = snapshot?.evidenceURL(
            now: now,
            calendar: calendar,
            language: l10n.language),
           let onOpenEvidence
        {
            EvidenceRowButton(
                action: { onOpenEvidence(url) },
                help: l10n.text(.showDetails))
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
    private func footerMetaText(now: Date) -> String? {
        guard let snapshot else {
            return l10n.text(isRefreshing ? .calculating : .notLoaded)
        }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        var parts: [String] = []
        if let checkedAt = snapshot.lastSuccessfulCheckAt {
            parts.append(
                "\(l10n.text(.rateLimitResetTodayLastCheck)) \(DurationFormatter.relativePast(since: checkedAt, now: now, language: l10n.language))")
        }
        if let latest = snapshot.latestReset(now: now) {
            let relative = DurationFormatter.relativePast(
                since: latest.at,
                now: now,
                language: l10n.language)
            parts.append(
                "\(l10n.text(.lastReset)) \(latest.resetType.localizedName(l10n: l10n)) · \(relative)")
        } else if snapshot.resolvedState(now: now, calendar: calendar) == .no,
                  snapshot.nextScheduledReset(now: now) == nil
        {
            parts.append(l10n.text(.rateLimitResetTodayAwaiting))
        }
        if let confidence = snapshot.primaryEvidenceEvent(now: now, calendar: calendar)?.confidence {
            parts.append(
                "\(l10n.text(.rateLimitResetTodayConfidence)) \(Int((confidence * 100).rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func hasEvidenceRow(now: Date) -> Bool {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        return snapshot?.evidenceURL(
            now: now,
            calendar: calendar,
            language: l10n.language) != nil
            || snapshot?.evidenceLine(l10n: l10n, now: now, calendar: calendar) != nil
    }

    private func evidenceLineText(now: Date) -> String {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        if let line = snapshot?.evidenceLine(l10n: l10n, now: now, calendar: calendar), !line.isEmpty {
            return line
        }
        return l10n.text(.rateLimitResetTodayLatestEvidence)
    }

    private func heroTitleView(now: Date) -> some View {
        let color = heroColor(now: now)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let snapshot {
                let calendar = RateLimitResetTodaySnapshot.localDayCalendar
                if snapshot.resolvedState(now: now, calendar: calendar) == .unknown {
                    Text(l10n.text(.rateLimitResetTodayUnknown))
                } else {
                    let presentation = snapshot.verdictPresentation(now: now, calendar: calendar)
                    if let percent = presentation.percentText(l10n: l10n) {
                        Text(percent)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                    }
                    Text(presentation.answerText(l10n: l10n))
                }
            } else {
                Text(isRefreshing ? "…" : "—")
            }
        }
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .minimumScaleFactor(0.75)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityTitle(now: now))
    }

    private func heroAccessibilityTitle(now: Date) -> String {
        guard let snapshot else { return isRefreshing ? "…" : "—" }
        if snapshot.resolvedState(now: now) == .unknown {
            return l10n.text(.rateLimitResetTodayUnknown)
        }
        return snapshot.verdictPresentation(now: now).titleText(l10n: l10n)
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
            if snapshot.prefersSameDayScheduleExplanation(now: now, calendar: calendar),
               let next = snapshot.nextScheduledReset(onLocalDayOf: now, calendar: calendar)
            {
                return scheduledHint(for: next.event.resetType)
            }
            return completedHint(for: snapshot.displayResetType(now: now, calendar: calendar) ?? .global)
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
                let openParen = l10n.language.openParen
                let closeParen = l10n.language.closeParen
                return "\(String(format: l10n.text(.rateLimitResetTodayNoHintWithNext), when))\(openParen)\(countdown)\(closeParen)"
            }
            if snapshot.hasUncertainNoSignalToday(now: now, calendar: calendar) {
                return l10n.text(.rateLimitResetTodayNoHintUncertain)
            }
            if let unconfirmed = snapshot.unconfirmedScheduleHint(
                l10n: l10n,
                now: now,
                calendar: calendar)
            {
                return unconfirmed.text
            }
            if let last = snapshot.noneHintLastReset(l10n: l10n, now: now) {
                return last.text
            }
            return l10n.text(.rateLimitResetTodayNoHint)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
    }

    private func heroColor(now: Date) -> Color {
        guard let snapshot else { return Color(nsColor: .secondaryLabelColor) }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        let state = snapshot.resolvedState(now: now, calendar: calendar)
        if state == .unknown {
            return Color(nsColor: .secondaryLabelColor)
        }
        let presentation = snapshot.verdictPresentation(now: now, calendar: calendar)
        if let band = presentation.band {
            return Color(nsColor: confidenceBandNSColor(band))
        }
        if presentation.isCompleted, presentation.resetType == .banked {
            return Color(nsColor: .systemBlue)
        }
        if presentation.showsYes {
            return Color(nsColor: .systemGreen)
        }
        return Color(nsColor: .systemOrange)
    }

    private func confidenceBandNSColor(_ band: RateLimitResetTodayConfidenceBand) -> NSColor {
        switch band {
        case .ok: .systemPurple
        case .warn: .systemYellow
        }
    }

    private func scheduleTimeColor(for event: RateLimitResetTodayEvent) -> Color {
        Color(nsColor: confidenceBandNSColor(snapshot?.scheduleConfidenceBand(for: event) ?? .ok))
    }

    private func verdictDetailText(
        _ detail: RateLimitResetTodayDetailPresentation,
        now: Date) -> some View
    {
        let secondary = Color(nsColor: .secondaryLabelColor)
        let emphasis = detailEmphasisColor(detail, now: now)
        var result = Text("")
        for token in detail.tokens {
            switch token {
            case .text(let value):
                result = result + Text(value).foregroundColor(secondary)
            case .resetType:
                result = result
                    + Text(detail.typeLabel)
                    .foregroundColor(detailTypeColor(detail, now: now))
                    .fontWeight(.semibold)
                    .underline()
            case .percent:
                result = result
                    + Text(detail.percentText ?? "")
                    .foregroundColor(emphasis)
                    .fontWeight(.semibold)
                    .underline()
            case .time:
                result = result
                    + Text(detail.timeText ?? "")
                    .foregroundColor(emphasis)
                    .fontWeight(.semibold)
                    .underline()
            }
        }
        return result
            .font(.caption2)
            .multilineTextAlignment(.leading)
    }

    private func detailTypeColor(
        _ detail: RateLimitResetTodayDetailPresentation,
        now: Date) -> Color
    {
        if let snapshot {
            let presentation = snapshot.verdictPresentation(now: now)
            if let band = presentation.band {
                return Color(nsColor: confidenceBandNSColor(band))
            }
        }
        guard let resetType = detail.resetType else {
            return Color(nsColor: .systemGreen)
        }
        return resetTypeColor(resetType)
    }

    private func detailEmphasisColor(
        _ detail: RateLimitResetTodayDetailPresentation,
        now: Date) -> Color
    {
        if let snapshot {
            let presentation = snapshot.verdictPresentation(now: now)
            if let band = presentation.band {
                return Color(nsColor: confidenceBandNSColor(band))
            }
        }
        return Color(nsColor: .systemGreen)
    }

    private func completedHint(for resetType: RateLimitResetType) -> String {
        switch resetType {
        case .global:
            l10n.text(.rateLimitResetTodayYesHint)
        case .banked:
            l10n.text(.rateLimitResetTodayBankedCompletedHint)
        case .globalAndBanked:
            l10n.text(.rateLimitResetTodayGlobalAndBankedCompletedHint)
        }
    }

    private func scheduledHint(for resetType: RateLimitResetType) -> String {
        switch resetType {
        case .global:
            l10n.text(.rateLimitResetTodayYesHintScheduled)
        case .banked:
            l10n.text(.rateLimitResetTodayBankedScheduledHint)
        case .globalAndBanked:
            l10n.text(.rateLimitResetTodayGlobalAndBankedScheduledHint)
        }
    }

    private func heroNoneLastDetail(now: Date) -> (resetType: RateLimitResetType, ago: String)? {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        guard let snapshot,
              snapshot.resolvedState(now: now, calendar: calendar) == .no,
              snapshot.nextScheduledReset(now: now) == nil,
              !snapshot.hasUncertainNoSignalToday(now: now, calendar: calendar),
              snapshot.unconfirmedExpiredSchedule(now: now, calendar: calendar) == nil,
              let last = snapshot.noneHintLastReset(l10n: l10n, now: now)
        else {
            return nil
        }
        return (last.resetType, last.ago)
    }

    private func heroUnconfirmedScheduleDetail(now: Date) -> RateLimitResetType? {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        guard let snapshot,
              snapshot.resolvedState(now: now, calendar: calendar) == .no,
              snapshot.nextScheduledReset(now: now) == nil,
              !snapshot.hasUncertainNoSignalToday(now: now, calendar: calendar),
              let event = snapshot.unconfirmedExpiredSchedule(now: now, calendar: calendar)
        else {
            return nil
        }
        return event.resetType
    }

    private func unconfirmedScheduleHintText(type: RateLimitResetType) -> some View {
        let template = l10n.text(.rateLimitResetTodayNoHintUnconfirmedSchedule)
        let typeLabel = type.localizedName(l10n: l10n)
        let typeColor = resetTypeColor(type)
        let secondary = Color(nsColor: .secondaryLabelColor)
        var result = Text("")
        for segment in RateLimitResetNoneHint.segments(template) {
            switch segment {
            case .text(let value):
                result = result + Text(value).foregroundColor(secondary)
            case .resetType:
                result = result + Text(typeLabel)
                    .foregroundColor(typeColor)
                    .fontWeight(.semibold)
            case .ago:
                continue
            }
        }
        return result
            .font(.caption2)
            .multilineTextAlignment(.leading)
    }

    private func noneLastHintText(type: RateLimitResetType, ago: String) -> some View {
        let template = l10n.text(.rateLimitResetTodayNoHintWithLast)
        let typeLabel = type.localizedName(l10n: l10n)
        let typeColor = resetTypeColor(type)
        let secondary = Color(nsColor: .secondaryLabelColor)
        var result = Text("")
        for segment in RateLimitResetNoneHint.segments(template) {
            switch segment {
            case .text(let value):
                result = result + Text(value).foregroundColor(secondary)
            case .resetType:
                result = result + Text(typeLabel)
                    .foregroundColor(typeColor)
                    .fontWeight(.semibold)
            case .ago:
                result = result + Text(ago)
                    .foregroundColor(Color(nsColor: .labelColor))
                    .fontWeight(.semibold)
            }
        }
        return result
            .font(.caption2)
            .multilineTextAlignment(.leading)
    }

    private func resetTypeColor(_ resetType: RateLimitResetType) -> Color {
        Color(nsColor: resetTypeNSColor(resetType))
    }

    private func resetTypeNSColor(_ resetType: RateLimitResetType) -> NSColor {
        switch resetType {
        case .global:
            .systemGreen
        case .banked:
            .systemBlue
        case .globalAndBanked:
            .systemPurple
        }
    }
}

private struct RateLimitResetTodayWebsiteLink: View {
    var title: String
    var help: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .underline(isHovered)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color(nsColor: .linkColor))
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .pointingHandCursor()
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier("rate-limit-reset-today-open-website")
        .onHover { isHovered = $0 }
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

struct QuotaEstimateSummaryView: View {
    var snapshot: QuotaEstimateSnapshot?
    var error: String?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onDetailsSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshableSectionHeader(
                title: l10n.text(.quotaEstimate),
                l10n: l10n,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh,
                infoHelp: l10n.text(.quotaEstimate),
                infoAccessibilityIdentifier: "quota-estimate-info",
                infoContent: {
                    AnyView(QuotaEstimateInfoPopover(l10n: l10n))
                })
            if let snapshot {
                heroLine(snapshot)
                    .fixedSize(horizontal: false, vertical: true)
                subtitleLine(snapshot)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                QuotaEstimateDataStatusView(snapshot: snapshot, error: error, l10n: l10n)
                SidePanelDisclosureRow(
                    title: l10n.text(.quotaEstimateThisWeek),
                    action: onDetailsSelect)
            } else if let error, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(l10n.text(isRefreshing ? .calculating : .notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func heroLine(_ snapshot: QuotaEstimateSnapshot) -> Text {
        guard let estimated = snapshot.estimatedCredits else {
            return Text("—")
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        var text = Text("\(QuotaEstimateFormatting.credits(estimated)) \(l10n.text(.quotaEstimateCredits))")
            .font(.title3.weight(.semibold).monospacedDigit())
        if let usd = snapshot.estimatedUSD, QuotaEstimateFormatting.shouldShowUSD(usd) {
            text = text + Text(" \(QuotaEstimateFormatting.approxUSD(usd))")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: .systemBlue))
        }
        return text
    }

    private func subtitleLine(_ snapshot: QuotaEstimateSnapshot) -> Text {
        let unit = l10n.text(.quotaEstimateCredits)
        if let reason = snapshot.unavailableReason {
            return Text(QuotaEstimatePresentation.unavailableText(reason, l10n: l10n))
                .foregroundColor(.secondary)
        }

        var text = Text("\(l10n.text(.quotaEstimateThisWeekUsed)) \(QuotaEstimateFormatting.credits(snapshot.usedCredits)) \(unit)")
            .foregroundColor(.secondary)
        if QuotaEstimateFormatting.shouldShowUSD(snapshot.usedUSD) {
            text = text + Text(" \(QuotaEstimateFormatting.approxUSD(snapshot.usedUSD))")
                .foregroundColor(Color(nsColor: .systemBlue))
        }
        if snapshot.canExtrapolate {
            text = text + Text(" · \(QuotaEstimateFormatting.percent(snapshot.usedPercent))")
                .foregroundColor(.secondary)
        }
        if let change = changeText(snapshot) {
            text = text + Text(" · \(change.text)")
                .foregroundColor(change.color)
        }
        return text
    }

    private func changeText(_ snapshot: QuotaEstimateSnapshot) -> (text: String, color: Color)? {
        guard let kind = snapshot.changeKind, let change = snapshot.changePercent else { return nil }
        let delta = QuotaEstimateFormatting.signedPercent(change)
        switch kind {
        case .decreased:
            return (
                "\(l10n.text(.quotaEstimateVsLast)) \(delta) · \(l10n.text(.quotaEstimateCut))",
                Color(nsColor: .systemOrange))
        case .increased:
            return (
                "\(l10n.text(.quotaEstimateVsLast)) \(delta) · \(l10n.text(.quotaEstimateIncreased))",
                Color(nsColor: .systemGreen))
        case .similar:
            return nil
        }
    }
}

enum QuotaEstimateFormatting {
    static func credits(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func tableCredits(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func percent(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value)
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func shouldShowUSD(_ value: Double) -> Bool {
        value.isFinite && abs(value) >= 0.005
    }

    static func approxUSD(_ value: Double) -> String {
        "(≈\(usd(value)))"
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value.rounded())
    }
}

private struct QuotaEstimateInfoPopover: View {
    var l10n: L10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.quotaEstimate))
                .font(.title3.weight(.semibold))
            Text(l10n.text(.quotaEstimateInfo))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l10n.text(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(l10n.text(.nextExpiry)): \(ResetCreditExpiryPresentation.duration(summary.nextExpiryRemaining, l10n: l10n))")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(ResetCreditExpiryPresentation.help(date: summary.nextExpiryDate, updatedAt: summary.updatedAt, l10n: l10n))
                    Text("\(l10n.text(.latestExpiry)): \(ResetCreditExpiryPresentation.duration(summary.latestExpiryRemaining, l10n: l10n))")
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(ResetCreditExpiryPresentation.help(date: summary.latestExpiryDate, updatedAt: summary.updatedAt, l10n: l10n))
                }
                .font(.caption)
                .monospacedDigit()
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
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SidePanelDisclosureRow(title: l10n.text(.showDetails), action: onDetailsSelect)
        }
    }
}

struct HeaderPopoverButton<PopoverContent: View>: View {
    var systemImage: String
    var help: String
    var accessibilityIdentifier: String
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(
                    isHovered ? RunwaySurface.hoverNeutral : Color.clear,
                    in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(accessibilityIdentifier)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent()
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
    var infoAccessibilityIdentifier: String? = nil
    var infoContent: (() -> AnyView)? = nil

    @State private var isRefreshHovered = false
    @State private var isInfoHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let trailingCaption, !trailingCaption.isEmpty {
                Text(trailingCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if let infoContent, let infoAccessibilityIdentifier {
                HeaderPopoverButton(
                    systemImage: "exclamationmark.circle",
                    help: infoHelp ?? l10n.text(.rateLimitResetTodaySourceTitle),
                    accessibilityIdentifier: infoAccessibilityIdentifier,
                    popoverContent: infoContent)
            } else if let onInfo {
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
                .animation(.easeOut(duration: 0.12), value: isRefreshHovered)
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
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RateLimitResetTodaySourcePopover: View {
    var l10n: L10n
    var onOpenSource: () -> Void

    @Environment(\.dismiss) private var dismiss

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

            Button {
                dismiss()
                onOpenSource()
            } label: {
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
                Button(l10n.text(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
