import AppKit
import CodexRunwayCore
import SwiftUI

struct TokenUsageTooltipContent: Equatable {
    var date: String
    var primary: String
    var secondary: String?
    var note: String?

    /// - Parameter showsOfficialStats: When false (Grok), only local session tokens are shown.
    static func make(
        date: String,
        officialTokens: Int,
        localTokens: Int,
        l10n: L10n,
        showsOfficialStats: Bool = true
    ) -> Self {
        let tokensLabel = l10n.text(.tokens)
        let local = TokenUsageHeatmapBuilder.compactTokenCount(
            localTokens,
            language: l10n.language)
        if !showsOfficialStats {
            return Self(
                date: date,
                primary: "\(l10n.text(.heatmapLocalShort)) \(local) \(tokensLabel)",
                secondary: nil,
                note: nil)
        }
        let official = TokenUsageHeatmapBuilder.compactTokenCount(
            officialTokens,
            language: l10n.language)
        return Self(
            date: date,
            primary: "\(l10n.text(.heatmapAllDevices)) \(official) \(tokensLabel)",
            secondary: "\(l10n.text(.heatmapLocalDevice)) \(local) \(tokensLabel)",
            note: localTokens > officialTokens
                ? l10n.text(.heatmapSourceMismatch)
                : nil)
    }
}

enum TokenUsageSourcePresentation {
    static func asOfText(
        statsAsOf: String?,
        generatedAt: Date?,
        l10n: L10n
    ) -> String? {
        let date = normalized(statsAsOf) ?? generatedAt.map(utcDay)
        return date.map { String(format: l10n.text(.heatmapOfficialAsOf), $0) }
    }

