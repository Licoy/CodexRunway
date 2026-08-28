import Foundation

public enum RateLimitResetTodayConfidenceBand: String, Codable, Sendable, Equatable {
    case ok
    case warn
}

/// Homepage-aligned hero: completed is “Yes”; scheduled is percent + “Yes”.
public struct RateLimitResetTodayVerdictPresentation: Sendable, Equatable {
    public static let okPercent = 80

    public var showsYes: Bool
    public var percent: Int?
    public var band: RateLimitResetTodayConfidenceBand?
    public var isScheduled: Bool
    public var isCompleted: Bool
    public var resetType: RateLimitResetType?

    public init(
        showsYes: Bool,
        percent: Int?,
        band: RateLimitResetTodayConfidenceBand?,
        isScheduled: Bool,
        isCompleted: Bool,
        resetType: RateLimitResetType?)
    {
        self.showsYes = showsYes
        self.percent = percent
        self.band = band
        self.isScheduled = isScheduled
        self.isCompleted = isCompleted
        self.resetType = resetType
    }

    public static func displayedPercent(_ confidence: Double) -> Int {
        Int((confidence * 100).rounded())
    }

    public static func band(for percent: Int) -> RateLimitResetTodayConfidenceBand {
        percent >= okPercent ? .ok : .warn
    }

    public func percentText(l10n: L10n) -> String? {
        guard let percent else { return nil }
        let key: L10nKey = percent == 100
            ? .rateLimitResetTodayPercentExact
            : .rateLimitResetTodayPercentPrefix
        return String(format: l10n.text(key), "\(percent)")
    }

    public func answerText(l10n: L10n) -> String {
        l10n.text(showsYes ? .rateLimitResetTodayYes : .rateLimitResetTodayNo)
    }

    public func titleText(l10n: L10n) -> String {
        let answer = answerText(l10n: l10n)
        guard let percentText = percentText(l10n: l10n) else { return answer }
        return percentText + answer
    }
}

public enum RateLimitResetTodayDetailToken: Equatable, Sendable {
    case text(String)
    case resetType
    case percent
    case time
}

public struct RateLimitResetTodayDetailPresentation: Sendable, Equatable {
    public var tokens: [RateLimitResetTodayDetailToken]
    public var resetType: RateLimitResetType?
    public var typeLabel: String
    public var percentText: String?
    public var timeText: String?
    public var plainText: String

    public init(
        tokens: [RateLimitResetTodayDetailToken],
        resetType: RateLimitResetType?,
        typeLabel: String,
        percentText: String?,
        timeText: String?,
        plainText: String)
    {
        self.tokens = tokens
        self.resetType = resetType
        self.typeLabel = typeLabel
        self.percentText = percentText
        self.timeText = timeText
        self.plainText = plainText
    }
}

extension RateLimitResetTodaySnapshot {
    public func verdictPresentation(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar)
        -> RateLimitResetTodayVerdictPresentation
    {
        if resolvedState(now: now, calendar: calendar) == .unknown {
            return RateLimitResetTodayVerdictPresentation(
                showsYes: false,
                percent: nil,
                band: nil,
                isScheduled: false,
                isCompleted: false,
                resetType: nil)
        }
        if hasAlreadyEffectiveResetToday(now: now, calendar: calendar) {
            return RateLimitResetTodayVerdictPresentation(
                showsYes: true,
                percent: nil,
                band: nil,
                isScheduled: false,
                isCompleted: true,
                resetType: displayResetType(now: now, calendar: calendar))
        }
        if let next = nextScheduledReset(now: now) {
            let percent = RateLimitResetTodayVerdictPresentation.displayedPercent(next.event.confidence)
            return RateLimitResetTodayVerdictPresentation(
                showsYes: true,
                percent: percent,
                band: RateLimitResetTodayVerdictPresentation.band(for: percent),
                isScheduled: true,
                isCompleted: false,
                resetType: next.event.resetType)
        }
        return RateLimitResetTodayVerdictPresentation(
            showsYes: false,
            percent: nil,
            band: nil,
            isScheduled: false,
            isCompleted: false,
            resetType: nil)
    }

    public func verdictDetail(
        l10n: L10n,
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar)
        -> RateLimitResetTodayDetailPresentation?
    {
        let presentation = verdictPresentation(now: now, calendar: calendar)
        if presentation.isCompleted {
            return confirmedDetail(l10n: l10n, now: now, calendar: calendar, presentation: presentation)
        }
        guard presentation.isScheduled,
              let next = nextScheduledReset(now: now),
              next.event.scheduleBasis != .contextualInference
        else {
            return nil
        }
        return scheduledChanceDetail(
            next,
            l10n: l10n,
            calendar: calendar,
            presentation: presentation)
    }

