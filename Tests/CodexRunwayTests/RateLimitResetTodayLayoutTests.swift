import AppKit
import CodexRunwayCore
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
}
