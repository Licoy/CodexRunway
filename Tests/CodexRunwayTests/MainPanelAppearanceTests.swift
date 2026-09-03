import AppKit
import Testing
@testable import CodexRunway

@Suite("Main panel appearance")
struct MainPanelAppearanceTests {
    @Test("main and detail panels paint an opaque background in both appearances")
    @MainActor
    func panelBackgroundDoesNotRevealTheDesktop() throws {
        for page in [MainPanelMockRender.Page.main, .apiCost] {
            for appearance in MainPanelMockRender.Appearance.allCases {
                let colors = try marginColors(page: page, appearance: appearance)
                for color in colors {
                    // An opaque panel has the same result over white and black
                    // windows. Do not supply an extra background in the renderer:
                    // it must capture the surface painted by the shipped root.
                    #expect(color.alphaComponent >= 0.99)
                }
            }
        }
    }

    @Test("main and detail panel backgrounds follow light and dark appearance")
    @MainActor
    func panelBackgroundFollowsAppearance() throws {
        for page in [MainPanelMockRender.Page.main, .apiCost] {
            let light = try #require(marginColors(page: page, appearance: .light).first)
            let dark = try #require(marginColors(page: page, appearance: .dark).first)

            // Check the theme relationship, not a particular macOS RGB value.
            #expect(luminance(light) > luminance(dark) + 0.25)
        }
    }

    @MainActor
    private func marginColors(
        page: MainPanelMockRender.Page,
        appearance: MainPanelMockRender.Appearance) throws -> [NSColor]
    {
        let data = try MainPanelMockRender.render(
            page: page,
            appearance: appearance,
            language: .simplifiedChinese)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide > 100)
        #expect(image.pixelsHigh > 100)

        // Both pages have 16-point horizontal content padding. Sample inside
        // that margin at several heights, clear of text and the resize handle.
        var colors: [NSColor] = []
        for xFraction in [0.02, 0.98] {
            for yFraction in [0.02, 0.5, 0.97] {
                let x = Int(Double(image.pixelsWide) * xFraction)
                let y = Int(Double(image.pixelsHigh) * yFraction)
                let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                colors.append(color)
            }
        }
        return colors
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