    public func scheduleConfidenceBand(for event: RateLimitResetTodayEvent)
        -> RateLimitResetTodayConfidenceBand
    {
        RateLimitResetTodayVerdictPresentation.band(
            for: RateLimitResetTodayVerdictPresentation.displayedPercent(event.confidence))
    }
}

enum RateLimitResetTodayCopy {
    static func replace(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    static func tokens(_ template: String) -> [RateLimitResetTodayDetailToken] {
        let marks: [(needle: String, token: RateLimitResetTodayDetailToken)] = [
            ("{type}", .resetType),
            ("{percent}", .percent),
            ("{when}", .time),
            ("{date}", .time),
        ]
        var segments: [RateLimitResetTodayDetailToken] = []
        var start = template.startIndex
        while start < template.endIndex {
            var next: (range: Range<String.Index>, token: RateLimitResetTodayDetailToken)?
            for mark in marks {
                guard let range = template.range(of: mark.needle, range: start..<template.endIndex)
                else { continue }
                if next == nil || range.lowerBound < next!.range.lowerBound {
                    next = (range, mark.token)
                }
            }
            guard let next else {
                let rest = String(template[start...])
                if !rest.isEmpty { segments.append(.text(rest)) }
                break
            }
            if next.range.lowerBound > start {
                segments.append(.text(String(template[start..<next.range.lowerBound])))
            }
            segments.append(next.token)
            start = next.range.upperBound
        }
        return segments.isEmpty ? [.text(template)] : segments
    }
}

private extension RateLimitResetTodaySnapshot {
    func confirmedDetail(
        l10n: L10n,
        now: Date,
        calendar: Calendar,
        presentation: RateLimitResetTodayVerdictPresentation)
        -> RateLimitResetTodayDetailPresentation?
    {
        guard let resetAt = latestResetAt(now: now),
              let ago = DurationFormatter.relativePastSingleUnit(
                  since: resetAt,
                  now: now,
                  language: l10n.language)
        else {
            return nil
        }
        let resetType = presentation.resetType ?? .global
        let typeLabel = resetType.localizedName(l10n: l10n)
        let zone = l10n.text(.rateLimitResetTodayClockLocal)
        let time = ResetLabelFormatter.scheduledLabel(
            for: RateLimitResetScheduleWindow(startAt: resetAt, endAt: resetAt, isRange: false),
            language: l10n.language,
            calendar: calendar)
        let when = String(format: l10n.text(.rateLimitResetTodayConfirmedWhen), time, ago)
        let confidence = primaryEvidenceEvent(now: now, calendar: calendar)?.confidence
        let percentText: String?
        if let confidence {
            percentText = "\(RateLimitResetTodayVerdictPresentation.displayedPercent(confidence))%"
        } else {
            percentText = nil
        }
        let key: L10nKey = percentText == nil
            ? .rateLimitResetTodayConfirmedHintNoPercent
            : .rateLimitResetTodayConfirmedHint
        var values = [
            "type": typeLabel,
            "zone": zone,
            "when": when,
        ]
        if let percentText {
            values["percent"] = percentText
        }
        let template = RateLimitResetTodayCopy.replace(l10n.text(key), ["zone": zone])
        return RateLimitResetTodayDetailPresentation(
            tokens: RateLimitResetTodayCopy.tokens(template),
            resetType: resetType,
            typeLabel: typeLabel,
            percentText: percentText,
            timeText: when,
            plainText: RateLimitResetTodayCopy.replace(l10n.text(key), values))
    }

    func scheduledChanceDetail(
        _ next: (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent),
        l10n: L10n,
        calendar: Calendar,
        presentation: RateLimitResetTodayVerdictPresentation)
        -> RateLimitResetTodayDetailPresentation?
    {
        guard let percentText = presentation.percentText(l10n: l10n) else { return nil }
        let resetType = next.event.resetType
        let typeLabel = resetType.localizedName(l10n: l10n)
        let zone = l10n.text(.rateLimitResetTodayClockLocal)
        let date = ResetLabelFormatter.scheduledLabel(
            for: RateLimitResetScheduleWindow(
                startAt: next.effectiveAt,
                endAt: next.effectiveUntil,
                isRange: next.isRange),
            language: l10n.language,
            calendar: calendar)
        let values = [
            "percent": percentText,
            "type": typeLabel,
            "zone": zone,
            "date": date,
        ]
        let raw = l10n.text(.rateLimitResetTodayScheduledChanceHint)
        let template = RateLimitResetTodayCopy.replace(raw, ["zone": zone, "percent": percentText])
        return RateLimitResetTodayDetailPresentation(
            tokens: RateLimitResetTodayCopy.tokens(template),
            resetType: resetType,
            typeLabel: typeLabel,
            percentText: percentText,
            timeText: date,
            plainText: RateLimitResetTodayCopy.replace(raw, values))
    }
}
