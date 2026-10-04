import AppKit
import SwiftUI
import Testing
@testable import CodexRunway

@Suite("Polished scroll position")
struct PolishedScrollPositionTests {
    @Test("content refresh never temporarily expands the visible scroll document")
    @MainActor
    func contentRefreshKeepsDocumentAtFittedHeight() throws {
        let position = PolishedScrollPosition()
        let host = makeHost(position: position)
        settle(host)
        let scrollView = requireScrollView(in: host)
        let document = try #require(scrollView.documentView)
        let expectedHeight = document.frame.height
        #expect(expectedHeight > 180)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        let expectedOffset = scrollView.documentVisibleRect.minY

        let frames = DocumentFrameRecorder()
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            frames,
            selector: #selector(DocumentFrameRecorder.record(_:)),
            name: NSView.frameDidChangeNotification,
            object: document)
        defer { NotificationCenter.default.removeObserver(frames) }

        host.rootView = homeView(position: position, revision: 1)
        settle(host)

        #expect(scrollView === requireScrollView(in: host))
        #expect(abs(document.frame.height - expectedHeight) <= 1)
        #expect(abs(scrollView.documentVisibleRect.minY - expectedOffset) <= 1)
        #expect(
            frames.heights.allSatisfy { abs($0 - expectedHeight) <= 1 },
            "Content-only refresh must not move the live document through a measurement height: \(frames.heights)")
    }

    @Test("document follows growing and shrinking content without a probe height")
    @MainActor
    func documentHeightTracksContentChanges() throws {
        let position = PolishedScrollPosition()
        let host = makeHost(position: position)
        settle(host)
        let document = try #require(requireScrollView(in: host).documentView)

        for (revision, rowCount) in [60, 5, 40].enumerated() {
            host.rootView = homeView(position: position, revision: revision + 1, rowCount: rowCount)
            settle(host)
            #expect(abs(document.frame.height - CGFloat(rowCount * 28)) <= 1)
        }
    }

    @Test("width changes reflow long content to its fitted height")
    @MainActor
    func documentHeightTracksWrapping() throws {
        let host = NSHostingView(rootView: wrappingView(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        settle(host)
        let document = try #require(requireScrollView(in: host).documentView)
        let originalHeight = document.frame.height

        host.rootView = wrappingView(width: 180)
        host.setFrameSize(NSSize(width: 180, height: 180))
        settle(host)
        #expect(abs(document.frame.width - 180) <= 1)
        #expect(document.frame.height > originalHeight)

        host.rootView = wrappingView(width: 320)
        host.setFrameSize(NSSize(width: 320, height: 180))
        settle(host)
        #expect(abs(document.frame.width - 320) <= 1)
        #expect(abs(document.frame.height - originalHeight) <= 1)
    }

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
    private func homeView(
        position: PolishedScrollPosition,
        revision: Int = 0,
        rowCount: Int = 40) -> AnyView
    {
        AnyView(
            PolishedScrollView(
                verticalPadding: 0,
                fadesEdges: false,
                remasureToken: revision,
                scrollPosition: position)
            {
                VStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        Text("row \(row) revision \(revision)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 28)
                    }
                }
            }
            .frame(width: 320, height: 180))
    }

    @MainActor
    private func wrappingView(width: CGFloat) -> AnyView {
        AnyView(
            PolishedScrollView(verticalPadding: 0, fadesEdges: false) {
                Text(String(repeating: "Long localized section text that must wrap. ", count: 20))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: width, height: 180))
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

@MainActor
private final class DocumentFrameRecorder: NSObject {
    var heights: [CGFloat] = []

    @objc func record(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        heights.append(view.frame.height)
    }
}
