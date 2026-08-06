import AppIntents
import CodexRunwayCore
import SwiftUI
import WidgetKit

@main
@available(macOS 14.0, *)
struct CodexRunwayWidgetBundle: WidgetBundle {
    var body: some Widget {
        RunwayOverviewWidget()
        RunwayTokenTrendWidget()
        RunwayMetricWidget()
        RunwayResetTodayWidget()
    }
}

@available(macOS 14.0, *)
struct RunwayOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: RunwayWidgetKind.overview.rawValue,
            intent: RunwayProviderSelectionIntent.self,
            provider: RunwayProviderTimelineProvider())
        { entry in
            RunwayOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Quota Overview")
        .description("Codex and Grok quota, cost, tokens, and balances.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@available(macOS 14.0, *)
struct RunwayTokenTrendWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: RunwayWidgetKind.tokenTrend.rawValue,
            intent: RunwayProviderSelectionIntent.self,
            provider: RunwayProviderTimelineProvider())
        { entry in
            RunwayTokenTrendWidgetView(entry: entry)
        }
        .configurationDisplayName("Token Trend")
        .description("Recent Codex and Grok token activity.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@available(macOS 14.0, *)
struct RunwayMetricWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: RunwayWidgetKind.metric.rawValue,
            intent: RunwayMetricSelectionIntent.self,
            provider: RunwayMetricTimelineProvider())
        { entry in
            RunwayMetricWidgetView(entry: entry)
        }
        .configurationDisplayName("Key Metric")
        .description("One focused quota, cost, token, or balance metric.")
        .supportedFamilies([.systemSmall])
    }
}

@available(macOS 14.0, *)
struct RunwayResetTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: RunwayWidgetKind.resetToday.rawValue,
            provider: RunwayResetTimelineProvider())
        { entry in
            RunwayResetTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Reset Today")
        .description("Today’s Codex reset status and next scheduled reset.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
