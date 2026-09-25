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

    @Test("all reset update states render across languages, widths, and appearances")
    @MainActor
    func resetUpdateQAMatrixRenders() {
        #expect(Set(RateLimitResetTodayMockRender.qaCases.map(\.language)) == Set(ResolvedLanguage.allCases))
        #expect(Set(RateLimitResetTodayMockRender.qaCases.map(\.width)) == Set([280, 358, 400]))
        #expect(Set(RateLimitResetTodayMockRender.qaCases.map(\.colorScheme)) == Set([.light, .dark]))
        let kinds = RateLimitResetTodayMockRender.qaCases.map(\.kind)
        for kind in [
            RateLimitResetTodaySnapshot.DevMockKind.explicitScheduled,
            .inferredScheduled,
            .grace,
            .expired,
            .unavailable,
        ] {
            #expect(kinds.contains(kind))
        }

        for item in RateLimitResetTodayMockRender.qaCases {
            let size = RateLimitResetTodayMockRender.logicalSize(
                kind: item.kind,
                language: item.language,
                width: item.width,
                resetType: .global,
                colorScheme: item.colorScheme)
            #expect(size.width == item.width)
            #expect(size.height > 80)
        }
    }

    @Test("hero keeps six-digit reactions inline when they fit and wraps only when needed")
    @MainActor
    func heroAdaptsToNaturalContentWidth() {
        let normalWithoutReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .explicitScheduled,
            language: .simplifiedChinese,
            width: 358,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: false,
            confidence: 0.88,
            reactionCount: 107_516)
        let normalWithReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .explicitScheduled,
            language: .simplifiedChinese,
            width: 358,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: true,
            confidence: 0.88,
            reactionCount: 107_516)
        let narrowWithoutReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .grace,
            language: .japanese,
            width: 280,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: false,
            confidence: 0.92,
            reactionCount: 107_516)
        let narrowWithReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .grace,
            language: .japanese,
            width: 280,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: true,
            confidence: 0.92,
            reactionCount: 107_516)

        #expect(normalWithReaction.width == 358)
        #expect(abs(normalWithReaction.height - normalWithoutReaction.height) <= 1)
        #expect(narrowWithReaction.width == 280)
        #expect(narrowWithReaction.height > narrowWithoutReaction.height)
    }

    @Test("legacy hero layout uses the same natural-width contract")
    @MainActor
    func legacyHeroAdaptsToNaturalContentWidth() {
        let normalWithoutReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .explicitScheduled,
            language: .simplifiedChinese,
            width: 358,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: false,
            confidence: 0.88,
            reactionCount: 107_516,
            usesLegacyHeroLayout: true)
        let normalWithReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .explicitScheduled,
            language: .simplifiedChinese,
            width: 358,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: true,
            confidence: 0.88,
            reactionCount: 107_516,
            usesLegacyHeroLayout: true)
        let narrowWithoutReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .grace,
            language: .japanese,
            width: 280,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: false,
            confidence: 0.92,
            reactionCount: 107_516,
            usesLegacyHeroLayout: true)
        let narrowWithReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .grace,
            language: .japanese,
            width: 280,
            resetType: .global,
            colorScheme: .dark,
            showsReaction: true,
            confidence: 0.92,
            reactionCount: 107_516,
            usesLegacyHeroLayout: true)
        let unavailableWithoutReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .unavailable,
            language: .french,
            width: 280,
            resetType: .global,
            colorScheme: .light,
            showsReaction: false,
            usesLegacyHeroLayout: true)
        let unavailableWithReaction = RateLimitResetTodayMockRender.logicalSize(
            kind: .unavailable,
            language: .french,
            width: 280,
            resetType: .global,
            colorScheme: .light,
            showsReaction: true,
            usesLegacyHeroLayout: true)

        #expect(abs(normalWithReaction.height - normalWithoutReaction.height) <= 1)
        #expect(narrowWithReaction.height > narrowWithoutReaction.height)
        #expect(unavailableWithReaction.height > unavailableWithoutReaction.height)
    }

    @Test("website link copy is localized for every language")
    func websiteLinkCopyIsLocalized() {
        for language in ResolvedLanguage.allCases {
            let text = L10n(language: language).text(.rateLimitResetTodayOpenWebsite)
            #expect(!text.isEmpty)
            #expect(text != L10nKey.rateLimitResetTodayOpenWebsite.rawValue)
        }
        #expect(
            L10n(language: .simplifiedChinese).text(.rateLimitResetTodayOpenWebsite)
                == "去 Did Codex Reset 查看重置信息和历史记录")
    }
}
