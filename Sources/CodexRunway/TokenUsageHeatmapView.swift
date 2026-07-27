import AppKit
import CodexRunwayCore
import SwiftUI

struct TokenUsageHeatmapView: View {
    /// Codex profile activity — all clients / devices.
    var allDevicesTokens: [String: Int]
    /// This Mac only — local session index.
    var localTokens: [String: Int]
    var calculatedAt: Date?
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void

    @State private var mode: TokenUsageHeatmapMode = .daily
    /// Cached grid; rebuilt when `dataFingerprint` changes.
    @State private var snapshot: TokenUsageHeatmapSnapshot?
    @StateObject private var hover = HeatmapHoverStore()

    private var dataFingerprint: String {
        let allTotal = allDevicesTokens.values.reduce(0, +)
        let localTotal = localTokens.values.reduce(0, +)
        let stamp = calculatedAt?.timeIntervalSince1970 ?? 0
        return "\(mode.rawValue)|\(stamp)|\(allDevicesTokens.count)|\(allTotal)|\(localTokens.count)|\(localTotal)|\(l10n.language)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .task(id: dataFingerprint) {
            rebuildSnapshot()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            if snapshot.weeks.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .heatmapEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                grid(snapshot)
                if !snapshot.hasUsage, !isRefreshing {
                    Text(l10n.text(.heatmapEmpty))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(l10n.text(isRefreshing ? .calculating : .heatmapEmpty))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(l10n.text(.tokenUsageHeatmap))
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Picker("", selection: $mode) {
                    Text(l10n.text(.heatmapDaily)).tag(TokenUsageHeatmapMode.daily)
                    Text(l10n.text(.heatmapWeekly)).tag(TokenUsageHeatmapMode.weekly)
                    Text(l10n.text(.heatmapCumulative)).tag(TokenUsageHeatmapMode.cumulative)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.callout.weight(.medium))
                        }
                    }
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help(l10n.text(.refresh))
                .pointingHandCursor()
            }
        }
    }

    private func grid(_ snapshot: TokenUsageHeatmapSnapshot) -> some View {
        let weekCount = max(1, snapshot.weeks.count)
        let outerHeight = contentHeight(cellSize: 11, rowSpacing: 2, labelSpacing: 6)
        return GeometryReader { proxy in
            let metrics = layoutMetrics(width: proxy.size.width, weekCount: weekCount)
            let height = contentHeight(
                cellSize: metrics.cellSize,
                rowSpacing: metrics.rowSpacing,
                labelSpacing: metrics.labelSpacing)
            let cellsHeight = metrics.cellSize * 7 + metrics.rowSpacing * 6

            ZStack(alignment: .topLeading) {
                StaticHeatmapCanvas(snapshot: snapshot, metrics: metrics)
                    .frame(width: metrics.gridWidth, height: cellsHeight)

                monthAxis(snapshot: snapshot, metrics: metrics)
                    .frame(width: metrics.gridWidth, height: 14, alignment: .leading)
                    .offset(y: cellsHeight + metrics.labelSpacing)

                HeatmapGridPointerOverlay(metrics: metrics, hover: hover)
                    .frame(width: metrics.gridWidth, height: cellsHeight)

                hoverHighlight(snapshot: snapshot, metrics: metrics)
                    .allowsHitTesting(false)

                hoverTooltip(
                    snapshot: snapshot,
                    metrics: metrics,
                    containerSize: CGSize(width: metrics.gridWidth, height: cellsHeight))
                    .allowsHitTesting(false)
            }
            .frame(width: metrics.gridWidth, height: height, alignment: .topLeading)
            .frame(width: proxy.size.width, height: height, alignment: .leading)
        }
        .frame(height: outerHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.text(.tokenUsageHeatmap))
        .accessibilityValue(accessibilitySummary(snapshot))
    }

    @ViewBuilder
    private func hoverHighlight(
        snapshot: TokenUsageHeatmapSnapshot,
        metrics: HeatmapLayoutMetrics
    ) -> some View {
        if let week = hover.week,
           let day = hover.day,
           snapshot.weeks.indices.contains(week),
           snapshot.weeks[week].indices.contains(day),
           snapshot.weeks[week][day].isInRange
        {
            let size = metrics.cellSize
            let x = CGFloat(week) * (size + metrics.columnSpacing)
            let y = CGFloat(day) * (size + metrics.rowSpacing)
            RoundedRectangle(cornerRadius: max(1.5, size * 0.22), style: .continuous)
                .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                .frame(width: size, height: size)
                .offset(x: x, y: y)
        }
    }

    @ViewBuilder
    private func hoverTooltip(
        snapshot: TokenUsageHeatmapSnapshot,
        metrics: HeatmapLayoutMetrics,
        containerSize: CGSize
    ) -> some View {
        if let week = hover.week,
           let day = hover.day,
           snapshot.weeks.indices.contains(week),
           snapshot.weeks[week].indices.contains(day)
        {
            let cell = snapshot.weeks[week][day]
            if cell.isInRange {
                let lines = tooltipLines(for: cell)
                let preferredWidth = min(230, max(168, containerSize.width * 0.38))
                let tooltipSize = CGSize(
                    width: min(containerSize.width, preferredWidth),
                    height: 60)
                let cellRect = CGRect(
                    x: CGFloat(week) * (metrics.cellSize + metrics.columnSpacing),
                    y: CGFloat(day) * (metrics.cellSize + metrics.rowSpacing),
                    width: metrics.cellSize,
                    height: metrics.cellSize)
                let origin = HeatmapTooltipPlacement.origin(
                    cellRect: cellRect,
                    tooltipSize: tooltipSize,
                    containerSize: containerSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(lines.primary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let secondary = lines.secondary {
                        Text(secondary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(
                    width: tooltipSize.width,
                    height: tooltipSize.height,
                    alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
                .offset(x: origin.x, y: origin.y)
                .accessibilityHidden(true)
            }
        }
    }

    private func monthAxis(snapshot: TokenUsageHeatmapSnapshot, metrics: HeatmapLayoutMetrics) -> some View {
        let step = metrics.cellSize + metrics.columnSpacing
        return Canvas { context, _ in
            for label in snapshot.monthLabels {
                let text = Text(monthTitle(label.month))
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: CGFloat(label.weekIndex) * step, y: 0),
                    anchor: .topLeading)
            }
        }
    }

    private struct TooltipLines: Equatable {
        var date: String
        var primary: String
        var secondary: String?
    }

    private func tooltipLines(for cell: TokenUsageHeatmapCell) -> TooltipLines {
        // Always that calendar day's totals (not weekly/cumulative aggregates).
        let date = Self.tooltipDateFormatter(language: l10n.language).string(from: cell.date)
        let tokensLabel = l10n.text(.tokens)
        let allText =
            "\(l10n.text(.heatmapAllDevices)) \(TokenUsageHeatmapBuilder.compactTokenCount(cell.allDevicesTokens, language: l10n.language)) \(tokensLabel)"
        let localText =
            "\(l10n.text(.heatmapLocalDevice)) \(TokenUsageHeatmapBuilder.compactTokenCount(cell.localTokens, language: l10n.language)) \(tokensLabel)"
        return TooltipLines(date: date, primary: allText, secondary: localText)
    }

    private func monthTitle(_ month: Int) -> String {
        if l10n.language == .simplifiedChinese {
            return "\(month)月"
        }
        let symbols = Calendar(identifier: .gregorian).shortMonthSymbols
        let index = max(0, min(symbols.count - 1, month - 1))
        return symbols[index]
    }

    private func accessibilitySummary(_ snapshot: TokenUsageHeatmapSnapshot) -> String {
        let total = TokenUsageHeatmapBuilder.compactTokenCount(snapshot.totalTokens, language: l10n.language)
        return "\(total) \(l10n.text(.tokens))"
    }

    private func rebuildSnapshot() {
        snapshot = TokenUsageHeatmapBuilder.make(
            allDevicesTokens: allDevicesTokens,
            localTokens: localTokens,
            mode: mode,
            now: calculatedAt ?? Date())
        hover.clear()
    }

    private func layoutMetrics(width: CGFloat, weekCount: Int) -> HeatmapLayoutMetrics {
        let columnSpacing: CGFloat = 2
        let rowSpacing: CGFloat = 2
        let count = max(1, weekCount)
        let totalSpacing = columnSpacing * CGFloat(count - 1)
        let raw = floor(max(1, (width - totalSpacing) / CGFloat(count)))
        let cellSize = min(11, max(5, raw))
        return HeatmapLayoutMetrics(
            cellSize: cellSize,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            labelSpacing: 6,
            weekCount: count)
    }

    private func contentHeight(cellSize: CGFloat, rowSpacing: CGFloat, labelSpacing: CGFloat) -> CGFloat {
        cellSize * 7 + rowSpacing * 6 + labelSpacing + 14
    }

    private static func tooltipDateFormatter(language: ResolvedLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.locale = Locale(identifier: language == .simplifiedChinese ? "zh_Hans_CN" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

// MARK: - Static canvas

private struct StaticHeatmapCanvas: View {
    var snapshot: TokenUsageHeatmapSnapshot
    var metrics: HeatmapLayoutMetrics

    var body: some View {
        Canvas { context, _ in
            let corner = max(1.5, metrics.cellSize * 0.22)
            let outOfRange = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
            let levelColors: [Color] = [
                Color(nsColor: .quaternaryLabelColor).opacity(0.22),
                Color(nsColor: .systemBlue).opacity(0.28),
                Color(nsColor: .systemBlue).opacity(0.45),
                Color(nsColor: .systemBlue).opacity(0.68),
                Color(nsColor: .systemBlue).opacity(0.92),
            ]
            for (weekIndex, week) in snapshot.weeks.enumerated() {
                for (dayIndex, cell) in week.enumerated() {
                    let x = CGFloat(weekIndex) * (metrics.cellSize + metrics.columnSpacing)
                    let y = CGFloat(dayIndex) * (metrics.cellSize + metrics.rowSpacing)
                    let rect = CGRect(x: x, y: y, width: metrics.cellSize, height: metrics.cellSize)
                    let path = Path(roundedRect: rect, cornerRadius: corner)
                    let fill: Color
                    if !cell.isInRange {
                        fill = outOfRange
                    } else {
                        fill = levelColors[min(4, max(0, cell.level))]
                    }
                    context.fill(path, with: .color(fill))
                }
            }
        }
    }
}

// MARK: - Hover store

private final class HeatmapHoverStore: ObservableObject {
    @Published private(set) var week: Int?
    @Published private(set) var day: Int?

    func set(week: Int, day: Int) {
        if self.week != week || self.day != day {
            self.week = week
            self.day = day
        }
    }

    func clear() {
        if week != nil || day != nil {
            week = nil
            day = nil
        }
    }
}

private struct HeatmapLayoutMetrics: Equatable {
    var cellSize: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var labelSpacing: CGFloat
    var weekCount: Int

    var gridWidth: CGFloat {
        CGFloat(weekCount) * cellSize + CGFloat(max(0, weekCount - 1)) * columnSpacing
    }
}

enum HeatmapTooltipPlacement {
    static func origin(
        cellRect: CGRect,
        tooltipSize: CGSize,
        containerSize: CGSize,
        gap: CGFloat = 6
    ) -> CGPoint {
        let maxX = max(0, containerSize.width - tooltipSize.width)
        let maxY = max(0, containerSize.height - tooltipSize.height)
        let alignedY = min(max(0, cellRect.midY - tooltipSize.height / 2), maxY)
        let prefersRight = cellRect.midX <= containerSize.width / 2
        let horizontalCandidates = prefersRight
            ? [cellRect.maxX + gap, cellRect.minX - gap - tooltipSize.width]
            : [cellRect.minX - gap - tooltipSize.width, cellRect.maxX + gap]

        if let x = horizontalCandidates.first(where: { $0 >= 0 && $0 <= maxX }) {
            return CGPoint(x: x, y: alignedY)
        }

        let alignedX = min(max(0, cellRect.midX - tooltipSize.width / 2), maxX)
        let above = cellRect.minY - gap - tooltipSize.height
        if above >= 0 {
            return CGPoint(x: alignedX, y: above)
        }
        return CGPoint(x: alignedX, y: cellRect.maxY + gap)
    }
}

// MARK: - Pointer tracking

private struct HeatmapGridPointerOverlay: NSViewRepresentable {
    var metrics: HeatmapLayoutMetrics
    var hover: HeatmapHoverStore

    func makeCoordinator() -> Coordinator {
        Coordinator(hover: hover)
    }

    func makeNSView(context: Context) -> HeatmapGridNSView {
        let view = HeatmapGridNSView()
        view.coordinator = context.coordinator
        context.coordinator.metrics = metrics
        context.coordinator.hover = hover
        return view
    }

    func updateNSView(_ nsView: HeatmapGridNSView, context: Context) {
        context.coordinator.metrics = metrics
        context.coordinator.hover = hover
        nsView.coordinator = context.coordinator
        nsView.refreshTrackingAreasIfNeeded()
    }

    final class Coordinator {
        var metrics: HeatmapLayoutMetrics
        var hover: HeatmapHoverStore

        init(hover: HeatmapHoverStore) {
            self.metrics = HeatmapLayoutMetrics(
                cellSize: 8, columnSpacing: 2, rowSpacing: 2, labelSpacing: 6, weekCount: 1)
            self.hover = hover
        }

        func handleMouse(at point: CGPoint, in bounds: CGRect) {
            guard bounds.contains(point), metrics.weekCount > 0 else {
                hover.clear()
                return
            }
            let strideX = metrics.cellSize + metrics.columnSpacing
            let strideY = metrics.cellSize + metrics.rowSpacing
            guard strideX > 0, strideY > 0 else {
                hover.clear()
                return
            }

            var week = Int(floor(point.x / strideX))
            var day = Int(floor(point.y / strideY))
            week = min(metrics.weekCount - 1, max(0, week))
            day = min(6, max(0, day))

            let gridWidth = CGFloat(metrics.weekCount) * metrics.cellSize
                + CGFloat(max(0, metrics.weekCount - 1)) * metrics.columnSpacing
            let gridHeight = 7 * metrics.cellSize + 6 * metrics.rowSpacing
            if point.x > gridWidth || point.y > gridHeight {
                hover.clear()
                return
            }

            hover.set(week: week, day: day)
        }
    }
}

private final class HeatmapGridNSView: NSView {
    var coordinator: HeatmapGridPointerOverlay.Coordinator?
    private var lastTrackingBounds: CGRect = .null

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshTrackingAreasIfNeeded() {
        if lastTrackingBounds != bounds {
            updateTrackingAreas()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .enabledDuringMouseDrag,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
        lastTrackingBounds = bounds
    }

    override func mouseEntered(with event: NSEvent) {
        handle(event)
    }

    override func mouseMoved(with event: NSEvent) {
        handle(event)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.hover.clear()
    }

    private func handle(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouse(at: point, in: bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override var acceptsFirstResponder: Bool { false }
}
