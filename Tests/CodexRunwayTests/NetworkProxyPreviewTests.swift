import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Network proxy previews", .serialized)
@MainActor
struct NetworkProxyPreviewTests {
    @Test("authenticated proxy fits all seven locales in both appearances")
    func localizedProxyPreviews() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/proxy-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var measurements = ["locale\tappearance\twidth\tfittingHeight\tdocumentHeight\tviewportHeight"]
        for language in ResolvedLanguage.allCases {
            for appearance in MainPanelMockRender.Appearance.allCases {
                measurements.append(try render(language: language, appearance: appearance, directory: directory))
                // Let pending MainActor network callbacks run between complete offscreen renders.
                await Task.yield()
            }
        }
        try measurements.joined(separator: "\n").appending("\n")
            .write(to: directory.appendingPathComponent("layout.tsv"), atomically: true, encoding: .utf8)
    }

    private func render(
        language: ResolvedLanguage,
        appearance: MainPanelMockRender.Appearance,
        directory: URL) throws -> String
    {
        let suiteName = "NetworkProxyPreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = try fixtureSettings(defaults: defaults, language: language)
        let titles = ControlPanelTab.allCases.map { $0.title(settings.l10n) }
        let width = ControlPanelLayout.panelWidth(titles: titles) - 2 * ControlPanelLayout.horizontalContentPadding
        let host = NSHostingView(rootView: PreferencesPane {
            NetworkProxySettingsView(settings: settings)
        }
        .frame(width: width, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance == .dark ? .dark : .light))
        let window = offscreenWindow(host: host, appearance: appearance, width: width)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        settle(host)
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView)
        let fitting = document.fittingSize
        try verifyLayout(document: document, scroll: scroll, fitting: fitting)
        let name = "\(language.rawValue)-\(appearance.rawValue)"
        let image = try snapshot(settings: settings, appearance: appearance, size: fitting)
        try image.write(to: directory.appendingPathComponent("\(name).png"))
        return "\(language.rawValue)\t\(appearance.rawValue)\t\(document.frame.width)\t\(fitting.height)\t\(document.frame.height)\t\(scroll.contentSize.height)"
    }

    private func fixtureSettings(defaults: UserDefaults, language: ResolvedLanguage) throws -> RunwaySettings {
        let store = NetworkProxyStore(defaults: defaults)
        try store.save(NetworkProxyConfiguration(
            mode: .http, host: "proxy.example.com", port: 8080,
            usesAuthentication: true, credentialID: UUID().uuidString))
        let credentials = ProxyCredentialStore(
            load: { _, _ in
                Issue.record("Rendering must not read Keychain credentials")
                throw NetworkProxyError.credentialsUnavailable
            },
            save: { _, _ in Issue.record("Rendering must not save Keychain credentials") },
            delete: { _ in Issue.record("Rendering must not delete Keychain credentials") })
        let settings = RunwaySettings(
            store: PreferencesStore(defaults: defaults),
            networkProxyStore: store, proxyCredentialStore: credentials)
        settings.updateLanguage(language.preference)
        return settings
    }

    private func offscreenWindow<Content: View>(
        host: NSHostingView<Content>,
        appearance: MainPanelMockRender.Appearance,
        width: CGFloat) -> NSWindow
    {
        let window = ProxyPreviewWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 320),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.nsAppearance
        host.appearance = appearance.nsAppearance
        host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
        window.contentView = host
        return window
    }

    private func verifyLayout(document: NSView, scroll: NSScrollView, fitting: NSSize) throws {
        try #require(fitting.width > 1 && fitting.height > 1, "AppKit must provide a real layout")
        #expect(fitting.height > scroll.contentSize.height, "The dense fixture must exercise vertical scrolling")
        #expect(abs(document.frame.width - scroll.contentSize.width) <= 1)
        #expect(document.frame.height + 1 >= fitting.height, "The document must include the full fitted content")
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        let controls = nativeControls(in: document).filter { !$0.isHidden && $0.bounds.width > 1 }
        #expect(controls.filter { $0 is NSTextField }.count >= 4, "Host, port, username and password must be rendered")
        for control in controls {
            let frame = control.convert(control.bounds, to: document)
            #expect(frame.minX >= -1 && frame.maxX <= document.bounds.width + 1, "Control must stay inside the pane: \(frame)")
            #expect(
                frame.midX > document.bounds.midX - 8,
                "Proxy controls must sit on the trailing edge: \(frame)")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY + 1 >= document.bounds.maxY, "The bottom of the group must be reachable")
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func nativeControls(in view: NSView) -> [NSControl] {
        ((view as? NSControl).map { [$0] } ?? [])
            + view.subviews.flatMap { nativeControls(in: $0) }
    }

    private func snapshot(
        settings: RunwaySettings,
        appearance: MainPanelMockRender.Appearance,
        size: NSSize) throws -> Data
    {
        // Capture a full-height root rather than a clipped scroll document, so native
        // controls and the SwiftUI layer tree participate in the same drawing pass.
        let host = NSHostingView(rootView: NetworkProxySettingsView(settings: settings)
            .padding(.horizontal, 20).padding(.vertical, 12).padding(.trailing, 4)
            .frame(width: size.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .dark ? .dark : .light))
        let window = offscreenWindow(host: host, appearance: appearance, width: size.width)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let fullSize = NSSize(width: size.width, height: ceil(size.height))
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.ignoresMouseEvents = true
        window.setContentSize(fullSize)
        host.frame = NSRect(origin: .zero, size: fullSize)
        window.orderFront(nil)
        settle(host)
        window.displayIfNeeded()
        #expect(abs(host.fittingSize.height - size.height) <= 1, "Snapshot must retain the full authenticated layout")
        return try pngData(from: host)
    }

    private func pngData(from view: NSView) throws -> Data {
        let bounds = view.bounds
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * 2)),
            pixelsHigh: Int(ceil(bounds.height * 2)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: bitmap)
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1_000, "Preview must contain rendered pixels")
        return data
    }
}

@MainActor
private final class ProxyPreviewWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // Opening an offscreen window must not simulate editing the first text field.
        if responder is NSTextField || responder is NSTextView { return false }
        return super.makeFirstResponder(responder)
    }
}
