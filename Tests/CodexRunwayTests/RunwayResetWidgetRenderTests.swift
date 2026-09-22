import AppKit
import CodexRunwayCore
import SwiftUI
import Testing
import WidgetKit
@testable import CodexRunwayWidget

@Suite("Reset widget rendering")
struct RunwayResetWidgetRenderTests {
    @MainActor
    @Test("small and medium grace views render in every language and appearance")
    func renderGraceMatrix() throws {
        guard #available(macOS 14.0, *) else { return }
        let directory = URL(fileURLWithPath: "/private/tmp/codex-reset-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for language in ResolvedLanguage.allCases {
            for family in [WidgetFamily.systemSmall, .systemMedium] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let url = directory.appendingPathComponent(
                        "\(language.rawValue)-\(familyName(family))-\(appearance == .darkAqua ? "dark" : "light").png")
                    try render(
                        entry: entry(language: language, scenario: .grace),
                        family: family,
                        appearance: appearance,
                        to: url)
                    #expect(FileManager.default.fileExists(atPath: url.path))
                }
            }
        }
        for (scenario, family) in [
            (Scenario.inferred, WidgetFamily.systemSmall),
            (.unavailable, .systemMedium),
            (.legacy, .systemSmall),
        ] {
            let url = directory.appendingPathComponent(
                "english-\(familyName(family))-\(scenario.rawValue)-light.png")
            try render(
                entry: entry(language: .english, scenario: scenario),
                family: family,
                appearance: .aqua,
                to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @available(macOS 14.0, *)
    @MainActor
    private func render(
        entry: RunwayWidgetEntry,
        family: WidgetFamily,
        appearance: NSAppearance.Name,
        to url: URL) throws
    {
        let size = family == .systemSmall
            ? CGSize(width: 170, height: 170)
            : CGSize(width: 360, height: 170)
        let colorScheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let view = RunwayResetTodayWidgetView(entry: entry, familyOverride: family)
            .frame(width: size.width, height: size.height)
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 28, height: size.height + 28))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngUnavailable
        }
        try png.write(to: url, options: .atomic)
    }

    private func entry(language: ResolvedLanguage, scenario: Scenario) -> RunwayWidgetEntry {
        let now = Date()
        let presentation: RunwayWidgetResetTodayTimelineEntry? = switch scenario {
        case .grace:
            RunwayWidgetResetTodayTimelineEntry(
                effectiveAt: now,
                reason: .grace,
                state: .yes,
                resetType: .globalAndBanked,
                nextScheduledAt: nil,
                nextScheduledResetType: nil,
                scheduleBasis: .explicit,
                confidencePercent: 98,
                confidenceBand: .ok)
        case .inferred:
            RunwayWidgetResetTodayTimelineEntry(
                effectiveAt: now,
                reason: .upcoming,
                state: .yes,
                resetType: .global,
                nextScheduledAt: now.addingTimeInterval(1_800),
                nextScheduledResetType: .global,
                scheduleBasis: .contextualInference,
                confidencePercent: 65,
                confidenceBand: .warn)
        case .unavailable:
            RunwayWidgetResetTodayTimelineEntry(
                effectiveAt: now,
                reason: .unavailable,
                state: .unknown,
                resetType: nil,
                nextScheduledAt: nil,
                nextScheduledResetType: nil,
                confidencePercent: nil,
                confidenceBand: nil)
        case .legacy:
            nil
        }
        let reset = RunwayWidgetResetTodaySnapshot(
            state: presentation?.state ?? .yes,
            resetType: presentation?.resetType,
            nextScheduledAt: presentation?.nextScheduledAt,
            lastSuccessfulCheckAt: now.addingTimeInterval(-300),
            fetchedAt: now,
            confidencePercent: presentation?.confidencePercent,
            confidenceBand: presentation?.confidenceBand,
            timeline: presentation.map { [$0] })
        let snapshot = RunwayWidgetSnapshot(
            generatedAt: now,
            language: language,
            providers: [],
            resetToday: reset)
        return RunwayWidgetEntry(
            date: now,
            state: .ready(snapshot),
            provider: .codex,
            metric: .remainingQuota)
    }

    private func familyName(_ family: WidgetFamily) -> String {
        family == .systemSmall ? "small" : "medium"
    }

    private enum RenderError: Error {
        case bitmapUnavailable
        case pngUnavailable
    }

    private enum Scenario: String {
        case grace
        case inferred
        case unavailable
        case legacy
    }
}
