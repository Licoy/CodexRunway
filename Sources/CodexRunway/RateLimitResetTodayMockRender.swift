import AppKit
import CodexRunwayCore
import SwiftUI

/// Renders the rate-limit-reset section with fixture data for design checks.
enum RateLimitResetTodayMockRender {
    @MainActor
    static func render(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        language: ResolvedLanguage = .simplifiedChinese,
        width: CGFloat = 358) throws -> Data
    {
        let l10n = L10n(language: language)
        let snapshot = RateLimitResetTodaySnapshot.devMock(kind: kind)
        let root = RateLimitResetTodayView(
            snapshot: snapshot,
            l10n: l10n,
            isRefreshing: false,
            onRefresh: {},
            onOpenSource: {},
            onOpenEvidence: { _ in })
            .padding(16)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        var height = host.fittingSize.height
        if height < 80 { height = 180 }
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    @MainActor
    static func write(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        language: ResolvedLanguage = .simplifiedChinese,
        to path: String) throws
    {
        let data = try render(kind: kind, language: language)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url)
        print("wrote \(path) (\(data.count) bytes)")
    }
}
