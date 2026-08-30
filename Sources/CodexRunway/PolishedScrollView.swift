import AppKit
import SwiftUI

/// Transient vertical position shared by scroll views that are recreated inside one
/// presentation. The value is intentionally not published: capturing a position while
/// a view is dismantled must not trigger a redraw of the surrounding SwiftUI tree.
@MainActor
final class PolishedScrollPosition: ObservableObject {
    fileprivate var verticalOffset: CGFloat = 0
}

struct PolishedScrollView<Content: View>: View {
    private let content: Content
    private let verticalPadding: CGFloat
    /// Soft edge fade. Disable when a fixed toolbar sits above the scroll view so the first row is not washed out.
    private let fadesEdges: Bool
    /// Changing this token forces an immediate document remasure (e.g. language switch).
    private let remasureToken: AnyHashable
    /// Thin overlay knob that fades away when idle. Off for the popover, on for settings.
    private let showsOverlayScroller: Bool
    /// Optional position whose lifetime is owned by the caller.
    private let scrollPosition: PolishedScrollPosition?

    init(
        verticalPadding: CGFloat = 8,
        fadesEdges: Bool = true,
        remasureToken: AnyHashable = 0,
        showsOverlayScroller: Bool = false,
        scrollPosition: PolishedScrollPosition? = nil,
        @ViewBuilder content: () -> Content)
    {
        self.verticalPadding = verticalPadding
        self.fadesEdges = fadesEdges
        self.remasureToken = remasureToken
        self.showsOverlayScroller = showsOverlayScroller
        self.scrollPosition = scrollPosition
        self.content = content()
    }

