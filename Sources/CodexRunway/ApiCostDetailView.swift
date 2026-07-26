import AppKit
import CodexRunwayCore
import SwiftUI

struct ApiCostDetailView: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n

    @State private var selectedRange: ApiCostRangeMode = .today
    @State private var customStartDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var customEndDate = Date()
    @State private var isLoading = false
    @State private var transientDetail: ApiEquivalentSummary?
    @State private var transientRange: ApiCostRangeMode?
    @State private var queryError: String?
    @State private var didQueryInitialRange = false
    @State private var pendingQuery: ApiCostDetailQuery?

    init(model: RunwayModel, l10n: L10n, initialRange: ApiCostSummaryRange = .today) {
        self.model = model
        self.l10n = l10n
        _selectedRange = State(initialValue: ApiCostRangeMode(initialRange))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            rangeControls
            if isLoading {
                loadingState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    detailContent
                }
            }
        }
        .padding(.top, 2)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            guard !didQueryInitialRange else { return }
            didQueryInitialRange = true
            rangeChanged(selectedRange)
        }
        .task(id: pendingQuery?.id) {
            guard let pendingQuery else { return }
            // Do not cancel the underlying model scan when leaving the page;
            // only ignore the result if this query is no longer active.
            await queryCost(pendingQuery)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail = activeDetail, detail.isDisplayableCost {
                header(detail)
                scanNoteText
                statGrid(detail)
                tokenParts(detail.totals)
                usageRows(detail.dailyRows, title: activeRangeTitle)
                breakdown(l10n.text(.projectBreakdown), rows: detail.projectRows)
                breakdown(l10n.text(.modelBreakdown), rows: detail.modelRows)
                breakdown(l10n.text(.apiCostSource), rows: detail.clientRows)
                rawReference(detail)
            } else if selectedRange == .custom, transientRange != .custom {
                // Idle custom tab: ask the user to pick dates instead of showing "unavailable".
                Text(l10n.text(.customRangePrompt))
                    .foregroundStyle(.secondary)
                scanNoteText
            } else if let detail = activeDetail, !detail.isDisplayableCost {
                Text(l10n.text(.usageAnalyticsEmpty))
                    .foregroundStyle(.secondary)
                scanNoteText
            } else {
                Text(l10n.text(.usageAnalyticsUnavailable))
                    .foregroundStyle(.secondary)
                scanNoteText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeDetail: ApiEquivalentSummary? {
        if selectedRange == .current {
            if transientRange == .current, let transientDetail { return transientDetail }
            return model.costDetail
        }
        guard transientRange == selectedRange else { return nil }
        return transientDetail
    }

    private var activeRangeTitle: String {
        if selectedRange == .current { return l10n.text(.currentCycle) }
        return selectedRange.title(l10n)
    }

    @ViewBuilder
    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            rangePicker

            if selectedRange == .custom, !isLoading {
                customControls
            }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 1) {
            ForEach(ApiCostRangeMode.allCases) { range in
                ApiCostRangeTabButton(
                    title: range.title(l10n),
                    isSelected: selectedRange == range)
                {
                    selectedRange = range
                    rangeChanged(range)
                }
            }
        }
        .padding(2)
        .fixedSize(horizontal: false, vertical: true)
        .runwayCard(.sunken, cornerRadius: RunwaySurface.radiusRow + 1)
        .frame(maxWidth: .infinity)
    }

    private var loadingState: some View {
        CostScanLoadingView(costProgress: model.costProgress, l10n: l10n)
    }

    private var customControls: some View {
        HStack(spacing: 8) {
            FullWidthDateField(
                title: l10n.text(.startDate),
                date: $customStartDate,
                range: minimumCustomDate...maximumCustomDate)

            FullWidthDateField(
                title: l10n.text(.endDate),
                date: $customEndDate,
                range: minimumCustomDate...maximumCustomDate)

            CustomRangeCalculateButton(
                title: isLoading ? l10n.text(.calculating) : l10n.text(.calculate),
                isLoading: isLoading,
                action: calculateCustomRange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: customStartDate) { newValue in
            if newValue > customEndDate {
                customEndDate = newValue
            }
        }
        .onChange(of: customEndDate) { newValue in
            if newValue < customStartDate {
                customStartDate = newValue
            }
        }
    }

    private var minimumCustomDate: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .month, value: -24, to: Date()) ?? Date()
    }

    private var maximumCustomDate: Date {
        Date()
    }

    private func header(_ detail: ApiEquivalentSummary) -> some View {
        RunwayPageSummaryRow(
            title: l10n.text(.apiCost),
            meta: "\(l10n.text(.calculatedAt)) \(calculatedText(detail.calculatedAt)) · \(detail.pricingVersion) · \(sourceText(detail.source))",
            figure: detail.estimatedUSD.map(DurationFormatter.money) ?? l10n.text(.tokensOnly))
    }

    @ViewBuilder
    private var scanNoteText: some View {
        if let scanNote = activeScanNote {
            Text("\(l10n.text(.costScanFailed)): \(scanNote)")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var activeScanNote: String? {
        // Prefer the in-page query error so cycle tabs don't keep a stale main-panel note.
        queryError ?? (selectedRange == .current ? model.costScanNote : nil)
    }

    private func statGrid(_ detail: ApiEquivalentSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            RunwayStatCard(title: l10n.text(.estimatedAPICost), value: detail.estimatedUSD.map(DurationFormatter.money) ?? "--", color: .green)
            RunwayStatCard(title: l10n.text(.tokens), value: Self.tokenText(detail.totals.totalTokens), color: .blue)
            RunwayStatCard(title: l10n.text(.inputCachedOutput), value: "\(Self.tokenText(detail.totals.uncachedInputTokens)) / \(Self.tokenText(detail.totals.cachedInputTokens)) / \(Self.tokenText(detail.totals.outputTokens))", color: .teal)
            RunwayStatCard(title: l10n.text(.turns), value: "\(detail.totals.turns)", color: .orange)
        }
    }

    private func tokenParts(_ totals: ApiEquivalentTotals) -> some View {
        HStack(spacing: 8) {
            RunwayStatCard(title: l10n.text(.nonCachedInput), value: Self.tokenText(totals.uncachedInputTokens), color: .blue)
            RunwayStatCard(title: l10n.text(.cachedInput), value: Self.tokenText(totals.cachedInputTokens), color: .green)
            RunwayStatCard(title: l10n.text(.outputTokens), value: Self.tokenText(totals.outputTokens), color: .orange)
        }
    }

    private func usageRows(_ rows: [ApiEquivalentDailyRow], title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if rows.isEmpty {
                Text(l10n.text(.notLoaded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RunwayTableContainer {
                    UsageTableHeader(l10n: l10n)
                } rows: {
                    ForEach(Array(rows.reversed().enumerated()), id: \.element.id) { index, row in
                        UsageTableRow(row: row, isFirst: index == 0)
                    }
                }
            }
        }
    }

    private func rangeChanged(_ range: ApiCostRangeMode) {
        queryError = nil
        switch range {
        case .today:
            scheduleQuery(.fixed(ApiCostRange.today()), mode: range)
        case .current:
            scheduleQuery(.currentCycle, mode: range)
        case .previous:
            if let costRange = model.previousCycleCostRange() {
                scheduleQuery(.fixed(costRange), mode: range)
            } else {
                scheduleQuery(.previousCycle, mode: range)
            }
        case .thisMonth:
            scheduleQuery(.fixed(ApiCostRange.thisMonth()), mode: range)
        case .custom:
            cancelPendingQuery()
            queryError = nil
            // Stay idle until the user picks dates and clicks Calculate.
            if transientRange != .custom {
                transientDetail = nil
            }
            prepareCustomDates()
        }
    }

    private func prepareCustomDates() {
        guard let detail = model.costDetail else { return }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: detail.window.start)
        let end = min(maximumCustomDate, detail.window.end)
        customStartDate = start
        customEndDate = max(start, end)
    }

    private func calculateCustomRange() {
        guard let range = ApiCostRange.custom(start: customStartDate, end: customEndDate) else {
            queryError = l10n.text(.invalidDateRange)
            return
        }
        scheduleQuery(.fixed(range), mode: .custom)
    }

    private func scheduleQuery(_ target: ApiCostDetailTarget, mode: ApiCostRangeMode) {
        isLoading = true
        queryError = nil
        // Keep previous results for the same mode until new data arrives when re-entering.
        if transientRange != mode {
            transientDetail = nil
            transientRange = nil
        }
        pendingQuery = ApiCostDetailQuery(target: target, mode: mode)
    }

    private func cancelPendingQuery() {
        pendingQuery = nil
        isLoading = false
    }

    @MainActor
    private func queryCost(_ query: ApiCostDetailQuery) async {
        do {
            let detail: ApiEquivalentSummary
            switch query.target {
            case .fixed(let range):
                detail = try await model.queryCost(range: range)
            case .currentCycle:
                detail = try await model.queryCurrentCycleCost()
            case .previousCycle:
                let range = try await model.resolvePreviousCycleCostRange()
                detail = try await model.queryCost(range: range)
            }
            guard isActive(query) else { return }
            transientDetail = detail
            transientRange = query.mode
            isLoading = false
            if !detail.isDisplayableCost {
                queryError = nil
            }
        } catch is CancellationError {
            // Leaving the page or switching range: leave in-flight work to the model cache.
            guard isActive(query) else { return }
            isLoading = false
        } catch {
            guard isActive(query) else { return }
            queryError = error is CostRangeQueryError
                ? l10n.text(.usageAnalyticsUnavailable)
                : error.localizedDescription
            transientDetail = nil
            transientRange = query.mode
            isLoading = false
        }
    }

    private func isActive(_ query: ApiCostDetailQuery) -> Bool {
        pendingQuery?.id == query.id
    }

    @ViewBuilder
    private func breakdown(_ title: String, rows: [ApiEquivalentBreakdownRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(8).enumerated()), id: \.element.id) { index, row in
                        BreakdownRow(row: row, isFirst: index == 0)
                    }
                }
                .runwayCard(.sunken)
            }
        }
    }

    @ViewBuilder
    private func rawReference(_ detail: ApiEquivalentSummary) -> some View {
        if detail.source == .onlineAnalytics {
            Text("\(l10n.text(.rawAnalyticsCredits)): \(String(format: "%.3f", detail.rawCredits))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceText(_ source: ApiEquivalentSource) -> String {
        switch source {
        case .localSessions:
            return l10n.text(.sourceLocalSessions)
        case .onlineAnalytics:
            return l10n.text(.sourceOnlineSupplement)
        case .unavailable:
            return l10n.text(.usageAnalyticsUnavailable)
        }
    }

    private func calculatedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: l10n.language == .simplifiedChinese ? "zh_Hans_CN" : "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func tokenText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// Observes the high-frequency scan progress in isolation, so its ticks only
/// re-render this small subtree instead of the whole detail page.
private struct CostScanLoadingView: View {
    @ObservedObject var costProgress: CostProgressModel
    var l10n: L10n

    var body: some View {
        let progress = costProgress.progress
        VStack(spacing: 12) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
            Text(progressTitle(progress))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let subtitle = progressSubtitle(progress) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
    }

    private func progressTitle(_ progress: CostScanProgress) -> String {
        switch progress.phase {
        case .preparing:
            return l10n.text(.costScanPreparing)
        case .refreshingIndex:
            return l10n.text(.costScanIndexing)
        case .aggregating:
            return l10n.text(.costScanAggregating)
        case .fetchingOnline:
            return l10n.text(.costScanFetchingOnline)
        case .failed:
            return progress.message ?? l10n.text(.costScanFailed)
        case .idle, .finished:
            return l10n.text(.calculating)
        }
    }

    private func progressSubtitle(_ progress: CostScanProgress) -> String? {
        var parts: [String] = []
        if let total = progress.totalUnits, total > 0 {
            parts.append(String(
                format: l10n.text(.costScanProgressFiles),
                progress.completedUnits,
                total))
        }
        if let detail = progress.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Native-style segment: a raised thumb marks the selection instead of an accent slab.
private struct ApiCostRangeTabButton: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var thumb: RoundedRectangle {
        RoundedRectangle(cornerRadius: RunwaySurface.radiusControl, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .background(thumbFill)
        // Expand only horizontally so the full tab width is clickable; keep compact height.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .help(title)
    }

    @ViewBuilder
    private var thumbFill: some View {
        if isSelected {
            // Accent thumb reads as the app's theme in both schemes.
            if colorScheme == .light {
                thumb
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 2.5, y: 1)
            } else {
                thumb.fill(Color.accentColor)
            }
        } else if isHovered {
            thumb.fill(Color.primary.opacity(0.05))
        } else {
            Color.clear
        }
    }
}

private enum ApiCostDetailTarget: Equatable {
    case fixed(ApiCostRange)
    case currentCycle
    case previousCycle
}

private struct ApiCostDetailQuery: Equatable {
    let id = UUID()
    var target: ApiCostDetailTarget
    var mode: ApiCostRangeMode
}

private enum ApiCostRangeMode: String, CaseIterable, Identifiable {
    case today
    case current
    case previous
    case thisMonth
    case custom

    var id: String { rawValue }

    init(_ range: ApiCostSummaryRange) {
        switch range {
        case .today:
            self = .today
        case .current:
            self = .current
        case .previous:
            self = .previous
        case .thisMonth:
            self = .thisMonth
        }
    }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .today:
            return l10n.text(.today)
        case .current:
            return l10n.text(.currentCycle)
        case .previous:
            return l10n.text(.previousCycle)
        case .thisMonth:
            return l10n.text(.thisMonth)
        case .custom:
            return l10n.text(.customRange)
        }
    }
}

/// Full-width date field: stretches to fill its HStack share, opens a single-day picker.
private struct FullWidthDateField: View {
    var title: String
    @Binding var date: Date
    var range: ClosedRange<Date>

    @State private var isPresented = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(formattedDate)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous)
                    .strokeBorder(fieldStroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(title), \(formattedDate)")
        .frame(maxWidth: .infinity)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                BorderlessCalendarDatePicker(date: $date, range: range)
                    .fixedSize()
            }
            .padding(12)
            .fixedSize()
        }
    }

    private var isActive: Bool {
        isHovered || isPresented
    }

    private var fieldBackground: Color {
        if isPresented {
            return Color.accentColor.opacity(0.10)
        }
        if isHovered {
            return RunwaySurface.hoverNeutral
        }
        return RunwaySurface.raised
    }

    private var fieldStroke: Color {
        if isPresented {
            return Color.accentColor.opacity(0.5)
        }
        return colorScheme == .dark ? RunwaySurface.hairline : Color.clear
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        // Fixed numeric form so both languages stay fully visible: 2020/01/01
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

/// Borderless AppKit calendar. Host reports the picker's natural size so the popover hugs it
/// with no empty margins; the picker is centered if the host is ever larger.
private struct BorderlessCalendarDatePicker: NSViewRepresentable {
    @Binding var date: Date
    var range: ClosedRange<Date>

    func makeCoordinator() -> Coordinator {
        Coordinator(date: $date)
    }

    func makeNSView(context: Context) -> CalendarHostView {
        let host = CalendarHostView()
        host.picker.target = context.coordinator
        host.picker.action = #selector(Coordinator.valueChanged(_:))
        context.coordinator.apply(date: date, range: range, to: host.picker)
        host.recalculateIntrinsicSize()
        return host
    }

    func updateNSView(_ host: CalendarHostView, context: Context) {
        context.coordinator.date = $date
        context.coordinator.apply(date: date, range: range, to: host.picker)
        host.recalculateIntrinsicSize()
        host.needsLayout = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>

        init(date: Binding<Date>) {
            self.date = date
        }

        func apply(date: Date, range: ClosedRange<Date>, to picker: NSDatePicker) {
            picker.minDate = range.lowerBound
            picker.maxDate = range.upperBound
            if picker.dateValue != date {
                picker.dateValue = date
            }
        }

        @objc func valueChanged(_ sender: NSDatePicker) {
            date.wrappedValue = sender.dateValue
        }
    }
}

@MainActor
private final class CalendarHostView: NSView {
    let picker: NSDatePicker = {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.isBordered = false
        picker.drawsBackground = false
        picker.isBezeled = false
        picker.focusRingType = .none
        return picker
    }()

    private var measuredSize = CGSize(width: 240, height: 210)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        measuredSize
    }

    func recalculateIntrinsicSize() {
        picker.sizeToFit()
        let fitted = picker.fittingSize
        guard fitted.width > 1, fitted.height > 1 else { return }
        if fitted != measuredSize {
            measuredSize = fitted
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()
        recalculateIntrinsicSize()
        let size = measuredSize
        // Center horizontally and vertically when the host is larger than the calendar.
        let x = max(0, ((bounds.width - size.width) / 2).rounded(.toNearestOrAwayFromZero))
        let y = max(0, ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero))
        picker.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private struct CustomRangeCalculateButton: View {
    var title: String
    var isLoading: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 68, minHeight: 30)
                .background(
                    (isHovered && !isLoading ? Color.accentColor.opacity(0.88) : Color.accentColor),
                    in: RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusRow, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.72 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .pointingHandCursor(enabled: !isLoading)
        .onHover { isHovered = $0 }
    }
}

private struct UsageTableHeader: View {
    var l10n: L10n

    var body: some View {
        HStack {
            Text(l10n.text(.date)).frame(width: 78, alignment: .leading)
            Text(l10n.text(.tokens)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(l10n.text(.estimatedAPICost)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(l10n.text(.turns)).frame(width: 42, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct UsageTableRow: View {
    var row: ApiEquivalentDailyRow
    var isFirst: Bool

    var body: some View {
        HStack {
            Text(row.date).frame(width: 78, alignment: .leading)
            Text(Self.tokenText(row.totals.totalTokens)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.estimatedUSD.map(DurationFormatter.money) ?? "--").frame(maxWidth: .infinity, alignment: .trailing)
            Text("\(row.totals.turns)").frame(width: 42, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .tableRowRule(isFirst: isFirst)
    }

    private static func tokenText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct BreakdownRow: View {
    var row: ApiEquivalentBreakdownRow
    var isFirst: Bool

    var body: some View {
        HStack {
            Text(row.name)
                .lineLimit(1)
            Spacer()
            Text(Self.tokenText(row.totals.totalTokens))
                .foregroundStyle(.secondary)
            Text(row.estimatedUSD.map(DurationFormatter.money) ?? "--")
                .frame(width: 82, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .tableRowRule(isFirst: isFirst)
    }

    private static func tokenText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
