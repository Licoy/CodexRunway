import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Control panel scrollers")
struct ControlPanelScrollTests {
    @Test("overlay knob is thin and switches fill for light and dark")
    @MainActor
    func overlayKnobAdaptsToAppearance() {
        #expect(ThinOverlayScroller.knobWidth < 5)
        #expect(ThinOverlayScroller.slotWidth <= 8)
        #expect(
            ThinOverlayScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
                == ThinOverlayScroller.slotWidth)
        #expect(ThinOverlayScroller.isCompatibleWithOverlayScrollers)

        let light = ThinOverlayScroller.knobFill(for: NSAppearance(named: .aqua)!)
            .usingColorSpace(.sRGB)
        let dark = ThinOverlayScroller.knobFill(for: NSAppearance(named: .darkAqua)!)
            .usingColorSpace(.sRGB)
        #expect(light != nil)
        #expect(dark != nil)
        #expect(light!.redComponent < 0.15)
        #expect(light!.alphaComponent > 0.1 && light!.alphaComponent < 0.35)
        #expect(dark!.redComponent > 0.85)
        #expect(dark!.alphaComponent > 0.2 && dark!.alphaComponent < 0.5)
    }

    @Test("settings panes install an autohiding overlay scroller")
    @MainActor
    func settingsScrollViewUsesThinOverlay() {
        let host = NSHostingView(rootView: PreferencesPane {
            ForEach(0..<24, id: \.self) { index in
                Text("row \(index)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        })
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: ControlPanelLayout.minimumPanelWidth,
            height: 320)
        host.layoutSubtreeIfNeeded()
        if host.fittingSize.width <= 1 {
            return
        }
        let scrollViews = collectScrollViews(in: host)
        #expect(!scrollViews.isEmpty)
        for scrollView in scrollViews {
            #expect(scrollView.scrollerStyle == .overlay)
            #expect(scrollView.autohidesScrollers)
            #expect(scrollView.hasVerticalScroller)
            #expect(scrollView.verticalScroller is ThinOverlayScroller)
            #expect(!scrollView.hasHorizontalScroller)
        }
    }

    @MainActor
    private func collectScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            found.append(scrollView)
        }
        for child in view.subviews {
            found.append(contentsOf: collectScrollViews(in: child))
        }
        return found
    }
}