    var body: some View {
        let scroll = HiddenScrollerScrollView(
            remasureToken: remasureToken,
            showsOverlayScroller: showsOverlayScroller,
            scrollPosition: scrollPosition)
        {
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
    let remasureToken: AnyHashable
    let showsOverlayScroller: Bool
    let scrollPosition: PolishedScrollPosition?

    init(
        remasureToken: AnyHashable,
        showsOverlayScroller: Bool,
        scrollPosition: PolishedScrollPosition?,
        @ViewBuilder content: () -> Content)
    {
        self.remasureToken = remasureToken
        self.showsOverlayScroller = showsOverlayScroller
        self.scrollPosition = scrollPosition
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollPosition: scrollPosition)
    }

    /// The nested NSHostingView is a separate SwiftUI root: custom environment keys do
    /// not cross it, so the panel-visibility flag that pauses shimmer timelines must be
    /// re-injected from the outer tree.
    private func rootView(_ context: Context, width: CGFloat) -> AnyView {
        AnyView(
            content
                .environment(\.runwayPanelVisible, context.environment.runwayPanelVisible)
                .frame(width: max(1, width), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SizingScrollView()
        rememberRootBuilder(context)
        let hostingView = NSHostingView(rootView: rootView(context, width: 1))
        hostingView.isFlipped = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.scrollerStyle = .overlay
        applyScroller(scrollView)
        scrollView.documentView = hostingView
        scrollView.onLayout = { [weak scrollView, weak hostingView] in
            guard let scrollView, let hostingView else { return }
            resize(hostingView, in: scrollView, coordinator: context.coordinator, force: false)
            restoreScrollPosition(in: scrollView, coordinator: context.coordinator)
        }
        resize(hostingView, in: scrollView, coordinator: context.coordinator, force: true)
        restoreScrollPosition(in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<AnyView> else { return }
        applyScroller(scrollView)
        let coordinator = context.coordinator
        rememberRootBuilder(context)
        let languageChanged = coordinator.lastRemasureToken != remasureToken
        coordinator.lastRemasureToken = remasureToken
        let width = max(1, scrollView.contentSize.width)
        hostingView.rootView = rootView(context, width: width)
        // Model refreshes publish in bursts; a full height probe costs several layout
        // passes of the whole panel, so coalesce probes instead of paying one per publish.
        // Language (or other remasure token) changes must remasure immediately so
        // longer strings wrap and grow instead of staying clipped at the old height.
        if languageChanged {
            resize(hostingView, in: scrollView, coordinator: coordinator, force: true)
            restoreScrollPosition(in: scrollView, coordinator: coordinator)
            return
        }
        coordinator.throttleProbe { [weak scrollView, weak hostingView] in
            guard let scrollView, let hostingView else { return }
            resize(hostingView, in: scrollView, coordinator: coordinator, force: true)
            restoreScrollPosition(in: scrollView, coordinator: coordinator)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let scrollPosition = coordinator.scrollPosition else { return }
        scrollPosition.verticalOffset = clampedVerticalOffset(
            scrollView.documentVisibleRect.minY,
            in: scrollView)
    }

    private func applyScroller(_ scrollView: NSScrollView) {
        if let sizing = scrollView as? SizingScrollView {
            sizing.forceOverlayScroller = showsOverlayScroller
        }
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        if showsOverlayScroller {
            scrollView.hasVerticalScroller = true
            if !(scrollView.verticalScroller is ThinOverlayScroller) {
                let scroller = ThinOverlayScroller()
                scroller.controlSize = .regular
                scroller.scrollerStyle = .overlay
                scrollView.verticalScroller = scroller
            } else {
                scrollView.verticalScroller?.scrollerStyle = .overlay
            }
        } else {
            scrollView.hasVerticalScroller = false
        }
    }

    private func rememberRootBuilder(_ context: Context) {
        let visible = context.environment.runwayPanelVisible
        let body = content
        context.coordinator.makeRoot = { width in
            AnyView(
                body
                    .environment(\.runwayPanelVisible, visible)
                    .frame(width: max(1, width), alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true))
        }
    }

    private func resize(
        _ hostingView: NSView,
        in scrollView: NSScrollView,
        coordinator: Coordinator,
        force: Bool)
    {
        let width = max(1, scrollView.contentSize.width)
        if let typed = hostingView as? NSHostingView<AnyView>, let makeRoot = coordinator.makeRoot {
            // Keep the SwiftUI tree pinned to the scroll width so English / long
            // locales wrap instead of measuring an unconstrained fitting width.
            typed.rootView = makeRoot(width)
        }
        // Bounded probe height: large enough for the panel, cheap vs. 1_000_000.
        let probeHeight: CGFloat = 8_000
        let widthChanged = abs(coordinator.lastWidth - width) > 0.5
        if !force && !widthChanged && coordinator.lastHeight > 0 {
            return
        }

        hostingView.setFrameSize(NSSize(width: width, height: probeHeight))
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = max(1, fitting.height)

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

    private func restoreScrollPosition(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard coordinator.needsScrollRestore, let scrollPosition = coordinator.scrollPosition else { return }
        let viewportHeight = scrollView.contentSize.height
        guard viewportHeight > 0, scrollView.documentView != nil else { return }

        let offset = Self.clampedVerticalOffset(scrollPosition.verticalOffset, in: scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollPosition.verticalOffset = offset
        coordinator.needsScrollRestore = false
    }

    private static func clampedVerticalOffset(_ offset: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximumOffset = max(0, documentHeight - scrollView.contentSize.height)
        return min(max(0, offset), maximumOffset)
    }

    @MainActor
    final class Coordinator {
        let scrollPosition: PolishedScrollPosition?
        var needsScrollRestore: Bool
        var lastWidth: CGFloat = 0
        var lastHeight: CGFloat = 0
        var lastRemasureToken: AnyHashable?
        var makeRoot: ((CGFloat) -> AnyView)?

        private let probeInterval: TimeInterval = 0.1
        private var lastProbeAt: Date?
        private var pendingProbe: (() -> Void)?

        init(scrollPosition: PolishedScrollPosition?) {
            self.scrollPosition = scrollPosition
            self.needsScrollRestore = scrollPosition != nil
        }

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
    var forceOverlayScroller = false

    override var scrollerStyle: NSScroller.Style {
        get { forceOverlayScroller ? .overlay : super.scrollerStyle }
        set { super.scrollerStyle = forceOverlayScroller ? .overlay : newValue }
    }

    override func layout() {
        super.layout()
        if forceOverlayScroller, super.scrollerStyle != .overlay {
            super.scrollerStyle = .overlay
        }
        onLayout?()
    }
}

/// Overlay knob used by settings: 3pt wide, no track, fades with AppKit overlay.
final class ThinOverlayScroller: NSScroller {
    static let slotWidth: CGFloat = 7
    static let knobWidth: CGFloat = 3

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style) -> CGFloat
    {
        slotWidth
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob)
        let insetX = max(0, (bounds.width - Self.knobWidth) / 2)
        knob = NSRect(
            x: bounds.minX + insetX,
            y: knob.minY + 1,
            width: Self.knobWidth,
            height: max(Self.knobWidth, knob.height - 2))
        let path = NSBezierPath(
            roundedRect: knob,
            xRadius: Self.knobWidth / 2,
            yRadius: Self.knobWidth / 2)
        Self.knobFill(for: effectiveAppearance).setFill()
        path.fill()
    }

    static func knobFill(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.36)
            : NSColor.black.withAlphaComponent(0.22)
    }
}
