import AppIntents
import Foundation

@available(macOS 14.0, *)
enum RunwayProviderChoice: String, AppEnum {
    case codex
    case grok
    case both

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static let caseDisplayRepresentations: [RunwayProviderChoice: DisplayRepresentation] = [
        .codex: DisplayRepresentation(title: "Codex"),
        .grok: DisplayRepresentation(title: "Grok"),
        .both: DisplayRepresentation(title: "Both"),
    ]
}

@available(macOS 14.0, *)
enum RunwayMetricChoice: String, AppEnum {
    case remainingQuota
    case apiEquivalentCost
    case tokenCount
    case balance

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static let caseDisplayRepresentations: [RunwayMetricChoice: DisplayRepresentation] = [
        .remainingQuota: DisplayRepresentation(title: "Remaining quota"),
        .apiEquivalentCost: DisplayRepresentation(title: "API equivalent cost"),
        .tokenCount: DisplayRepresentation(title: "Token count"),
        .balance: DisplayRepresentation(title: "Balance"),
    ]
}

@available(macOS 14.0, *)
struct RunwayProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Choose which provider the widget displays.")

    @Parameter(title: "Provider", default: .codex)
    var provider: RunwayProviderChoice

    init() {
        provider = .codex
    }
}

@available(macOS 14.0, *)
struct RunwayMetricSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Key Metric"
    static let description = IntentDescription("Choose a provider and metric.")

    @Parameter(title: "Provider", default: .codex)
    var provider: RunwayProviderChoice

    @Parameter(title: "Metric", default: .remainingQuota)
    var metric: RunwayMetricChoice

    init() {
        provider = .codex
        metric = .remainingQuota
    }
}
