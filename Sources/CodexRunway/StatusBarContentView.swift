import AppKit
import CodexRunwayCore

final class StatusBarContentView: NSView {
    private var state = StatusBarContentState.placeholder
    private var hasUpdated = false

    private var layout: StatusBarContentLayout {
        StatusBarContentLayout(state: state)
    }

    var renderPlan: StatusBarRenderPlan {
        layout.renderPlan
    }

    var preferredWidth: CGFloat {
        layout.preferredWidth
    }

    /// Returns true when the drawn content actually changed.
    @discardableResult
    func update(_ state: StatusBarContentState) -> Bool {
        guard !hasUpdated || self.state != state else { return false }
        self.state = state
        hasUpdated = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch state.configuration.style {
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

    private func drawBattery() {
        guard !renderPlan.meters.isEmpty else {
            drawLargeBattery(nil)
            return
        }

        if renderPlan.meters.count == 1 {
            drawLargeBattery(renderPlan.meters.first)
            return
        }

        let frames = layout.columnFrames(widths: layout.batteryColumnWidths, gap: 6, in: bounds)
        for (column, frame) in zip(renderPlan.columns, frames) {
            let rows = layout.rowFrames(count: column.count, in: frame, height: 8, gap: 1)
            for (meter, row) in zip(column, rows) {
                drawSmallBattery(meter, rect: row)
            }
        }
    }

    private func drawLargeBattery(_ meter: QuotaMeter?) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()

        let percent = CGFloat(meter?.remainingPercent ?? 0) / 100
        let fillRect = rect.insetBy(dx: 2, dy: 2)
        let filled = NSRect(x: fillRect.minX, y: fillRect.minY, width: fillRect.width * percent, height: fillRect.height)
        NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill(with: meterColor(meter), alpha: 0.85)
        drawCentered(
            meter.map(layout.batteryDetail(for:)) ?? "--",
            font: layout.batteryFont,
            rect: rect,
            color: .labelColor)
    }

    private func drawSmallBattery(_ meter: QuotaMeter, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()

        let fillRect = rect.insetBy(dx: 1.5, dy: 1.5)
        let width = fillRect.width * CGFloat(meter.remainingPercent) / 100
        let filled = NSRect(x: fillRect.minX, y: fillRect.minY, width: width, height: fillRect.height)
        NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill(with: meterColor(meter), alpha: 0.85)
        drawCentered(
            layout.batteryCaption(for: meter),
            font: layout.smallBatteryFont,
            rect: rect,
            color: .labelColor)
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
        drawCentered(ringText(for: meter), font: layout.ringFont, rect: rect, color: .labelColor)
    }

    private func ringText(for meter: QuotaMeter?) -> String {
        meter.map { "\($0.remainingPercent)" } ?? "--"
    }

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

private extension NSBezierPath {
    func fill(with color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        fill()
    }
}
