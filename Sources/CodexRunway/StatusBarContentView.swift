import AppKit
import CodexRunwayCore

final class StatusBarContentView: NSView {
    private var state = StatusBarContentState.placeholder
    private var hasUpdated = false
    /// Drives the battery fill sheen; only active while the battery style is shown.
    /// nonisolated(unsafe): cleaned up from deinit / window teardown on the main thread.
    nonisolated(unsafe) private var sheenTimer: Timer?
    nonisolated(unsafe) private var reduceMotionObserver: NSObjectProtocol?

    private var layout: StatusBarContentLayout {
        StatusBarContentLayout(state: state)
    }

    var renderPlan: StatusBarRenderPlan {
        layout.renderPlan
    }

    var preferredWidth: CGFloat {
        layout.preferredWidth
    }

    deinit {
        sheenTimer?.invalidate()
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
    }

    /// Returns true when the drawn content actually changed.
    @discardableResult
    func update(_ state: StatusBarContentState) -> Bool {
        guard !hasUpdated || self.state != state else {
            syncSheenAnimation()
            return false
        }
        self.state = state
        hasUpdated = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
        syncSheenAnimation()
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 22)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installReduceMotionObserverIfNeeded()
        }
        syncSheenAnimation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch state.configuration.style {
        case .text:
            drawText()
        case .countdown:
            drawCountdown()
        case .battery:
            drawBattery()
        case .meters:
            drawMeters()
        case .rings:
            drawRings()
        }
    }

    // MARK: - Animation

    private var shouldAnimateSheen: Bool {
        state.configuration.style == .battery
            && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func syncSheenAnimation() {
        if shouldAnimateSheen {
            guard sheenTimer == nil else { return }
            // Fire on the main run loop; assumeIsolated is safe because the timer is
            // only scheduled from main-thread UI code and added to .common modes.
            let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tickSheen()
                }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            sheenTimer = timer
        } else if sheenTimer != nil {
            sheenTimer?.invalidate()
            sheenTimer = nil
            needsDisplay = true
        }
    }

    private func tickSheen() {
        guard shouldAnimateSheen else {
            syncSheenAnimation()
            return
        }
        // Only repaint while the band is traveling (plus a short exit buffer).
        let phase = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: RunwaySheen.cycle)
        if phase <= RunwaySheen.travel + 0.08 {
            needsDisplay = true
        }
    }

    private func installReduceMotionObserverIfNeeded() {
        guard reduceMotionObserver == nil else { return }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncSheenAnimation()
                self?.needsDisplay = true
            }
        }
    }

    // MARK: - Countdown / meters / rings

    private func drawText() {
        let captions = layout.textCaptions
        let frames = layout.columnFrames(widths: layout.textColumnWidths, gap: 4, in: bounds)
        for (caption, frame) in zip(captions, frames) {
            drawCentered(caption, font: layout.textFont, rect: frame, color: .labelColor)
        }
    }

    private func drawCountdown() {
        guard renderPlan.meters.count > 1 else {
            drawCentered(state.content.text, font: layout.countdownFont, rect: bounds, color: .labelColor)
            return
        }
        let frames = layout.columnFrames(widths: layout.countdownColumnWidths, gap: 2, in: bounds)
        for (meter, frame) in zip(renderPlan.meters, frames) {
            drawCentered(
                layout.countdownCaption(for: meter),
                font: layout.countdownItemFont,
                rect: frame,
                color: .labelColor)
        }
    }

    private func drawMeters() {
        guard !renderPlan.meters.isEmpty else {
            drawCentered("--", font: layout.meterTextFont, rect: bounds, color: .labelColor)
            return
        }

        let frames = layout.columnFrames(widths: layout.meterColumnWidths, gap: 6, in: bounds)
        for (column, frame) in zip(renderPlan.columns, frames) {
            let rows = layout.rowFrames(count: column.count, in: frame, height: 10)
            for (meter, row) in zip(column, rows) {
                drawMeter(meter, row: row)
            }
        }
    }

    private func drawMeter(_ meter: QuotaMeter, row: NSRect) {
        let barWidth = min(40, row.width * 0.36)
        let barRect = NSRect(x: row.minX, y: row.midY - 2.5, width: barWidth, height: 5)
        let background = NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5)
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        background.fill()

        let percent = CGFloat(meter.remainingPercent) / 100
        let fillRect = NSRect(
            x: barRect.minX,
            y: barRect.minY,
            width: barRect.width * percent,
            height: barRect.height)
        NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5).fill(with: meterColor(meter), alpha: 0.95)
        let textRect = NSRect(
            x: barRect.maxX + 4,
            y: row.minY,
            width: max(20, row.maxX - barRect.maxX - 4),
            height: row.height)
        drawLine(layout.meterCaption(for: meter), rect: textRect)
    }

    private func drawRings() {
        guard !renderPlan.meters.isEmpty else {
            drawRing(nil, rect: NSRect(x: bounds.midX - 10, y: 1, width: 20, height: 20))
            return
        }

        let contentWidth = CGFloat(renderPlan.meters.count * 24 - 4)
        var x = bounds.midX - contentWidth / 2
        for meter in renderPlan.meters {
            drawRing(meter, rect: NSRect(x: x, y: 1, width: 20, height: 20))
            x += 24
        }
    }

    private func drawRing(_ meter: QuotaMeter?, rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.5
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        track.stroke()

        if let meter {
            let progress = CGFloat(meter.remainingPercent) / 100
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = 2.5
            meterColor(meter).setStroke()
            arc.stroke()
        }
        drawCentered(layout.ringText(for: meter), font: layout.ringFont, rect: rect, color: .labelColor)
    }

    // MARK: - Battery

    private func drawBattery() {
        guard !renderPlan.meters.isEmpty else {
            drawBatteryCell(
                meter: nil,
                in: bounds,
                metrics: .large,
                caption: "--",
                font: layout.batteryFont)
            return
        }

        if renderPlan.meters.count == 1, let meter = renderPlan.meters.first {
            drawBatteryCell(
                meter: meter,
                in: bounds,
                metrics: .large,
                caption: layout.batteryDetail(for: meter),
                font: layout.batteryFont)
            return
        }

        let frames = layout.columnFrames(widths: layout.batteryColumnWidths, gap: 5, in: bounds)
        for (column, frame) in zip(renderPlan.columns, frames) {
            let rows = layout.rowFrames(count: column.count, in: frame, height: 9.5, gap: 1.5)
            for (meter, row) in zip(column, rows) {
                drawBatteryCell(
                    meter: meter,
                    in: row,
                    metrics: .compact,
                    caption: layout.batteryCaption(for: meter),
                    font: layout.smallBatteryFont)
            }
        }
    }

    private func drawBatteryCell(
        meter: QuotaMeter?,
        in bounds: NSRect,
        metrics: BatteryMetrics,
        caption: String,
        font: NSFont)
    {
        // iOS-style hollow battery: thin outline + inset level fill + small terminal nub.
        let geometry = metrics.geometry(in: bounds)
        let percent = max(0, min(1, CGFloat(meter?.remainingPercent ?? 0) / 100))
        let fillColor = meterColor(meter)
        let outline = batteryOutlineColor

        // 1) Body outline (no solid shell).
        let bodyPath = NSBezierPath(roundedRect: geometry.body, xRadius: geometry.cornerRadius, yRadius: geometry.cornerRadius)
        bodyPath.lineWidth = metrics.strokeWidth
        outline.setStroke()
        bodyPath.stroke()

        // 2) Terminal nub — solid, same ink as the outline (SF Symbol proportions).
        let terminalPath = NSBezierPath(
            roundedRect: geometry.terminal,
            xRadius: geometry.terminalRadius,
            yRadius: geometry.terminalRadius)
        outline.setFill()
        terminalPath.fill()

        // 3) Level fill inset inside the outline.
        let trackPath = NSBezierPath(roundedRect: geometry.track, xRadius: geometry.trackRadius, yRadius: geometry.trackRadius)
        if percent > 0.001 {
            let fillWidth = max(geometry.minFillWidth, geometry.track.width * percent)
            let fillRect = NSRect(
                x: geometry.track.minX,
                y: geometry.track.minY,
                width: min(fillWidth, geometry.track.width),
                height: geometry.track.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: geometry.trackRadius, yRadius: geometry.trackRadius)

            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()
            fillColor.setFill()
            fillPath.fill()
            if shouldAnimateSheen, percent > 0.04 {
                drawBatterySheen(fillRect: fillRect, clipPath: fillPath)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        drawBatteryCaption(caption, font: font, in: geometry.body, remainingPercent: percent)
    }

    /// Matches system status-item ink (black in light, white in dark).
    private var batteryOutlineColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.92)
    }

    /// Soft band that drifts across the filled segment — same rhythm as panel sheen.
    private func drawBatterySheen(fillRect: NSRect, clipPath: NSBezierPath) {
        let t = RunwaySheen.progress(at: Date())
        guard t < 1 else { return }

        let bandWidth = max(10, fillRect.width * 0.42)
        let travel = fillRect.width + bandWidth
        let x = fillRect.minX + t * travel - bandWidth
        let sheenRect = NSRect(x: x, y: fillRect.minY, width: bandWidth, height: fillRect.height)

        guard let gradient = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0), 0),
            (NSColor.white.withAlphaComponent(0.18), 0.28),
            (NSColor.white.withAlphaComponent(0.55), 0.5),
            (NSColor.white.withAlphaComponent(0.18), 0.72),
            (NSColor.white.withAlphaComponent(0), 1)
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        gradient.draw(in: sheenRect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBatteryCaption(
        _ text: String,
        font: NSFont,
        in rect: NSRect,
        remainingPercent: CGFloat)
    {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        // Over a colored fill, white reads cleanly (like iOS charging icons).
        // Over empty interior, fall back to label ink.
        let overFill = remainingPercent >= 0.42
        let foreground: NSColor = overFill
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor.labelColor

        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -0.4)
        shadow.shadowBlurRadius = overFill ? 1.1 : 0
        shadow.shadowColor = overFill ? NSColor.black.withAlphaComponent(0.28) : nil

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]
        let size = text.size(withAttributes: attributes)
        let y = rect.midY - size.height / 2
        text.draw(
            in: NSRect(x: rect.minX, y: y, width: rect.width, height: size.height),
            withAttributes: attributes)
    }

    // MARK: - Shared helpers

    private func meterColor(_ meter: QuotaMeter?) -> NSColor {
        switch meter?.health {
        case .green:
            return .systemGreen
        case .yellow:
            return .systemYellow
        case .red:
            return .systemRed
        case nil:
            return .tertiaryLabelColor
        }
    }

    private func drawCentered(_ text: String, font: NSFont, rect: NSRect, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let size = text.size(withAttributes: attributes)
        let y = rect.midY - size.height / 2
        text.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: size.height), withAttributes: attributes)
    }

    private func drawLine(_ text: String, rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: layout.meterTextFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

// MARK: - Battery geometry (iOS status-bar proportions)

private struct BatteryMetrics {
    /// Outline stroke thickness.
    var strokeWidth: CGFloat
    var bodyHeight: CGFloat
    var horizontalInset: CGFloat
    var terminalWidth: CGFloat
    var terminalHeightRatio: CGFloat
    /// Gap between body right edge and terminal (iOS keeps this very tight).
    var terminalGap: CGFloat
    var cornerRadius: CGFloat
    /// Inset from the *outer* body edge to the fill; must clear the stroke.
    var trackInset: CGFloat
    var minFillWidth: CGFloat

    /// Single-meter menu bar battery — elongated capsule like SF Symbols.
    static let large = BatteryMetrics(
        strokeWidth: 1.35,
        bodyHeight: 12,
        horizontalInset: 2.5,
        terminalWidth: 1.75,
        terminalHeightRatio: 0.38,
        terminalGap: 0.85,
        cornerRadius: 3.25,
        trackInset: 2.15,
        minFillWidth: 2)

    /// Stacked multi-meter cells.
    static let compact = BatteryMetrics(
        strokeWidth: 1.1,
        bodyHeight: 9,
        horizontalInset: 0.5,
        terminalWidth: 1.35,
        terminalHeightRatio: 0.4,
        terminalGap: 0.7,
        cornerRadius: 2.4,
        trackInset: 1.7,
        minFillWidth: 1.5)

    struct Geometry {
        var body: NSRect
        var terminal: NSRect
        var track: NSRect
        var cornerRadius: CGFloat
        var trackRadius: CGFloat
        var terminalRadius: CGFloat
        var minFillWidth: CGFloat
    }

    func geometry(in bounds: NSRect) -> Geometry {
        let height = min(bodyHeight, max(7, bounds.height - 2))
        let bodyWidth = max(14, bounds.width - horizontalInset * 2 - terminalWidth - terminalGap)
        // Align stroke fully inside the row so it is not clipped.
        let body = NSRect(
            x: bounds.minX + horizontalInset + strokeWidth / 2,
            y: bounds.midY - height / 2 + strokeWidth / 2,
            width: bodyWidth - strokeWidth,
            height: height - strokeWidth)
        let outerMaxX = body.maxX + strokeWidth / 2
        let terminalHeight = max(2.2, (height - strokeWidth) * terminalHeightRatio)
        let terminal = NSRect(
            x: outerMaxX + terminalGap,
            y: bounds.midY - terminalHeight / 2,
            width: terminalWidth,
            height: terminalHeight)
        // Fill sits inside the stroked path.
        let track = body.insetBy(dx: trackInset - strokeWidth / 2, dy: trackInset - strokeWidth / 2)
        return Geometry(
            body: body,
            terminal: terminal,
            track: track,
            cornerRadius: max(1.5, cornerRadius - strokeWidth / 2),
            trackRadius: max(1, cornerRadius - trackInset + 0.25),
            terminalRadius: terminalHeight / 2,
            minFillWidth: minFillWidth)
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        fill()
    }
}
