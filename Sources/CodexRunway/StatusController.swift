import AppKit
import CodexRunwayCore
import Combine
import SwiftUI

struct RunwayWidgetReloadGate {
    private(set) var allowsReload: Bool

    init(initiallyAllowed: Bool) {
        allowsReload = initiallyAllowed
    }

    mutating func open() {
        allowsReload = true
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private var widgetReloadGate: RunwayWidgetReloadGate
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusBarView = StatusBarContentView(frame: .zero)
    private let popover = NSPopover()
    let settings = RunwaySettings()
    lazy var model = RunwayModel(settings: settings, grokModule: GrokAccountModule())
    private lazy var updaterService = UpdaterService(settings: settings)
    /// Drives pause of panel-only animations while the main panel is hidden.
    let mainPanelVisibility = MainPanelVisibility()
    private var statusMenu: NSMenu?
    private var detailsWindow: NSWindow?
    private var controlPanelWindow: NSWindow?
    private var eventMonitor: Any?
    private var localPopoverCloseMonitor: Any?
    private var globalPopoverCloseMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var lastQuotaResetRefresh: Date?
    private var refreshSchedule = RefreshSchedule()
    private var widgetRefreshSchedule = RefreshSchedule()
    private var widgetRefreshPending = false
    private var timer: Timer?
    private var widgetCoordinator: RunwayWidgetCoordinator?
    private var widgetSnapshotCancellable: AnyCancellable?
    private var liveMainPanelHeight: CGFloat?
    private var mainPanelResizeTopEdge: CGFloat?

    init(initialWidgetReloadAllowed: Bool = true) {
        self.widgetReloadGate = RunwayWidgetReloadGate(
            initiallyAllowed: initialWidgetReloadAllowed)
        super.init()
    }

    func start() {
        let button = statusItem.button
        button?.toolTip = "CodexRunway"
        button?.target = self
        button?.action = #selector(handleStatusItemClick(_:))
        button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        installStatusBarView()
        model.onFullRefreshCompleted = { [weak self] in
            self?.fullRefreshCompleted()
        }
        configureWidgets()
        settings.onChange = { [weak self] in
            self?.applyAppearance()
            self?.model.relabel()
            self?.updaterService.applyPreferences()
            self?.refreshIntervalChanged()
            self?.rebuildHostedViews()
            self?.updateStatusBarView()
            self?.publishWidgetSnapshot(force: true)
        }
        updaterService.applyPreferences()
        applyAppearance()
        // applicationDefined: dismiss is owned by status-item toggle + outside-click monitors.
        // .transient fights makeKey (second status-item click auto-dismisses then re-opens).
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = mainPanelContentSize()
        // No hosting yet: showPopover builds a fresh tree per open, and while hidden no
        // SwiftUI tree stays alive subscribed to model publishes.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                // Full teardown: dismiss any sheet, hide panel, rebuild hosting.
                self?.closeMainPanel()
            }
        }
        installEventMonitor()
        let tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // Menu-bar text is minute-granular; tolerance lets the system coalesce wakeups.
        tickTimer.tolerance = 0.2
        timer = tickTimer
        beginFullRefresh(
            policy: .ifChanged,
            refreshWidgets: hasActiveWidgets)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let activation = StatusItemActivation.current else { return }
        handleStatusEvent(activation.mouseButton, relativeTo: sender)
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Use screen-space hit testing too: when the popover is key, event.window
            // can be unreliable for the status item.
            guard self.eventHitsStatusButton(event) || self.eventHitsStatusButtonScreen(event) else {
                return event
            }
            if event.modifierFlags.contains(.command) { return event }
            self.handleStatusEvent(Self.mouseButton(from: event), relativeTo: self.statusItem.button)
            return nil
        }
    }

    private func tick() {
        let now = Date()
        let refreshWidgets = hasActiveWidgets && widgetRefreshSchedule.isDue(at: now)
        model.tick(now: now)
        updateStatusBarView()
        if let reset = model.nextDueQuotaReset(after: lastQuotaResetRefresh, now: now), !model.isRefreshing {
            lastQuotaResetRefresh = reset
            beginFullRefresh(policy: .ifChanged, refreshWidgets: refreshWidgets)
            return
        }
        if (refreshSchedule.isDue(at: now) || refreshWidgets), !model.isRefreshing {
            beginFullRefresh(policy: .ifChanged, refreshWidgets: refreshWidgets)
        }
    }

    private func beginFullRefresh(
        policy: UsageCostRefreshPolicy,
        refreshWidgets: Bool = false
    ) {
        guard !model.isRefreshing else { return }
        if refreshWidgets {
            widgetRefreshPending = true
            widgetRefreshSchedule.refreshStarted()
        }
        refreshSchedule.refreshStarted()
        model.refresh(policy: policy)
    }

    private func fullRefreshCompleted(at completion: Date = Date()) {
        refreshSchedule.refreshCompleted(at: completion, interval: refreshInterval)
        let refreshWidgets = hasActiveWidgets
            && (widgetRefreshPending || widgetRefreshSchedule.isDue(at: completion))
        widgetRefreshPending = false
        if refreshWidgets {
            widgetRefreshSchedule.refreshCompleted(
                at: completion,
                interval: widgetRefreshInterval)
        }
        widgetCoordinator?.refreshConfigurations()
        let reloadTimelines = widgetReloadGate.allowsReload
        let publication = publishWidgetSnapshot(
            force: refreshWidgets,
            reloadTimelines: reloadTimelines)
        if !reloadTimelines, let publication {
            Task { @MainActor [weak self] in
                await publication.value
                self?.widgetReloadGate.open()
            }
        }
    }

    private func configureWidgets() {
        guard #available(macOS 14.0, *), let coordinator = RunwayWidgetCoordinator() else { return }
        widgetCoordinator = coordinator
        model.widgetRequirements = coordinator.initialRequirements
        coordinator.onRequirementsChanged = { [weak self] requirements in
            guard let self, self.model.widgetRequirements != requirements else { return }
            self.model.widgetRequirements = requirements
            self.refreshIntervalChanged()
            if !requirements.isEmpty {
                self.beginFullRefresh(policy: .ifChanged, refreshWidgets: true)
            }
        }
        widgetSnapshotCancellable = model.objectWillChange
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.publishWidgetSnapshot(force: false) }
        }
        coordinator.refreshConfigurations()
        publishWidgetSnapshot(force: true)
    }

    @discardableResult
    private func publishWidgetSnapshot(
        force: Bool,
        reloadTimelines: Bool? = nil
    ) -> Task<Void, Never>? {
        widgetCoordinator?.publish(
            model.makeWidgetSnapshot(),
            force: force,
            reloadTimelines: reloadTimelines ?? widgetReloadGate.allowsReload,
            minimumReloadInterval: widgetRefreshInterval)
    }

    private func refreshIntervalChanged(now: Date = Date()) {
        refreshSchedule.intervalChanged(to: refreshInterval, now: now)
        guard hasActiveWidgets else {
            widgetRefreshSchedule = RefreshSchedule()
            widgetRefreshPending = false
            return
        }
        widgetRefreshSchedule.intervalChanged(to: widgetRefreshInterval, now: now)
    }

    private var refreshInterval: TimeInterval {
        TimeInterval(settings.preferences.refreshIntervalSeconds)
    }

    private var widgetRefreshInterval: TimeInterval {
        TimeInterval(settings.preferences.widgetRefreshIntervalSeconds)
    }

    private var hasActiveWidgets: Bool {
        !model.widgetRequirements.isEmpty
    }

    private func applyAppearance() {
        let appearance: NSAppearance?
        switch settings.preferences.appearance {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        // loadedPopoverWindow: touching .view would force-load a hidden hosting tree.
        loadedPopoverWindow?.appearance = appearance
        detailsWindow?.appearance = appearance
        controlPanelWindow?.appearance = appearance
    }

    private func rebuildHostedViews() {
        let wasVisible = isMainPanelVisible
        // While the status-item popover is visible, never replace its content VC.
        // Swapping NSHostingController (e.g. after chart-style preference writes)
        // detaches the popover from the status button and leaves a thin sliver at
        // the top of the screen. RunwayPopoverView already observes settings and
        // redraws in place. Drop hosting only when hidden so the next open is fresh.
        if !popover.isShown {
            popover.contentViewController = nil
        } else {
            // Keep size pinned even if SwiftUI layout thrash tries to shrink it.
            pinPopoverContentSize()
            reanchorPopoverIfShown()
        }
        if let detailsWindow {
            if detailsWindow.isVisible {
                // Normal NSWindow is safe to refresh; not anchored like NSPopover.
                detailsWindow.contentViewController = makePopoverHostingController()
                detailsWindow.title = "CodexRunway"
            } else {
                detailsWindow.contentViewController = nil
            }
        }
        mainPanelVisibility.isVisible = wasVisible
        if let controlPanelWindow {
            let didResize = ControlPanelLayout.applyWindowLayout(
                controlPanelWindow,
                title: settings.l10n.text(.controlPanel),
                titles: controlPanelTabTitles)
            if didResize {
                centerControlPanel(controlPanelWindow)
            }
        }
    }

    private func popoverRootView() -> RunwayPopoverRootView {
        RunwayPopoverRootView(
            model: model,
            settings: settings,
            mainPanelVisibility: mainPanelVisibility,
            checkForUpdates: { [weak self] in self?.updaterService.checkForUpdates() },
            openGitHub: { ExternalURLLauncher.open(ControlPanelView.githubURL) },
            openControlPanel: { [weak self] tab in self?.showControlPanel(tab: tab) },
            initialPanelHeight: preferredMainPanelHeight,
            resizeMainPanel: { [weak self] height, shouldPersist in
                self?.resizeMainPanel(to: height, persist: shouldPersist)
                    ?? MainPanelLayout.clampedHeight(height)
            })
    }

    private func makePopoverHostingController() -> NSHostingController<RunwayPopoverRootView> {
        let controller = NSHostingController(rootView: popoverRootView())
        controller.preferredContentSize = mainPanelContentSize()
        return controller
    }

    private func pinPopoverContentSize() {
        let size = mainPanelContentSize()
        popover.contentSize = size
        if let controller = popover.contentViewController {
            controller.preferredContentSize = size
        }
    }

    private var preferredMainPanelHeight: CGFloat {
        resolvedMainPanelHeight(
            liveMainPanelHeight ?? CGFloat(settings.preferences.mainPanelHeight))
    }

    private var availableMainPanelScreenHeight: CGFloat? {
        let screen = loadedPopoverWindow?.screen
            ?? detailsWindow?.screen
            ?? statusItem.button?.window?.screen
            ?? NSScreen.main
        return screen?.visibleFrame.height
    }

    private func resolvedMainPanelHeight(_ proposedHeight: CGFloat) -> CGFloat {
        MainPanelLayout.alignedHeight(
            MainPanelLayout.clampedHeight(
                proposedHeight,
                availableScreenHeight: availableMainPanelScreenHeight))
    }

    private func mainPanelContentSize(height: CGFloat? = nil) -> NSSize {
        MainPanelLayout.contentSize(
            height: height ?? preferredMainPanelHeight,
            availableScreenHeight: availableMainPanelScreenHeight)
    }

    @discardableResult
    private func resizeMainPanel(to proposedHeight: CGFloat, persist: Bool) -> CGFloat {
        let height = resolvedMainPanelHeight(proposedHeight)
        let currentHeight = liveMainPanelHeight ?? preferredMainPanelHeight
        captureMainPanelResizeTopEdgeIfNeeded()

        if height != currentHeight {
            liveMainPanelHeight = height
            let size = mainPanelContentSize(height: height)

            popover.contentSize = size
            popover.contentViewController?.preferredContentSize = size
            if let window = loadedPopoverWindow, let topEdge = mainPanelResizeTopEdge {
                keepWindowTopEdge(window, at: topEdge)
            }
            if let detailsWindow, detailsWindow.isVisible {
                resizeDetailsWindow(
                    detailsWindow,
                    contentSize: size,
                    topEdge: mainPanelResizeTopEdge)
            }
        }

        if persist {
            settings.updateMainPanelHeight(liveMainPanelHeight ?? currentHeight)
            mainPanelResizeTopEdge = nil
        }
        return liveMainPanelHeight ?? currentHeight
    }

    private func captureMainPanelResizeTopEdgeIfNeeded() {
        guard mainPanelResizeTopEdge == nil else { return }
        if let window = loadedPopoverWindow {
            mainPanelResizeTopEdge = window.frame.maxY
        } else if let detailsWindow, detailsWindow.isVisible {
            mainPanelResizeTopEdge = detailsWindow.frame.maxY
        }
    }

    private func keepWindowTopEdge(_ window: NSWindow, at topEdge: CGFloat) {
        let frame = MainPanelLayout.frameKeepingTopEdge(
            window.frame,
            size: window.frame.size,
            topEdge: topEdge)
        guard frame.origin != window.frame.origin else { return }
        window.setFrameOrigin(frame.origin)
    }

    /// The resize handle represents the bottom edge, so keep a fallback window's
    /// top edge fixed while its bottom follows the pointer.
    private func resizeDetailsWindow(
        _ window: NSWindow,
        contentSize: NSSize,
        topEdge: CGFloat? = nil
    ) {
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let frameSize = window.frameRect(forContentRect: contentRect).size
        let frame = MainPanelLayout.frameKeepingTopEdge(
            window.frame,
            size: frameSize,
            topEdge: topEdge ?? window.frame.maxY)
        window.setFrame(frame, display: true)
    }

    /// Re-show relative to the status button after any geometry glitch.
    private func reanchorPopoverIfShown() {
        guard popover.isShown, let button = statusItem.button else { return }
        pinPopoverContentSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPopoverWindow()
    }

    private func eventHitsStatusButton(_ event: NSEvent) -> Bool {
        // NSStatusBarWindow includes the button plus the system's side margins.
        event.window === statusItem.button?.window
    }

    private func handleStatusEvent(_ mouseButton: StatusMouseButton, relativeTo button: NSStatusBarButton?) {
        let panelShown = isMainPanelVisible
        switch StatusInteraction.route(mouseButton: mouseButton, isPopoverShown: panelShown) {
        case .showMenu:
            if let button { showMenu(relativeTo: button) }
        case .showPopover:
            showPopover()
        case .closePopover:
            closeMainPanel()
        }
    }

    private var isMainPanelVisible: Bool {
        popover.isShown || (detailsWindow?.isVisible == true)
    }

    /// Window of the popover content without force-loading a hidden hosting tree
    /// (`viewIfLoaded` needs macOS 14; `isViewLoaded` covers the 12.0 floor).
    private var loadedPopoverWindow: NSWindow? {
        guard let controller = popover.contentViewController, controller.isViewLoaded else { return nil }
        return controller.view.window
    }

    private func closeMainPanel() {
        // Always destroy sheets first, then hide hosts, then drop hosting so the
        // next open never reuses a half-dismissed SwiftUI presentation.
        closePopover()
        closeDetailsWindow()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        // Visible before show so the first frame already renders with shimmer unpaused;
        // fresh hosting per open (dropped on close) keeps presentation state clean.
        mainPanelVisibility.isVisible = true
        liveMainPanelHeight = resolvedMainPanelHeight(
            CGFloat(settings.preferences.mainPanelHeight))
        if popover.contentViewController == nil {
            popover.contentViewController = makePopoverHostingController()
        }
        pinPopoverContentSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if !popover.isShown {
            showDetailsWindow()
            return
        }
        applyAppearance()
        // Key focus for active controls; safe with applicationDefined + custom dismiss.
        focusPopoverWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.pinPopoverContentSize()
            self.focusPopoverWindow()
        }
        startPopoverCloseMonitors()
        refreshVisiblePopoverSections()
    }

    private func focusPopoverWindow() {
        guard popover.isShown, let window = loadedPopoverWindow else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Prefer makeKey over makeKeyAndOrderFront once shown: keeps popover ordering stable.
        window.makeKey()
        window.orderFront(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        mainPanelVisibility.isVisible = false
        stopPopoverCloseMonitors()
        // Destroy sheet + hosting state so the next open is clean.
        destroyMainPanelPresentation()
    }

    private func startPopoverCloseMonitors() {
        stopPopoverCloseMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localPopoverCloseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self else { return event }
            // Escape-like: status-button hits are handled by the toggle path (eventMonitor).
            if self.shouldClosePopover(for: event) {
                self.closePopover()
            }
            return event
        }
        // Global monitor covers clicks outside this process (desktop / other apps).
        // Accessory apps often do not resign active on empty desktop clicks.
        globalPopoverCloseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                if self.shouldClosePopover(for: event) {
                    self.closePopover()
                }
            }
        }
    }

    private func stopPopoverCloseMonitors() {
        if let localPopoverCloseMonitor {
            NSEvent.removeMonitor(localPopoverCloseMonitor)
            self.localPopoverCloseMonitor = nil
        }
        if let globalPopoverCloseMonitor {
            NSEvent.removeMonitor(globalPopoverCloseMonitor)
            self.globalPopoverCloseMonitor = nil
        }
    }

    private func shouldClosePopover(for event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        // Clicks on the confirm sheet count as hits on the panel family (keep open).
        // Clicks outside destroy the sheet with the panel via closePopover().
        return StatusInteraction.shouldClosePopover(
            hitStatusButton: eventHitsStatusButton(event) || eventHitsStatusButtonScreen(event),
            hitPopover: eventHitsPopover(event))
    }

    private func eventHitsPopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = loadedPopoverWindow else { return false }
        if eventBelongsToWindowFamily(event.window, root: popoverWindow) { return true }
        // Global monitors may not attach event.window; fall back to screen coordinates.
        let screenPoint = NSEvent.mouseLocation
        if popoverWindow.frame.contains(screenPoint) { return true }
        return sheetFrames(of: popoverWindow).contains { $0.contains(screenPoint) }
    }

    /// True when the event window is the panel or one of its sheets/children.
    private func eventBelongsToWindowFamily(_ window: NSWindow?, root: NSWindow) -> Bool {
        guard let window else { return false }
        if window === root { return true }
        if window.sheetParent === root { return true }
        if root.attachedSheet === window { return true }
        if root.sheets.contains(where: { $0 === window }) { return true }
        if root.childWindows?.contains(where: { $0 === window }) == true { return true }
        return false
    }

    private func sheetFrames(of window: NSWindow) -> [NSRect] {
        var frames: [NSRect] = window.sheets.map(\.frame)
        if let attached = window.attachedSheet {
            frames.append(attached.frame)
        }
        return frames
    }

    /// Tear down any AppKit/SwiftUI sheets attached to the main panel window.
    private func dismissPresentedSheets(on window: NSWindow?) {
        guard let window else { return }
        // End highest sheet first; bound iterations so a stubborn sheet cannot hang.
        for _ in 0..<8 {
            guard let sheet = window.attachedSheet ?? window.sheets.last else { break }
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        // SwiftUI sheets may also appear as child windows of the host.
        for child in window.childWindows ?? [] where child.isSheet || child.sheetParent === window {
            child.orderOut(nil)
        }
    }

    /// After the main panel is hidden: destroy sheets and drop the hosted trees. The
    /// next open builds a fresh tree, so it can never reuse half-dismissed SwiftUI
    /// presentation state (e.g. account switch sheet) — and while hidden no tree stays
    /// alive subscribed to model publishes (assigning a controller to the hidden
    /// details window would load it immediately and keep it re-rendering off screen).
    private func destroyMainPanelPresentation() {
        dismissPresentedSheets(on: loadedPopoverWindow)
        dismissPresentedSheets(on: detailsWindow)
        mainPanelVisibility.isVisible = false
        statusItem.button?.highlight(false)
        popover.contentViewController = nil
        detailsWindow?.contentViewController = nil
        liveMainPanelHeight = nil
        mainPanelResizeTopEdge = nil
    }

    private func eventHitsStatusButtonScreen(_ event: NSEvent) -> Bool {
        guard let buttonWindow = statusItem.button?.window else { return false }
        if event.window === buttonWindow {
            return true
        }
        return buttonWindow.frame.contains(NSEvent.mouseLocation)
    }

    private func closePopover() {
        guard popover.isShown else { return }
        // Destroy confirm sheet before hiding the host, then tear down in popoverDidClose.
        dismissPresentedSheets(on: loadedPopoverWindow)
        mainPanelVisibility.isVisible = false
        popover.performClose(nil)
        if popover.isShown {
            // performClose can no-op; force close so the delegate teardown still runs.
            popover.close()
        }
        if popover.isShown {
            stopPopoverCloseMonitors()
            destroyMainPanelPresentation()
        }
    }

    private func showDetailsWindow() {
        liveMainPanelHeight = resolvedMainPanelHeight(
            CGFloat(settings.preferences.mainPanelHeight))
        let contentSize = mainPanelContentSize()
        let isNew = detailsWindow == nil
        let window = detailsWindow ?? NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexRunway"
        window.level = .floating
        window.isReleasedWhenClosed = false
        // Title-bar close must run the same teardown as outside-clicks, or the
        // hosted tree (and its 30fps sheen timers) survives behind a closed window.
        window.delegate = self
        window.contentViewController = makePopoverHostingController()
        detailsWindow = window
        if !isNew {
            resizeDetailsWindow(window, contentSize: contentSize)
        }
        mainPanelVisibility.isVisible = true
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        if isNew || !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.detailsWindow, window.isVisible else { return }
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKey()
            window.orderFront(nil)
        }
        startDetailsWindowCloseMonitors()
        refreshVisiblePopoverSections()
    }

    func openWidget(_ link: RunwayWidgetDeepLink) {
        switch link.provider {
        case .codex:
            model.selectProvider(.codex)
        case .grok:
            model.selectProvider(.grok)
        case .both:
            break
        }
        showDetailsWindow()
        switch link.section {
        case .overview:
            beginFullRefresh(policy: .ifChanged, refreshWidgets: hasActiveWidgets)
        case .quota:
            model.refreshQuota()
        case .tokens:
            if model.selectedProvider == .grok {
                model.refreshGrokLocalUsage()
            } else {
                model.refreshTokenHeatmap(policy: .ifChanged)
            }
        case .cost:
            if model.selectedProvider == .grok {
                model.refreshGrokLocalUsage()
            } else {
                model.refreshCost(policy: .ifChanged)
            }
        case .resetToday:
            model.selectProvider(.codex)
            model.refreshRateLimitResetToday(force: true)
        }
    }

    private func startDetailsWindowCloseMonitors() {
        // Reuse the same monitors: close details window when clicking outside.
        stopPopoverCloseMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localPopoverCloseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self else { return event }
            if self.shouldCloseDetailsWindow(for: event) {
                self.closeDetailsWindow()
            }
            return event
        }
        globalPopoverCloseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                if self.shouldCloseDetailsWindow(for: event) {
                    self.closeDetailsWindow()
                }
            }
        }
    }

    private func shouldCloseDetailsWindow(for event: NSEvent) -> Bool {
        guard let detailsWindow, detailsWindow.isVisible else { return false }
        if eventHitsStatusButton(event) || eventHitsStatusButtonScreen(event) { return false }
        // Sheet clicks stay open; outside clicks close + destroy presentation.
        if eventBelongsToWindowFamily(event.window, root: detailsWindow) { return false }
        let screenPoint = NSEvent.mouseLocation
        if detailsWindow.frame.contains(screenPoint) { return false }
        if sheetFrames(of: detailsWindow).contains(where: { $0.contains(screenPoint) }) { return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === detailsWindow {
            stopPopoverCloseMonitors()
            destroyMainPanelPresentation()
        } else if window === controlPanelWindow {
            // Drop the hosted settings tree; showControlPanel rebuilds it per open.
            controlPanelWindow?.contentViewController = nil
        }
    }

    private func closeDetailsWindow() {
        guard let detailsWindow, detailsWindow.isVisible else {
            stopPopoverCloseMonitors()
            return
        }
        dismissPresentedSheets(on: detailsWindow)
        mainPanelVisibility.isVisible = false
        detailsWindow.orderOut(nil)
        stopPopoverCloseMonitors()
        destroyMainPanelPresentation()
    }

    private func refreshVisiblePopoverSections() {
        guard model.selectedProvider == .codex else {
            if model.grokPanelState.quota == nil {
                model.refreshGrok(.current)
            }
            return
        }
        if settings.preferences.showsCostSummary {
            model.refreshCost(policy: .ifChanged)
        }
        if settings.preferences.showsTokenUsageHeatmap {
            model.refreshTokenHeatmap(policy: .ifChanged)
        }
        // Non-blocking: last snapshot stays visible, section spinner shows, alerts on change.
        if settings.preferences.showsRateLimitResetToday {
            model.refreshRateLimitResetToday(force: true)
        }
        // force:false — panel opens skip the heavy session-dir rescan while the
        // last successful scan is fresh; manual section refreshes stay forced.
        if settings.preferences.showsSessionRepairSummary {
            model.refreshSessionReport(force: false)
        }
        if settings.preferences.showsRecentSessions {
            model.refreshRecentSessions(force: false)
        }
    }

    private func showControlPanel(tab: ControlPanelTab = .general) {
        let panelSize = ControlPanelLayout.contentSize(titles: controlPanelTabTitles)
        let window = controlPanelWindow ?? NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: panelSize.width,
                height: panelSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Rebuild hosting view so initial tab selection and localized tab widths
        // are applied every time the panel opens.
        window.contentViewController = NSHostingController(rootView: ControlPanelView(
            settings: settings,
            model: model,
            checkForUpdates: { [weak self] in self?.updaterService.checkForUpdates() },
            initialTab: tab))
        ControlPanelLayout.applyWindowLayout(
            window,
            title: settings.l10n.text(.controlPanel),
            titles: controlPanelTabTitles)
        controlPanelWindow = window
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        centerControlPanel(window)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI hosting can settle its size one runloop turn after ordering front,
        // which nudges the frame off center — re-center once the layout is final.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.centerControlPanel(window)
        }
    }

    private var controlPanelTabTitles: [String] {
        ControlPanelTab.allCases.map { $0.title(settings.l10n) }
    }

    private func centerControlPanel(_ window: NSWindow) {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        // Horizontal: true center of the display (visibleFrame shifts when the Dock
        // sits on a side edge). Vertical: center of the usable area.
        let origin = NSPoint(
            x: screen.frame.midX - window.frame.width / 2,
            y: screen.visibleFrame.midY - window.frame.height / 2)
        window.setFrameOrigin(origin)
    }

    private func showMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        populateMenu(menu)
        statusMenu = menu
        closeMainPanel()
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        button.highlight(isMainPanelVisible)
    }

    private static func mouseButton(from event: NSEvent) -> StatusMouseButton {
        if event.type == .rightMouseDown || event.type == .rightMouseUp || event.buttonNumber == 1 {
            return .right
        }
        if event.modifierFlags.contains(.control) {
            return .right
        }
        return .left
    }

    @objc func showDetailsFromMenu() {
        showPopover()
    }

    @objc func openDetailsWindowFromMenu() {
        showDetailsWindow()
    }

    @objc func openControlPanelFromMenu() {
        showControlPanel()
    }

    @objc func refreshFromMenu() {
        beginFullRefresh(policy: .force, refreshWidgets: hasActiveWidgets)
        showPopover()
    }

    @objc func checkForUpdatesFromMenu() {
        updaterService.checkForUpdates()
    }

    @objc func repairFromMenu() {
        let alert = NSAlert()
        alert.messageText = settings.l10n.text(.repairConfirmTitle)
        alert.informativeText = model.repairWarning
        alert.addButton(withTitle: settings.l10n.text(.repair))
        alert.addButton(withTitle: settings.l10n.text(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.repairSessions()
        showPopover()
    }

    @objc func openCodexFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
