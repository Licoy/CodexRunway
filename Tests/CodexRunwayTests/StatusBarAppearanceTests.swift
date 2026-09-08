import AppKit
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status bar appearance")
struct StatusBarAppearanceTests {
    @Test("quota fills contrast against light and dark menu bars")
    @MainActor
    func quotaColorsRemainReadable() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let palette = StatusBarPalette(appearance: appearance)
            let background = NSColor(white: name == .aqua ? 0.92 : 0.14, alpha: 1)
            for health in [QuotaHealth.green, .yellow, .red] {
                let color = try #require(palette.color(for: health).usingColorSpace(.sRGB))
                #expect(contrast(color, background) >= 3)
            }
        }
    }

    @Test("renders quota meters in both menu bar appearances")
    @MainActor
    func renderBothAppearances() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var preferences = RunwayPreferences()
            preferences.statusBarDisplayStyle = .meters
            let meters = [20, 51, 90].map { used in
                QuotaMeter(title: "每周", window: RateWindow(usedPercent: used, windowMinutes: 10_080, resetsAt: nil))
            }
            let view = StatusBarContentView(frame: .zero)
            view.appearance = appearance
            view.update(StatusBarContentState(
                configuration: .init(preferences: preferences, language: .simplifiedChinese),
                content: .init(text: "", meters: meters, displayMinute: 0)))
            view.frame = NSRect(x: 0, y: 0, width: view.preferredWidth, height: 22)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            appearance.performAsCurrentDrawingAppearance {
                NSColor(white: name == .aqua ? 0.92 : 0.14, alpha: 1).setFill()
                view.bounds.fill()
                view.draw(view.bounds)
            }
            image.unlockFocus()
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide > 100)
            if let directory = ProcessInfo.processInfo.environment["RUNWAY_TEST_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent(name == .aqua ? "status-light.png" : "status-dark.png"))
            }
        }
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ c: CGFloat) -> CGFloat {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let first = luminance(foreground), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
