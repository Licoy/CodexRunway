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
        let data = try RateLimitResetTodayMockRender.render(
            kind: .scheduled,
            language: .simplifiedChinese,
            width: 280)
        let image = try #require(NSBitmapImageRep(data: data))

        // At this width both the hero summary and expected-reset row need more
        // than two lines. The rendered card must grow instead of clipping them.
        #expect(image.pixelsHigh >= 560)
    }
}
