import AppKit
import SwiftUI

struct PolishedScrollView<Content: View>: View {
    private let content: Content
    private let verticalPadding: CGFloat
    /// Soft edge fade. Disable when a fixed toolbar sits above the scroll view so the first row is not washed out.
    private let fadesEdges: Bool

    init(verticalPadding: CGFloat = 8, fadesEdges: Bool = true, @ViewBuilder content: () -> Content) {
        self.verticalPadding = verticalPadding
        self.fadesEdges = fadesEdges
        self.content = content()
    }

    var body: some View {
        let scroll = HiddenScrollerScrollView {
            content
                .padding(.vertical, verticalPadding)
                .padding(.trailing, 4)
        }
        if fadesEdges {
            scroll.mask(verticalFade)
        } else {
            scroll
        }
    }

    private var verticalFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
        }
    }
}

private struct HiddenScrollerScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// The nested NSHostingView is a separate SwiftUI root: custom environment keys do
    /// not cross it, so the panel-visibility flag that pauses shimmer timelines must be
    /// re-injected from the outer tree.
    private func rootView(_ context: Context) -> AnyView {
        AnyView(content.environment(\.runwayPanelVisible, context.environment.runwayPanelVisible))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SizingScrollView()
        let hostingView = NSHostingView(rootView: rootView(context))
        hostingView.isFlipped = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = hostingView
        scrollView.onLayout = { [weak scrollView, weak hostingView] in
            guard let scrollView, let hostingView else { return }
            resize(hostingView, in: scrollView, coordinator: context.coordinator, force: false)
        }
        resize(hostingView, in: scrollView, coordinator: context.coordinator, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<AnyView> else { return }
        hostingView.rootView = rootView(context)
        // Model refreshes publish in bursts; a full height probe costs several layout
        // passes of the whole panel, so coalesce probes instead of paying one per publish.
        let coordinator = context.coordinator
        coordinator.throttleProbe { [weak scrollView, weak hostingView] in
            guard let scrollView, let hostingView else { return }
            resize(hostingView, in: scrollView, coordinator: coordinator, force: true)
        }
    }

    private func resize(
        _ hostingView: NSView,
        in scrollView: NSScrollView,
        coordinator: Coordinator,
        force: Bool)
    {
        let width = max(1, scrollView.contentSize.width)
        // Bounded probe height: large enough for the panel, cheap vs. 1_000_000.
        let probeHeight: CGFloat = 8_000
        let widthChanged = abs(coordinator.lastWidth - width) > 0.5
        if !force && !widthChanged && coordinator.lastHeight > 0 {
            return
        }

        hostingView.setFrameSize(NSSize(width: width, height: probeHeight))
        hostingView.layoutSubtreeIfNeeded()
        let height = max(1, hostingView.fittingSize.height)

        // Skip frame writes when nothing meaningful changed (avoids layout thrash).
        if abs(coordinator.lastWidth - width) < 0.5,
           abs(coordinator.lastHeight - height) < 0.5,
           abs(hostingView.frame.height - height) < 0.5
        {
            coordinator.lastWidth = width
            coordinator.lastHeight = height
            return
        }

        hostingView.setFrameSize(NSSize(width: width, height: height))
        coordinator.lastWidth = width
        coordinator.lastHeight = height
    }

    @MainActor
    final class Coordinator {
        var lastWidth: CGFloat = 0
        var lastHeight: CGFloat = 0

        private let probeInterval: TimeInterval = 0.1
        private var lastProbeAt: Date?
        private var pendingProbe: (() -> Void)?

        /// Leading + trailing throttle: probe immediately when idle, and collapse a
        /// publish burst into a single trailing probe.
        func throttleProbe(_ probe: @escaping () -> Void) {
            let now = Date()
            if let lastProbeAt, now.timeIntervalSince(lastProbeAt) < probeInterval {
                let alreadyScheduled = pendingProbe != nil
                pendingProbe = probe
                guard !alreadyScheduled else { return }
                let delay = probeInterval - now.timeIntervalSince(lastProbeAt)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    self.lastProbeAt = Date()
                    let pending = self.pendingProbe
                    self.pendingProbe = nil
                    pending?()
                }
                return
            }
            lastProbeAt = now
            probe()
        }
    }
}

private final class SizingScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
