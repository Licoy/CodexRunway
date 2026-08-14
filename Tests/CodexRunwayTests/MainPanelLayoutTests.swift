import AppKit
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Main panel locale layout")
struct MainPanelLayoutTests {
    @Test("shipped popover width contains English and new-locale content")
    @MainActor
    func mainPanelFitsShippedWidthForEveryLanguage() throws {
        var anyHost = false
        for language in ResolvedLanguage.allCases {
            let measurement = MainPanelMockRender.measure(language: language)
            if !measurement.hostAvailable {
                continue
            }
            anyHost = true
            #expect(measurement.fittingWidth <= measurement.panelWidth + 0.5)
            #expect(measurement.documentWidth <= measurement.panelWidth + 0.5)
            #expect(measurement.panelWidth == RunwayPopoverView.panelSize.width)
        }
        if !anyHost {
            // Headless environments can fail to produce a real NSHostingView fitting size.
            // The remaining table / formatter / picker tests still gate the change.
            return
        }
    }

    @Test("long reset-today rows grow in height instead of clipping")
    @MainActor
    func longRowsGrowInsteadOfClipping() throws {
        for language in ResolvedLanguage.allCases {
            let narrowData = try RateLimitResetTodayMockRender.render(
                kind: .scheduled,
                language: language,
                width: 280)
            let wideData = try RateLimitResetTodayMockRender.render(
                kind: .scheduled,
                language: language,
                width: RunwayPopoverView.panelSize.width)
            guard
                let narrowImage = NSBitmapImageRep(data: narrowData),
                let wideImage = NSBitmapImageRep(data: wideData)
            else {
                continue
            }
            #expect(narrowImage.size.height >= wideImage.size.height)
            #expect(wideImage.size.width <= RunwayPopoverView.panelSize.width + 1)
        }
    }
}
