import CodexRunwayCore
import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
struct RunwayOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RunwayWidgetEntry

    var body: some View {
        Group {
            switch entry.state {
            case .ready(let snapshot): content(snapshot)
            case .missing, .corrupt, .unsupportedVersion: RunwayWidgetUnavailableView(state: entry.state)
            }
        }
        .runwayWidgetPreviewUnredacted(entry.isPlaceholder)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(RunwayWidgetDeepLink(provider: entry.provider, section: .overview).url)
    }

    private func content(_ snapshot: RunwayWidgetSnapshot) -> some View {
        let l10n = L10n(language: snapshot.language)
        let providers = entry.provider.providers.compactMap(snapshot.provider)
        return VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            RunwayWidgetHeader(title: l10n.text(.widgetOverviewTitle), trailing: entry.provider.label)
            if providers.isEmpty {
                Text(l10n.text(.widgetNoData)).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(providers.enumerated()), id: \.element.provider) { index, provider in
                    if index > 0 { Divider() }
                    providerQuota(provider, l10n: l10n)
                }
            }
            Spacer(minLength: 0)
            RunwayWidgetFreshness(snapshot: snapshot, now: entry.date, l10n: l10n)
        }
    }

    @ViewBuilder
    private func providerQuota(_ provider: RunwayWidgetProviderSnapshot, l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RunwayProviderLabel(provider: provider.provider, plan: provider.plan)
            if provider.availability != .available {
                Text(runwayAvailabilityText(provider.availability, l10n: l10n))
                    .font(.caption).foregroundStyle(.secondary)
            } else if provider.quota.isEmpty {
                Text(l10n.text(.widgetNoData))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let quota = RunwayWidgetLayoutPolicy.quotaLimit(for: family.runwayFamily)
                    .map { Array(provider.quota.prefix($0)) }
                    ?? provider.quota
                ForEach(Array(quota.enumerated()), id: \.offset) { _, meter in
                    RunwayQuotaRow(quota: meter, showsCountdown: family != .systemSmall)
                }
                if family == .systemLarge {
                    HStack(spacing: 14) {
                        extra(l10n.text(.widgetCost), runwayMoney(provider.apiEquivalentCostUSD) ?? "—")
                        extra(l10n.text(.tokens), runwayCompactNumber(provider.tokenTotal(limit: 30)))
                        extra(l10n.text(.widgetBalance), runwayMoney(provider.balanceUSD) ?? "—")
                        if let resets = provider.resetCredits {
                            extra(l10n.text(.widgetResetCredits), "\(resets.availableCount)")
                        }
                    }
                }
            }
        }
    }

    private func extra(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
    }

}

@available(macOS 14.0, *)
struct RunwayTokenTrendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RunwayWidgetEntry

    var body: some View {
        Group {
            switch entry.state {
            case .ready(let snapshot): content(snapshot)
            case .missing, .corrupt, .unsupportedVersion: RunwayWidgetUnavailableView(state: entry.state)
            }
        }
        .runwayWidgetPreviewUnredacted(entry.isPlaceholder)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(RunwayWidgetDeepLink(provider: entry.provider, section: .tokens).url)
    }

    private func content(_ snapshot: RunwayWidgetSnapshot) -> some View {
        let l10n = L10n(language: snapshot.language)
        let limit = RunwayWidgetLayoutPolicy.trendDays(for: family.runwayFamily)
        let providers = entry.provider.providers.compactMap(snapshot.provider)
        return VStack(alignment: .leading, spacing: 9) {
            RunwayWidgetHeader(title: l10n.text(.widgetTokenTrendTitle), trailing: "\(limit)d")
            ForEach(Array(providers.enumerated()), id: \.element.provider) { index, provider in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        RunwayProviderLabel(provider: provider.provider, plan: nil)
                        Spacer()
                        Text(source(provider.tokenSource, l10n: l10n))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(runwayCompactNumber(provider.tokenTotal(limit: limit)))
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    let points = Array(provider.dailyTokens.suffix(limit))
                    if provider.availability != .available {
                        Text(runwayAvailabilityText(provider.availability, l10n: l10n))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if points.isEmpty {
                        Text(l10n.text(.tokenUsageHeatmapUnavailable))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        RunwayTokenBars(points: points)
                            .frame(minHeight: providers.count > 1 ? 32 : 52)
                    }
                }
            }
            Spacer(minLength: 0)
            RunwayWidgetFreshness(snapshot: snapshot, now: entry.date, l10n: l10n)
        }
    }

    private func source(_ source: RunwayWidgetTokenSource, l10n: L10n) -> String {
        source == .allDevices ? l10n.text(.widgetAllDevices) : l10n.text(.widgetThisMac)
    }
}

@available(macOS 14.0, *)
struct RunwayMetricWidgetView: View {
    var entry: RunwayWidgetEntry

    var body: some View {
        Group {
            switch entry.state {
            case .ready(let snapshot): content(snapshot)
            case .missing, .corrupt, .unsupportedVersion: RunwayWidgetUnavailableView(state: entry.state)
            }
        }
        .runwayWidgetPreviewUnredacted(entry.isPlaceholder)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(RunwayWidgetDeepLink(provider: entry.provider, section: section).url)
    }

