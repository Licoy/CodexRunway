import AppKit
import CodexRunwayCore
import SwiftUI
import Testing
@testable import CodexRunway

@Suite("Rate limit reset today layout")
struct RateLimitResetTodayLayoutTests {
    @Test("scheduled reset countdown refreshes every second")
    @MainActor
    func scheduledResetCountdownRefreshesEverySecond() {
        #expect(RateLimitResetTodayView.countdownRefreshInterval == 1)
    }

    @Test("scheduled reset card grows instead of truncating long local ranges")
    @MainActor
    func scheduledResetCardGrowsForWrappedContent() throws {
        let narrowData = try RateLimitResetTodayMockRender.render(
            kind: .scheduled,
            language: .simplifiedChinese,
            width: 280)
        let wideData = try RateLimitResetTodayMockRender.render(
            kind: .scheduled,
            language: .simplifiedChinese,
            width: 358)
        let narrowImage = try #require(NSBitmapImageRep(data: narrowData))
        let wideImage = try #require(NSBitmapImageRep(data: wideData))

        // At this width both the hero summary and expected-reset row need more
        // lines. Compare logical points so the assertion is independent of the
        // runner's 1x/2x backing scale.
        #expect(narrowImage.size.height > wideImage.size.height)
    }

    @Test("combined reset card renders at supported widths, appearances, and languages")
    @MainActor
    func combinedResetCardRendersAcrossSupportedLayouts() throws {
        let cases: [(ResolvedLanguage, CGFloat, ColorScheme)] = [
            (.english, 280, .light),
            (.simplifiedChinese, 358, .dark),
            (.traditionalChinese, 400, .light),
            (.korean, 280, .dark),
            (.japanese, 358, .light),
            (.russian, 280, .light),
            (.french, 400, .dark),
        ]
        #expect(Set(cases.map(\.0)) == Set(ResolvedLanguage.allCases))
        #expect(Set(cases.map(\.1)) == Set([280, 358, 400]))
        #expect(Set(cases.map(\.2)) == Set([.light, .dark]))

        for (language, width, colorScheme) in cases {
            let size = RateLimitResetTodayMockRender.logicalSize(
                kind: .yes,
                language: language,
                width: width,
                resetType: .globalAndBanked,
                colorScheme: colorScheme)

            #expect(size.width == width)
            #expect(size.height > 80)
        }
    }

    @Test("combined scheduled reset grows at narrow width for long copy")
    @MainActor
    func combinedScheduledResetGrowsForLongCopy() throws {
        let narrowData = try RateLimitResetTodayMockRender.render(
            kind: .scheduled,
            language: .russian,
            width: 280,
            resetType: .globalAndBanked)
        let wideData = try RateLimitResetTodayMockRender.render(
            kind: .scheduled,
            language: .russian,
            width: 400,
            resetType: .globalAndBanked)
        let narrowImage = try #require(NSBitmapImageRep(data: narrowData))
        let wideImage = try #require(NSBitmapImageRep(data: wideData))

        #expect(narrowImage.size.height > wideImage.size.height)
    }
}
