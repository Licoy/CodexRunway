import AppKit
import SwiftUI
import Testing
@testable import CodexRunway

@Suite("Polished scroll position")
struct PolishedScrollPositionTests {
    @Test("recreated scroll view restores position within one presentation")
    @MainActor
    func restoresPositionAfterDetailRoundTrip() {
        let position = PolishedScrollPosition()
        let host = makeHost(position: position)
        settle(host)

        let original = requireScrollView(in: host)
        original.contentView.scroll(to: NSPoint(x: 0, y: 180))
        original.reflectScrolledClipView(original.contentView)
        let expected = original.documentVisibleRect.minY
        #expect(expected > 0)

        host.rootView = AnyView(detailView)
        settle(host)
        #expect(collectScrollViews(in: host).isEmpty)
        host.rootView = homeView(position: position)
        settle(host)

        let restored = requireScrollView(in: host)
        #expect(restored !== original)
        #expect(abs(restored.documentVisibleRect.minY - expected) <= 1)
    }

    @Test("new presentation starts at the top")
    @MainActor
    func newPresentationStartsAtTop() {
        let oldPosition = PolishedScrollPosition()
        let host = makeHost(position: oldPosition)
        settle(host)

        let original = requireScrollView(in: host)
        original.contentView.scroll(to: NSPoint(x: 0, y: 180))
        original.reflectScrolledClipView(original.contentView)
        #expect(original.documentVisibleRect.minY > 0)

        let reopenedHost = makeHost(position: PolishedScrollPosition())
        settle(reopenedHost)

        let reopened = requireScrollView(in: reopenedHost)
        #expect(reopened !== original)
        #expect(abs(reopened.documentVisibleRect.minY) <= 1)
    }

    @MainActor
    private func makeHost(position: PolishedScrollPosition) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: homeView(position: position))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        return host
    }

    @MainActor
    private func homeView(position: PolishedScrollPosition) -> AnyView {
        AnyView(
            PolishedScrollView(
                verticalPadding: 0,
                fadesEdges: false,
                scrollPosition: position)
            {
                VStack(spacing: 0) {
                    ForEach(0..<40, id: \.self) { row in
                        Text("row \(row)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 28)
                    }
                }
            }
            .frame(width: 320, height: 180))
    }

    private var detailView: some View {
        Text("API cost detail")
            .frame(width: 320, height: 180)
    }

    @MainActor
    private func settle(_ host: NSHostingView<AnyView>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func requireScrollView(in host: NSView) -> NSScrollView {
        guard let scrollView = collectScrollViews(in: host).first else {
            Issue.record("Expected a scroll view")
            fatalError("Expected a scroll view")
        }
        return scrollView
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