    private func content(_ snapshot: RunwayWidgetSnapshot) -> some View {
        let l10n = L10n(language: snapshot.language)
        let providers = entry.provider.providers.compactMap(snapshot.provider)
        return VStack(alignment: .leading, spacing: 9) {
            RunwayWidgetHeader(title: metricTitle(l10n), trailing: nil)
            ForEach(Array(providers.enumerated()), id: \.element.provider) { index, provider in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    Text(provider.provider == .codex ? "Codex" : "Grok")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(metricValue(provider))
                            .font(providers.count == 1 ? .title.weight(.bold) : .title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(metricColor(provider))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if provider.availability != .available {
                            Text(runwayAvailabilityText(provider.availability, l10n: l10n))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            RunwayWidgetFreshness(snapshot: snapshot, now: entry.date, l10n: l10n)
        }
    }

    private var section: RunwayWidgetSection {
        switch entry.metric {
        case .remainingQuota, .balance: .quota
        case .apiEquivalentCost: .cost
        case .tokenCount: .tokens
        }
    }

    private func metricTitle(_ l10n: L10n) -> String {
        switch entry.metric {
        case .remainingQuota: l10n.text(.widgetRemaining)
        case .apiEquivalentCost: l10n.text(.widgetCost)
        case .tokenCount: l10n.text(.tokens)
        case .balance: l10n.text(.widgetBalance)
        }
    }

    private func metricValue(_ provider: RunwayWidgetProviderSnapshot) -> String {
        guard provider.availability == .available else { return "—" }
        return switch entry.metric {
        case .remainingQuota: provider.primaryQuota.map { "\($0.remainingPercent)%" } ?? "—"
        case .apiEquivalentCost: runwayMoney(provider.apiEquivalentCostUSD) ?? "—"
        case .tokenCount: runwayCompactNumber(provider.tokenTotal(limit: 30))
        case .balance: runwayMoney(provider.balanceUSD) ?? "—"
        }
    }

    private func metricColor(_ provider: RunwayWidgetProviderSnapshot) -> Color {
        guard entry.metric == .remainingQuota, let quota = provider.primaryQuota else {
            return entry.metric == .tokenCount ? RunwayWidgetPalette.token : .primary
        }
        return RunwayWidgetPalette.quota(remaining: quota.remainingPercent)
    }
}

@available(macOS 14.0, *)
struct RunwayResetTodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RunwayWidgetEntry

    var body: some View {
        Group {
            switch entry.state {
            case .ready(let snapshot): content(snapshot)
            case .missing, .corrupt, .unsupportedVersion: RunwayWidgetUnavailableView(state: entry.state)
            }
        }
        .runwayWidgetPreviewUnredacted(entry.isPlaceholder)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(RunwayWidgetDeepLink(provider: .codex, section: .resetToday).url)
    }

    private func content(_ snapshot: RunwayWidgetSnapshot) -> some View {
        let l10n = L10n(language: snapshot.language)
        return VStack(alignment: .leading, spacing: 8) {
            RunwayWidgetHeader(title: l10n.text(.widgetResetTodayTitle), trailing: "Codex")
            if let reset = snapshot.resetToday {
                Text(stateText(reset.state, l10n: l10n))
                    .font(.system(size: family == .systemSmall ? 34 : 42, weight: .bold, design: .rounded))
                    .foregroundStyle(stateColor(reset.state))
                if let resetType = reset.resetType {
                    Text(resetType.localizedName(l10n: l10n))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(resetTypeColor(resetType))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                if let next = reset.nextScheduledAt {
                    HStack(spacing: 5) {
                        if let resetType = reset.nextScheduledResetType {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(resetType.localizedName(l10n: l10n))
                                .fontWeight(.semibold)
                                .foregroundStyle(resetTypeColor(resetType))
                        } else {
                            Text(l10n.text(.rateLimitResetTodayNextScheduled))
                        }
                        Spacer(minLength: 4)
                        Text(next, style: .timer).monospacedDigit()
                    }
                    .font(.caption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text(nextScheduleAccessibilityLabel(reset.nextScheduledResetType, l10n: l10n)))
                    .accessibilityValue(Text(next, style: .timer))
                }
                if family == .systemMedium, let checked = reset.lastSuccessfulCheckAt {
                    HStack(spacing: 4) {
                        Text(l10n.text(.rateLimitResetTodayLastCheck))
                        Text(checked, style: .relative)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(l10n.text(.widgetNoData)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let reset = snapshot.resetToday {
                let freshnessDate = reset.lastSuccessfulCheckAt ?? reset.fetchedAt
                RunwayWidgetFreshness(
                    date: freshnessDate,
                    isStale: entry.date.timeIntervalSince(freshnessDate) > RunwayWidgetSnapshot.staleAfter,
                    now: entry.date,
                    l10n: l10n)
            } else {
                RunwayWidgetFreshness(snapshot: snapshot, now: entry.date, l10n: l10n)
            }
        }
    }

    private func stateText(_ state: RunwayWidgetResetTodaySnapshot.State, l10n: L10n) -> String {
        switch state {
        case .yes: l10n.text(.rateLimitResetTodayYes)
        case .no: l10n.text(.rateLimitResetTodayNo)
        case .unknown: l10n.text(.rateLimitResetTodayUnknown)
        }
    }

    private func stateColor(_ state: RunwayWidgetResetTodaySnapshot.State) -> Color {
        switch state {
        case .yes: .green
        case .no: .primary
        case .unknown: .yellow
        }
    }

    private func resetTypeColor(_ resetType: RateLimitResetType) -> Color {
        switch resetType {
        case .global: Color(nsColor: .systemGreen)
        case .banked: Color(nsColor: .systemBlue)
        case .globalAndBanked: Color(nsColor: .systemPurple)
        }
    }

    private func nextScheduleAccessibilityLabel(
        _ resetType: RateLimitResetType?,
        l10n: L10n
    ) -> String {
        let label = l10n.text(.rateLimitResetTodayNextScheduled)
        guard let resetType else { return label }
        return "\(label) · \(resetType.localizedName(l10n: l10n))"
    }
}