    static func disclosure(l10n: L10n, showsOfficialStats: Bool = true) -> String {
        showsOfficialStats
            ? l10n.text(.heatmapSourceDisclosure)
            : l10n.text(.grokLocalUsageHint)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum TokenUsageTooltipLayout {
    static func size(
        for content: TokenUsageTooltipContent,
        cellRect: CGRect,
        containerSize: CGSize,
        gap: CGFloat = 6
    ) -> CGSize {
        let preferredWidth = min(260, max(180, containerSize.width * 0.42))
        let leftRoom = max(0, cellRect.minX - gap)
        let rightRoom = max(0, containerSize.width - cellRect.maxX - gap)
        let sideRoom = max(leftRoom, rightRoom)
        let width = sideRoom >= 160 ? min(preferredWidth, sideRoom) : preferredWidth
        let height: CGFloat
        if content.note != nil {
            height = 80
        } else if content.secondary != nil {
            height = 60
        } else {
            height = 44
        }
        return CGSize(
            width: min(containerSize.width, width),
            height: height)
    }
}

private struct TokenUsageTooltipCard: View {
    var content: TokenUsageTooltipContent
    var size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.date)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(content.primary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let secondary = content.secondary {
                Text(secondary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let note = content.note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
    }
}

struct TokenUsageHeatmapView: View {
    /// Current-account profile statistics from the official service.
    var allDevicesTokens: [String: Int]
    /// All session logs present on this Mac; historical logs may span accounts.
    var localTokens: [String: Int]
    var calculatedAt: Date?
    var officialStatsAsOf: String?
    var officialGeneratedAt: Date?
    /// When false (Grok), hide official multi-device stats from tooltips and captions.
    var showsOfficialStats: Bool = true
    @Binding var chartStyle: TokenUsageChartStyle
    var l10n: L10n
    var isRefreshing: Bool
    var onRefresh: () -> Void

    @State private var mode: TokenUsageHeatmapMode = .daily
    /// Cached grid; rebuilt when `dataFingerprint` changes.
    @State private var snapshot: TokenUsageHeatmapSnapshot?
    /// Cached line/bar series; rebuilt with the same fingerprint.
    @State private var series: TokenUsageChartSeries?
    @StateObject private var hover = HeatmapHoverStore()
    @State private var isChartStyleHovered = false
    @State private var isRefreshHovered = false

    private var dataFingerprint: String {
        let allTotal = allDevicesTokens.values.reduce(0, +)
        let localTotal = localTokens.values.reduce(0, +)
        let stamp = calculatedAt?.timeIntervalSince1970 ?? 0
        let officialStamp = officialGeneratedAt?.timeIntervalSince1970 ?? 0
        return "\(mode.rawValue)|\(chartStyle.rawValue)|\(stamp)|\(officialStatsAsOf ?? "")|\(officialStamp)|\(allDevicesTokens.count)|\(allTotal)|\(localTokens.count)|\(localTotal)|\(l10n.language)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        // Fixed height keeps NSPopover geometry stable when switching chart styles.
        .frame(maxWidth: .infinity, minHeight: chartContentMinHeight, alignment: .topLeading)
        .onAppear { rebuildData() }
        .onChange(of: dataFingerprint) { _ in
            rebuildData()
        }
    }

    /// Matches heatmap grid height so line/bar swaps do not resize the panel section.
    private var chartContentMinHeight: CGFloat {
        // header (~22) + spacing (8) + plot (~98)
        128
    }

    @ViewBuilder
    private var content: some View {
        switch chartStyle {
        case .heatmap:
            heatmapContent
        case .line, .bar:
            trendContent
        }
    }

    @ViewBuilder
    private var heatmapContent: some View {
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

    @ViewBuilder
    private var trendContent: some View {
        if let series {
            if series.points.isEmpty {
                Text(l10n.text(isRefreshing ? .calculating : .heatmapEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TokenUsageTrendChartView(
                    series: series,
                    style: chartStyle == .bar ? .bar : .line,
                    showsOfficialStats: showsOfficialStats,
                    l10n: l10n)
                if !series.hasUsage, !isRefreshing {
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

    /// The compact controls share the title row; the wider mode picker stays below
    /// so localized labels cannot push the section beyond the popover width.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.text(.tokenUsageHeatmap))
                        .font(.headline)
                        .lineLimit(1)
                    if showsOfficialStats, let officialAsOfText {
                        Text(officialAsOfText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Cap so a future longer localization truncates instead of
                // widening the section past the panel.
                .frame(maxWidth: 320, alignment: .leading)
                Spacer(minLength: 4)

                HeaderPopoverButton(
                    systemImage: "info.circle",
                    help: TokenUsageSourcePresentation.disclosure(
                        l10n: l10n,
                        showsOfficialStats: showsOfficialStats),
                    accessibilityIdentifier: "token-usage-info")
                {
                    TokenUsageSourcePopover(
                        l10n: l10n,
                        disclosure: TokenUsageSourcePresentation.disclosure(
                            l10n: l10n,
                            showsOfficialStats: showsOfficialStats),
                        officialAsOfText: showsOfficialStats ? officialAsOfText : nil)
                }

                // AppKit popup avoids SwiftUI Menu, which can collapse / mis-place NSPopover.
                ChartStylePopUpButton(
                    style: $chartStyle,
                    titles: chartStyleTitles,
                    helpText: l10n.text(.tokenUsageChartStyle))
                    .frame(width: 34, height: 24)
                    .background(
                        isChartStyleHovered ? RunwaySurface.hoverNeutral : Color.clear,
                        in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                    .animation(.easeOut(duration: 0.12), value: isChartStyleHovered)
                    .accessibilityLabel(l10n.text(.tokenUsageChartStyle))
                    .pointingHandCursor()
                    .onHover { isChartStyleHovered = $0 }

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
                    .foregroundStyle(
                        isRefreshHovered && !isRefreshing ? Color.primary : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        isRefreshHovered && !isRefreshing ? RunwaySurface.hoverNeutral : Color.clear,
                        in: RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous))
                    .animation(.easeOut(duration: 0.12), value: isRefreshHovered)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help(l10n.text(.refresh))
                .accessibilityLabel(l10n.text(.refresh))
                .pointingHandCursor(enabled: !isRefreshing)
                .onHover { isRefreshHovered = $0 }
            }

            Picker("", selection: $mode) {
                Text(l10n.text(.heatmapDaily)).tag(TokenUsageHeatmapMode.daily)
                Text(l10n.text(.heatmapWeekly)).tag(TokenUsageHeatmapMode.weekly)
                Text(modeThirdSegmentTitle).tag(TokenUsageHeatmapMode.cumulative)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 252, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var officialAsOfText: String? {
        TokenUsageSourcePresentation.asOfText(
            statsAsOf: officialStatsAsOf,
            generatedAt: officialGeneratedAt,
            l10n: l10n)
    }

    private var modeThirdSegmentTitle: String {
        switch chartStyle {
        case .heatmap:
            return l10n.text(.heatmapCumulative)
        case .line, .bar:
            return l10n.text(.heatmapMonthly)
        }
    }

    private var chartStyleTitles: [TokenUsageChartStyle: String] {
        [
            .heatmap: l10n.text(.tokenUsageChartHeatmap),
            .line: l10n.text(.tokenUsageChartLine),
            .bar: l10n.text(.tokenUsageChartBar),
        ]
    }

    private func grid(_ snapshot: TokenUsageHeatmapSnapshot) -> some View {
        let weekCount = max(1, snapshot.weeks.count)
        let outerHeight = contentHeight(
            cellSize: HeatmapLayoutMetrics.maxCellSize,
            rowSpacing: HeatmapLayoutMetrics.rowSpacing,
            labelSpacing: HeatmapLayoutMetrics.labelSpacing)
        return GeometryReader { proxy in
            let metrics = HeatmapLayoutMetrics.make(width: proxy.size.width, weekCount: weekCount)
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
                    containerSize: CGSize(width: metrics.gridWidth, height: outerHeight))
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
                let content = tooltipContent(for: cell)
                let cellRect = CGRect(
                    x: CGFloat(week) * (metrics.cellSize + metrics.columnSpacing),
                    y: CGFloat(day) * (metrics.cellSize + metrics.rowSpacing),
                    width: metrics.cellSize,
                    height: metrics.cellSize)
                let tooltipSize = TokenUsageTooltipLayout.size(
                    for: content,
                    cellRect: cellRect,
                    containerSize: containerSize)
                let origin = HeatmapTooltipPlacement.origin(
                    cellRect: cellRect,
                    tooltipSize: tooltipSize,
                    containerSize: containerSize)

                TokenUsageTooltipCard(content: content, size: tooltipSize)
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

    private func tooltipContent(for cell: TokenUsageHeatmapCell) -> TokenUsageTooltipContent {
        // Always that calendar day's totals (not weekly/cumulative aggregates).
        let date = Self.tooltipDateFormatter(language: l10n.language).string(from: cell.date)
        return TokenUsageTooltipContent.make(
            date: date,
            officialTokens: cell.allDevicesTokens,
            localTokens: cell.localTokens,
            l10n: l10n,
            showsOfficialStats: showsOfficialStats)
    }

    private func monthTitle(_ month: Int) -> String {
        TokenUsageDateFormatting.monthTitle(month, language: l10n.language)
    }

    private func accessibilitySummary(_ snapshot: TokenUsageHeatmapSnapshot) -> String {
        let total = TokenUsageHeatmapBuilder.compactTokenCount(snapshot.totalTokens, language: l10n.language)
        return "\(total) \(l10n.text(.tokens))"
    }

    private func rebuildData() {
        let now = calculatedAt ?? Date()
        switch chartStyle {
        case .heatmap:
            snapshot = TokenUsageHeatmapBuilder.make(
                allDevicesTokens: allDevicesTokens,
                localTokens: localTokens,
                mode: mode,
                now: now)
            series = nil
        case .line, .bar:
            series = TokenUsageHeatmapBuilder.makeSeries(
                allDevicesTokens: allDevicesTokens,
                localTokens: localTokens,
                mode: mode,
                now: now)
            snapshot = nil
        }
        hover.clear()
    }

    private func contentHeight(cellSize: CGFloat, rowSpacing: CGFloat, labelSpacing: CGFloat) -> CGFloat {
        cellSize * 7 + rowSpacing * 6 + labelSpacing + 14
    }

    private static func tooltipDateFormatter(language: ResolvedLanguage) -> DateFormatter {
        TokenUsageDateFormatting.mediumDateFormatter(language: language)
    }
}

private struct TokenUsageSourcePopover: View {
    var l10n: L10n
    var disclosure: String
    var officialAsOfText: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.tokenUsageHeatmap))
                .font(.title3.weight(.semibold))
            Text(disclosure)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let officialAsOfText {
                Text(officialAsOfText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(l10n.text(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
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

struct HeatmapLayoutMetrics: Equatable {
    /// Upper bound so a momentarily unconstrained header cannot grow the grid
    /// past the shipped popover content area (400 − 2×16 padding − 4 scroll).
    static let maxGridWidth: CGFloat = 364
    static let minCellSize: CGFloat = 5
    static let maxCellSize: CGFloat = 11
    static let columnSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 2
    static let labelSpacing: CGFloat = 6

    var cellSize: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var labelSpacing: CGFloat
    var weekCount: Int

    var gridWidth: CGFloat {
        CGFloat(weekCount) * cellSize + CGFloat(max(0, weekCount - 1)) * columnSpacing
    }

    /// Sizes square cells to fill `width` when that stays within the cell cap.
    /// Late-year YTD grids (≈30+ weeks) therefore sit flush with the panel;
    /// early-year grids keep the compact GitHub-style cell size instead of
    /// inflating a handful of columns.
    static func make(width: CGFloat, weekCount: Int) -> HeatmapLayoutMetrics {
        let count = max(1, weekCount)
        let totalSpacing = columnSpacing * CGFloat(count - 1)
        let available = min(max(0, width), maxGridWidth)
        let raw = (available - totalSpacing) / CGFloat(count)
        let cellSize = min(maxCellSize, max(minCellSize, raw))
        return HeatmapLayoutMetrics(
            cellSize: cellSize,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            labelSpacing: labelSpacing,
            weekCount: count)
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
        let below = cellRect.maxY + gap
        if below <= maxY {
            return CGPoint(x: alignedX, y: below)
        }
        return CGPoint(x: alignedX, y: alignedY)
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

// MARK: - Chart style popup (AppKit — safe inside NSPopover)

/// Pull-down using `NSPopUpButton` so selection does not re-anchor the host `NSPopover`
/// the way SwiftUI `Menu` often does on macOS 12–14.
private struct ChartStylePopUpButton: NSViewRepresentable {
    @Binding var style: TokenUsageChartStyle
    var titles: [TokenUsageChartStyle: String]
    var helpText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(style: $style)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.toolTip = helpText
        context.coordinator.button = button
        context.coordinator.rebuildMenu(titles: titles, selected: style)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.style = $style
        context.coordinator.button = button
        button.toolTip = helpText
        context.coordinator.rebuildMenu(titles: titles, selected: style)
    }

    @MainActor
    final class Coordinator: NSObject {
        var style: Binding<TokenUsageChartStyle>
        var titles: [TokenUsageChartStyle: String] = [:]
        weak var button: NSPopUpButton?
        private var isRebuilding = false

        init(style: Binding<TokenUsageChartStyle>) {
            self.style = style
        }

        func rebuildMenu(titles: [TokenUsageChartStyle: String], selected: TokenUsageChartStyle) {
            guard let button else { return }
            self.titles = titles
            isRebuilding = true
            defer { isRebuilding = false }

            button.removeAllItems()

            // Pull-down title item (index 0) — shows the active style icon.
            let titleItem = NSMenuItem()
            titleItem.image = Self.symbolImage(for: selected)
            titleItem.image?.isTemplate = true
            titleItem.title = ""
            button.menu?.addItem(titleItem)

            for chartStyle in TokenUsageChartStyle.allCases {
                let title = titles[chartStyle] ?? chartStyle.rawValue
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = chartStyle.rawValue
                item.state = chartStyle == selected ? .on : .off
                item.image = Self.symbolImage(for: chartStyle)
                item.image?.isTemplate = true
                button.menu?.addItem(item)
            }

            button.selectItem(at: 0)
        }

        @objc func selectionChanged(_ sender: Any?) {
            guard !isRebuilding else { return }
            let raw = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String
            guard let raw, let next = TokenUsageChartStyle(rawValue: raw) else {
                button?.selectItem(at: 0)
                return
            }
            if style.wrappedValue != next {
                style.wrappedValue = next
            }
            rebuildMenu(titles: titles, selected: next)
        }

        private static func symbolImage(for style: TokenUsageChartStyle) -> NSImage? {
            let name: String
            switch style {
            case .heatmap: name = "square.grid.3x3.fill"
            case .line: name = "waveform.path"
            case .bar: name = "chart.bar.fill"
            }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: style.rawValue)
            image?.isTemplate = true
            return image
        }
    }
}

// MARK: - Line / bar chart

private enum TokenUsageTrendStyle {
    case line
    case bar
}

private struct TokenUsageTrendChartView: View {
    var series: TokenUsageChartSeries
    var style: TokenUsageTrendStyle
    var showsOfficialStats: Bool = true
    var l10n: L10n

    @StateObject private var hover = TrendHoverStore()

    private let plotHeight: CGFloat = 78
    private let labelHeight: CGFloat = 14
    private let labelSpacing: CGFloat = 6
    private let yAxisWidth: CGFloat = 36

    private var outerHeight: CGFloat { plotHeight + labelSpacing + labelHeight }

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = max(1, proxy.size.width - yAxisWidth)
            let layout = TrendLayoutMetrics(
                plotWidth: plotWidth,
                plotHeight: plotHeight,
                pointCount: series.points.count,
                maxTokens: series.points.map(\.tokens).max() ?? 0)

            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 0) {
                    yAxis(layout: layout)
                        .frame(width: yAxisWidth, height: plotHeight, alignment: .trailing)
                    VStack(alignment: .leading, spacing: labelSpacing) {
                        ZStack(alignment: .topLeading) {
                            StaticTrendCanvas(series: series, style: style, layout: layout)
                                .frame(width: plotWidth, height: plotHeight)
                            TrendPointerOverlay(layout: layout, hover: hover)
                                .frame(width: plotWidth, height: plotHeight)
                            hoverMarker(layout: layout)
                                .allowsHitTesting(false)
                        }
                        .frame(width: plotWidth, height: plotHeight)
                        monthAxis(layout: layout)
                            .frame(width: plotWidth, height: labelHeight, alignment: .leading)
                    }
                }
                hoverTooltip(
                    layout: layout,
                    containerSize: CGSize(width: proxy.size.width, height: outerHeight),
                    xOffset: yAxisWidth)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: outerHeight, alignment: .topLeading)
        }
        .frame(height: outerHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.text(.tokenUsageHeatmap))
        .accessibilityValue(accessibilitySummary)
        .onChange(of: series.points.count) { _ in
            hover.clear()
        }
    }

    private var accessibilitySummary: String {
        let total = TokenUsageHeatmapBuilder.compactTokenCount(series.totalTokens, language: l10n.language)
        return "\(total) \(l10n.text(.tokens))"
    }

    private func yAxis(layout: TrendLayoutMetrics) -> some View {
        let top = TokenUsageHeatmapBuilder.compactTokenCount(layout.maxTokens, language: l10n.language)
        let mid = TokenUsageHeatmapBuilder.compactTokenCount(layout.maxTokens / 2, language: l10n.language)
        return VStack(alignment: .trailing, spacing: 0) {
            Text(top)
            Spacer(minLength: 0)
            if layout.maxTokens > 0 {
                Text(mid)
                Spacer(minLength: 0)
            }
            Text("0")
        }
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        .padding(.trailing, 4)
    }

    private func monthAxis(layout: TrendLayoutMetrics) -> some View {
        let labels = monthLabels()
        return Canvas { context, _ in
            for label in labels {
                guard series.points.indices.contains(label.pointIndex) else { continue }
                let x = layout.xPosition(for: label.pointIndex)
                let text = Text(label.title)
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                context.draw(context.resolve(text), at: CGPoint(x: x, y: 0), anchor: .top)
            }
        }
    }

    private struct MonthLabel {
        var pointIndex: Int
        var title: String
    }

    private func monthLabels() -> [MonthLabel] {
        var result: [MonthLabel] = []
        var lastMonth: Int?
        let calendar = Calendar(identifier: .gregorian)
        for (index, point) in series.points.enumerated() {
            let month = calendar.component(.month, from: point.date)
            if month != lastMonth {
                result.append(MonthLabel(pointIndex: index, title: monthTitle(month)))
                lastMonth = month
            }
        }
        return result
    }

    private func monthTitle(_ month: Int) -> String {
        TokenUsageDateFormatting.monthTitle(month, language: l10n.language)
    }

    @ViewBuilder
    private func hoverMarker(layout: TrendLayoutMetrics) -> some View {
        if let index = hover.index, series.points.indices.contains(index) {
            let point = series.points[index]
            let x = layout.xPosition(for: index)
            let y = layout.yPosition(for: point.tokens)
            switch style {
            case .line:
                Circle()
                    .stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
                    .background(Circle().fill(Color(nsColor: .systemBlue)))
                    .frame(width: 8, height: 8)
                    .offset(x: x - 4, y: y - 4)
            case .bar:
                let bar = layout.barRect(for: index, tokens: point.tokens)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                    .frame(width: bar.width, height: bar.height)
                    .offset(x: bar.minX, y: bar.minY)
            }
        }
    }

    @ViewBuilder
    private func hoverTooltip(
        layout: TrendLayoutMetrics,
        containerSize: CGSize,
        xOffset: CGFloat
    ) -> some View {
        if let index = hover.index, series.points.indices.contains(index) {
            let point = series.points[index]
            let content = tooltipContent(for: point)
            let x = xOffset + layout.xPosition(for: index)
            let y = layout.yPosition(for: point.tokens)
            let cellRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
            let tooltipSize = TokenUsageTooltipLayout.size(
                for: content,
                cellRect: cellRect,
                containerSize: containerSize)
            let origin = HeatmapTooltipPlacement.origin(
                cellRect: cellRect,
                tooltipSize: tooltipSize,
                containerSize: containerSize)

            TokenUsageTooltipCard(content: content, size: tooltipSize)
                .offset(x: origin.x, y: origin.y)
                .accessibilityHidden(true)
        }
    }

    private func tooltipContent(for point: TokenUsageChartPoint) -> TokenUsageTooltipContent {
        let date = tooltipDateFormatter.string(from: point.date)
        return TokenUsageTooltipContent.make(
            date: date,
            officialTokens: point.allDevicesTokens,
            localTokens: point.localTokens,
            l10n: l10n,
            showsOfficialStats: showsOfficialStats)
    }

    private var tooltipDateFormatter: DateFormatter {
        TokenUsageDateFormatting.seriesTooltipFormatter(mode: series.mode, language: l10n.language)
    }
}

private struct TrendLayoutMetrics: Equatable {
    var plotWidth: CGFloat
    var plotHeight: CGFloat
    var pointCount: Int
    var maxTokens: Int

    private var step: CGFloat {
        guard pointCount > 1 else { return plotWidth }
        return plotWidth / CGFloat(pointCount - 1)
    }

    private var barSlot: CGFloat {
        guard pointCount > 0 else { return plotWidth }
        return plotWidth / CGFloat(pointCount)
    }

    var barWidth: CGFloat {
        min(12, max(1.5, barSlot * 0.62))
    }

    func xPosition(for index: Int) -> CGFloat {
        guard pointCount > 1 else { return plotWidth / 2 }
        return CGFloat(index) * step
    }

    func yPosition(for tokens: Int) -> CGFloat {
        guard maxTokens > 0 else { return plotHeight }
        let ratio = CGFloat(tokens) / CGFloat(maxTokens)
        return plotHeight * (1 - min(1, max(0, ratio)))
    }

    func barRect(for index: Int, tokens: Int) -> CGRect {
        let slot = barSlot
        let width = barWidth
        let x = CGFloat(index) * slot + (slot - width) / 2
        let y = yPosition(for: tokens)
        let height = max(0, plotHeight - y)
        return CGRect(x: x, y: y, width: width, height: max(height, tokens > 0 ? 1 : 0))
    }
}

private struct StaticTrendCanvas: View {
    var series: TokenUsageChartSeries
    var style: TokenUsageTrendStyle
    var layout: TrendLayoutMetrics

    var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)

            switch style {
            case .line:
                drawLine(context: &context)
            case .bar:
                drawBars(context: &context)
            }
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let grid = Color(nsColor: .separatorColor).opacity(0.35)
        var path = Path()
        // baseline
        path.move(to: CGPoint(x: 0, y: size.height - 0.5))
        path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        // mid
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(grid), lineWidth: 1)
    }

    private func drawLine(context: inout GraphicsContext) {
        let points = series.points
        guard !points.isEmpty else { return }
        let lineColor = Color(nsColor: .systemBlue)
        var line = Path()
        var fill = Path()
        for (index, point) in points.enumerated() {
            let x = layout.xPosition(for: index)
            let y = layout.yPosition(for: point.tokens)
            if index == 0 {
                line.move(to: CGPoint(x: x, y: y))
                fill.move(to: CGPoint(x: x, y: layout.plotHeight))
                fill.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                fill.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if let lastIndex = points.indices.last {
            let lastX = layout.xPosition(for: lastIndex)
            fill.addLine(to: CGPoint(x: lastX, y: layout.plotHeight))
            fill.closeSubpath()
        }
        context.fill(fill, with: .color(lineColor.opacity(0.16)))
        context.stroke(line, with: .color(lineColor), style: StrokeStyle(lineWidth: 1.75, lineJoin: .round))
    }

    private func drawBars(context: inout GraphicsContext) {
        let fill = Color(nsColor: .systemBlue).opacity(0.78)
        for (index, point) in series.points.enumerated() {
            let rect = layout.barRect(for: index, tokens: point.tokens)
            guard rect.height > 0 else { continue }
            let path = Path(roundedRect: rect, cornerRadius: min(2, rect.width / 2))
            context.fill(path, with: .color(fill))
        }
    }
}

private final class TrendHoverStore: ObservableObject {
    @Published private(set) var index: Int?

    func set(index: Int) {
        if self.index != index {
            self.index = index
        }
    }

    func clear() {
        if index != nil {
            index = nil
        }
    }
}

private struct TrendPointerOverlay: NSViewRepresentable {
    var layout: TrendLayoutMetrics
    var hover: TrendHoverStore

    func makeCoordinator() -> Coordinator {
        Coordinator(hover: hover)
    }

    func makeNSView(context: Context) -> TrendPointerNSView {
        let view = TrendPointerNSView()
        view.coordinator = context.coordinator
        context.coordinator.layout = layout
        context.coordinator.hover = hover
        return view
    }

    func updateNSView(_ nsView: TrendPointerNSView, context: Context) {
        context.coordinator.layout = layout
        context.coordinator.hover = hover
        nsView.coordinator = context.coordinator
        nsView.refreshTrackingAreasIfNeeded()
    }

    final class Coordinator {
        var layout: TrendLayoutMetrics
        var hover: TrendHoverStore

        init(hover: TrendHoverStore) {
            self.layout = TrendLayoutMetrics(plotWidth: 1, plotHeight: 1, pointCount: 0, maxTokens: 0)
            self.hover = hover
        }

        func handleMouse(at point: CGPoint, in bounds: CGRect) {
            guard bounds.contains(point), layout.pointCount > 0 else {
                hover.clear()
                return
            }
            let index: Int
            if layout.pointCount == 1 {
                index = 0
            } else {
                let step = layout.plotWidth / CGFloat(layout.pointCount - 1)
                index = min(layout.pointCount - 1, max(0, Int((point.x / step).rounded())))
            }
            hover.set(index: index)
        }
    }
}

private final class TrendPointerNSView: NSView {
    var coordinator: TrendPointerOverlay.Coordinator?
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
