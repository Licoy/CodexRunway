import AppKit
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Control panel tabs", .serialized)
struct ControlPanelTabBarTests {
    @Test("control panel keeps the SwiftUI system tab view")
    func controlPanelUsesSystemTabView() throws {
        let source = try String(contentsOf: sourceURL("ControlPanelView.swift"), encoding: .utf8)

        #expect(source.contains("TabView(selection: $selectedTab)"))
        #expect(source.contains(".id(l10n.language.rawValue)"))
        #expect(source.contains(".frame(width: panelWidth, height: Self.panelHeight)"))
        #expect(!source.contains("ControlPanelTabStrip"))
        #expect(!source.contains("ToolbarItem(placement: .principal)"))
    }

    @Test("every shipped language has a non-empty title for each settings tab")
    func titlesAreCompleteForEveryLanguage() {
        #expect(ControlPanelTab.allCases == [
            .general,
            .accounts,
            .display,
            .advanced,
            .about,
        ])
        for language in ResolvedLanguage.allCases {
            let l10n = L10n(language: language)
            var seen: Set<String> = []
            for tab in ControlPanelTab.allCases {
                let title = tab.title(l10n)
                #expect(!title.isEmpty)
                #expect(!tab.systemImage.isEmpty)
                #expect(seen.insert(title).inserted)
            }
        }
    }

    @Test("window and native tab group grow to preserve every localized title")
    @MainActor
    func windowAndTabsGrowForLocalizedTitles() {
        _ = NSApplication.shared
        for language in ResolvedLanguage.allCases {
            let titles = ControlPanelTab.allCases.map { $0.title(L10n(language: language)) }
            let panelWidth = ControlPanelLayout.panelWidth(titles: titles)
            #expect(panelWidth >= ControlPanelLayout.minimumPanelWidth)
            if language != .russian {
                #expect(panelWidth == ControlPanelLayout.minimumPanelWidth)
            }
            #expect(
                ControlPanelLayout.tabStripAvailableWidth(titles: titles)
                    >= ControlPanelLayout.naturalStripWidth(titles: titles))
            #expect(!ControlPanelLayout.needsTruncation(titles: titles))
        }

        let english = ControlPanelTab.allCases.map { $0.title(L10n(language: .english)) }
        let russian = ControlPanelTab.allCases.map { $0.title(L10n(language: .russian)) }
        #expect(ControlPanelLayout.naturalStripWidth(titles: russian) > 550)
        #expect(ControlPanelLayout.panelWidth(titles: russian) >= 722)
        #expect(
            ControlPanelLayout.panelWidth(titles: russian)
                > ControlPanelLayout.panelWidth(titles: english))
    }

    @Test("localized tab width measurement grows for the longest labels")
    @MainActor
    func localizedTabWidthMeasurementTracksLabels() {
        _ = NSApplication.shared
        var measuredWidths: [ResolvedLanguage: CGFloat] = [:]
        for language in ResolvedLanguage.allCases {
            let titles = ControlPanelTab.allCases.map { $0.title(L10n(language: language)) }
            let width = ControlPanelLayout.naturalStripWidth(titles: titles)
            #expect(width > 0)
            measuredWidths[language] = width
        }
        #expect(measuredWidths[.russian] == measuredWidths.values.max())
    }

    @Test("panel size expands and contracts when the language changes")
    @MainActor
    func panelSizeTracksLocalizedTabWidth() {
        let english = ControlPanelTab.allCases.map { $0.title(L10n(language: .english)) }
        let russian = ControlPanelTab.allCases.map { $0.title(L10n(language: .russian)) }
        let englishSize = ControlPanelLayout.contentSize(titles: english)
        let russianSize = ControlPanelLayout.contentSize(titles: russian)
        let restoredSize = ControlPanelLayout.contentSize(titles: english)

        #expect(russianSize.width > englishSize.width)
        #expect(restoredSize == englishSize)
        #expect(englishSize.height == ControlPanelLayout.panelHeight)
        #expect(russianSize.height == ControlPanelLayout.panelHeight)
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexRunway/\(name)")
    }
}
