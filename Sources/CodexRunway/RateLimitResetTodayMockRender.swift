import AppKit
import CodexRunwayCore
import SwiftUI

/// Renders the rate-limit-reset section with fixture data for design checks.
enum RateLimitResetTodayMockRender {
    @MainActor
    static func render(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        language: ResolvedLanguage = .simplifiedChinese,
        width: CGFloat = 358,
        resetType: RateLimitResetType = .global,
        colorScheme: ColorScheme = .light) throws -> Data
    {
        let host = NSHostingView(rootView: root(
            kind: kind,
            language: language,
            width: width,
            resetType: resetType,
            colorScheme: colorScheme))
        layout(host, width: width)

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
    static func logicalSize(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        language: ResolvedLanguage,
        width: CGFloat,
        resetType: RateLimitResetType,
        colorScheme: ColorScheme) -> CGSize
    {
        let host = NSHostingView(rootView: root(
            kind: kind,
            language: language,
            width: width,
            resetType: resetType,
            colorScheme: colorScheme))
        layout(host, width: width)
        return host.frame.size
    }

    @MainActor
    private static func root(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        language: ResolvedLanguage,
        width: CGFloat,
        resetType: RateLimitResetType,
        colorScheme: ColorScheme) -> some View
    {
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: kind)
        if !snapshot.events.isEmpty {
            snapshot.events[0].resetType = resetType
        }
        return RateLimitResetTodayView(
            snapshot: snapshot,
            l10n: L10n(language: language),
            isRefreshing: false,
            onRefresh: {},
            onOpenSource: {},
            onOpenEvidence: { _ in })
            .padding(16)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
    }

    @MainActor
    private static func layout<Content: View>(_ host: NSHostingView<Content>, width: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        let fittingHeight = host.fittingSize.height
        let height = fittingHeight < 80 ? 180 : fittingHeight
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
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
