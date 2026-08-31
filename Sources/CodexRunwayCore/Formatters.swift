import Foundation

public enum DurationFormatter {
    public static func localized(
        _ seconds: TimeInterval,
        language: ResolvedLanguage,
        includeSeconds: Bool = true)
        -> String
    {
        let value = max(0, Int(seconds.rounded(.up)))
        let days = value / 86_400
        let hours = (value % 86_400) / 3_600
        let minutes = (value % 3_600) / 60
        let seconds = value % 60
        let style = DurationUnitStyle(language: language)
        var parts: [String] = []
        if days > 0 {
            parts.append(style.unit(days, .day))
            if hours > 0 { parts.append(style.unit(hours, .hour)) }
            return style.join(parts)
        }
        if hours > 0 { parts.append(style.unit(hours, .hour)) }
        if minutes > 0 || hours > 0 { parts.append(style.unit(minutes, .minute)) }
        if includeSeconds || parts.isEmpty { parts.append(style.unit(seconds, .second)) }
        return style.join(parts)
    }

    public static func money(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        return "$" + String(format: "%.4f", number.doubleValue)
    }

    public static func relativePast(
        since date: Date,
        now: Date = Date(),
        language: ResolvedLanguage,
        includeSeconds: Bool = true)
        -> String
    {
        let interval = now.timeIntervalSince(date)
        // Minute granularity: callers that re-render on a timer use this so the
        // string only changes once per minute instead of every second.
        if !includeSeconds, interval < 60 {
            return DurationCopy.justNow(language)
        }
        let text = localized(interval, language: language, includeSeconds: includeSeconds)
        return DurationCopy.ago(text, language: language)
    }

    /// Single-unit past duration matching the hosted reset-today "no" copy.
    /// Future or invalid intervals return nil.
    public static func relativePastSingleUnit(
        since date: Date,
        now: Date = Date(),
        language: ResolvedLanguage) -> String?
    {
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite, interval >= 0 else { return nil }
        let seconds = Int(interval)
        let style = DurationUnitStyle(language: language)
        if seconds < 60 {
            return style.unit(max(seconds, 1), .second)
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return style.unit(minutes, .minute)
        }
        let hours = minutes / 60
        if hours < 24 {
            return style.unit(hours, .hour)
        }
        return style.unit(hours / 24, .day)
    }

    /// Compact absolute remaining duration (no "ago"/"in" wrapper), e.g. "3小时20分钟".
    public static func remaining(
        until date: Date,
        now: Date = Date(),
        language: ResolvedLanguage,
        includeSeconds: Bool = false)
        -> String
    {
        let interval = max(0, date.timeIntervalSince(now))
        if !includeSeconds, interval < 60 {
            return DurationCopy.underOneMinute(language)
        }
        return localized(interval, language: language, includeSeconds: includeSeconds)
    }

    /// Compact elapsed duration since a past moment, e.g. "3小时20分钟".
    public static func elapsed(
        since date: Date,
        now: Date = Date(),
        language: ResolvedLanguage,
        includeSeconds: Bool = false)
        -> String
    {
        let interval = max(0, now.timeIntervalSince(date))
        if !includeSeconds, interval < 60 {
            return DurationCopy.underOneMinute(language)
        }
        return localized(interval, language: language, includeSeconds: includeSeconds)
    }
}

public enum ResetLabelFormatter {
    public static func shortLabel(
        for date: Date,
        now: Date = Date(),
        language: ResolvedLanguage,
        calendar: Calendar = .autoupdatingCurrent)
        -> String
    {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: language.posixLocaleIdentifier)
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }

    public static func scheduledLabel(
        for window: RateLimitResetScheduleWindow,
        language: ResolvedLanguage,
        calendar: Calendar = .autoupdatingCurrent)
        -> String
    {
        let start = fullDateTime(window.startAt, language: language, calendar: calendar)
        guard window.isRange else { return start }
        let end = fullDateTime(window.endAt, language: language, calendar: calendar)
        return "\(start)~\(end)"
    }

    public static func scheduledCountdown(
        for window: RateLimitResetScheduleWindow,
        now: Date = Date(),
        language: ResolvedLanguage)
        -> String
    {
        let end = countdownDuration(until: window.endAt, now: now, language: language)
        guard window.isRange else { return end }
        let start = window.startAt > now
            ? countdownDuration(until: window.startAt, now: now, language: language)
            : DurationCopy.now(language)
        return "\(start)~\(end)"
    }

    private static func countdownDuration(
        until date: Date,
        now: Date,
        language: ResolvedLanguage) -> String
    {
        let totalSeconds = max(0, Int(date.timeIntervalSince(now).rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let style = DurationUnitStyle(language: language)
        var parts: [String] = []
        if hours > 0 { parts.append(style.unit(hours, .hour)) }
        if minutes > 0 || hours > 0 { parts.append(style.unit(minutes, .minute)) }
        parts.append(style.unit(seconds, .second))
        return style.join(parts)
    }

    private static func fullDateTime(
        _ date: Date,
        language: ResolvedLanguage,
        calendar: Calendar) -> String
    {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: language.posixLocaleIdentifier)
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }
}

public enum ResetCreditDateFormatter {
    public static func updatedAt(_ date: Date, language: ResolvedLanguage) -> String {
        let formatter = formatter(language: language, dateStyle: .medium, timeStyle: .short)
        return formatter.string(from: date)
    }

    public static func expiresAt(_ date: Date, language: ResolvedLanguage) -> String {
        let dateText = formatter(language: language, dateStyle: .short, timeStyle: .none).string(from: date)
        let timeText = formatter(language: language, dateStyle: .none, timeStyle: .short).string(from: date)
        return "\(dateText) \(timeText)"
    }

    private static func formatter(
        language: ResolvedLanguage,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style)
        -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.posixLocaleIdentifier)
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}

public enum SubscriptionDateFormatter {
    /// Stable calendar date for the account header (local timezone, no time-of-day).
    public static func expiresOn(
        _ date: Date,
        language: ResolvedLanguage,
        calendar: Calendar = .autoupdatingCurrent)
        -> String
    {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = language.locale
        // Fixed patterns avoid locale-style churn (e.g. "Jun 20, 2026" vs numeric).
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            formatter.dateFormat = "yyyy/M/d"
        case .russian, .french:
            formatter.dateFormat = "d MMM yyyy"
        case .english:
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    /// Treat the subscription as active for the entire local calendar day of `expiresAt`.
    public static func isExpired(
        _ expiresAt: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent)
        -> Bool
    {
        calendar.startOfDay(for: now) > calendar.startOfDay(for: expiresAt)
    }

    public static func endOfLocalDay(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent)
        -> Date
    {
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            return date
        }
        return next.addingTimeInterval(-1)
    }
}

public enum TokenUsageDateFormatting {
    public static func monthTitle(_ month: Int, language: ResolvedLanguage) -> String {
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return "\(month)月"
        case .korean:
            return "\(month)월"
        case .english, .russian, .french:
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = language.locale
            let symbols = calendar.shortMonthSymbols
            let index = max(0, min(symbols.count - 1, month - 1))
            return symbols[index]
        }
    }

    public static func mediumDateFormatter(
        language: ResolvedLanguage,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    public static func seriesTooltipFormatter(
        mode: TokenUsageHeatmapMode,
        language: ResolvedLanguage,
        timeZone: TimeZone = .autoupdatingCurrent)
        -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = language.locale
        switch mode {
        case .weekly:
            formatter.dateFormat = yearMonthDayPattern(language)
        case .cumulative:
            formatter.dateFormat = yearMonthPattern(language)
        case .daily:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter
    }

    private static func yearMonthDayPattern(_ language: ResolvedLanguage) -> String {
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return "yyyy年M月d日"
        case .korean:
            return "yyyy년 M월 d일"
        default:
            return "MMM d, yyyy"
        }
    }

    private static func yearMonthPattern(_ language: ResolvedLanguage) -> String {
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return "yyyy年M月"
        case .korean:
            return "yyyy년 M월"
        default:
            return "MMM yyyy"
        }
    }
}

enum DurationCopy {
    static func justNow(_ language: ResolvedLanguage) -> String {
        switch language {
        case .english:
            return "just now"
        case .simplifiedChinese:
            return "刚刚"
        case .traditionalChinese:
            return "剛剛"
        case .korean:
            return "방금"
        case .japanese:
            return "たった今"
        case .russian:
            return "только что"
        case .french:
            return "à l'instant"
        }
    }

    static func underOneMinute(_ language: ResolvedLanguage) -> String {
        switch language {
        case .english:
            return "under 1 minute"
        case .simplifiedChinese:
            return "不到1分钟"
        case .traditionalChinese:
            return "不到1分鐘"
        case .korean:
            return "1분 미만"
        case .japanese:
            return "1分未満"
        case .russian:
            return "меньше 1 минуты"
        case .french:
            return "moins d'1 minute"
        }
    }

    static func now(_ language: ResolvedLanguage) -> String {
        switch language {
        case .english:
            return "now"
        case .simplifiedChinese:
            return "现在"
        case .traditionalChinese:
            return "現在"
        case .korean:
            return "지금"
        case .japanese:
            return "現在"
        case .russian:
            return "сейчас"
        case .french:
            return "maintenant"
        }
    }

    static func ago(_ text: String, language: ResolvedLanguage) -> String {
        switch language {
        case .english:
            return "\(text) ago"
        case .simplifiedChinese, .traditionalChinese:
            return "\(text)之前"
        case .korean:
            return "\(text) 전"
        case .japanese:
            return "\(text)前"
        case .russian:
            return "\(text) назад"
        case .french:
            return "il y a \(text)"
        }
    }
}

private struct DurationUnitStyle {
    enum Unit {
        case day, hour, minute, second
    }

    var language: ResolvedLanguage

    func join(_ parts: [String]) -> String {
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return parts.joined()
        default:
            return parts.joined(separator: " ")
        }
    }

    func unit(_ value: Int, _ unit: Unit) -> String {
        switch language {
        case .simplifiedChinese:
            switch unit {
            case .day: return "\(value)天"
            case .hour: return "\(value)小时"
            case .minute: return "\(value)分钟"
            case .second: return "\(value)秒"
            }
        case .traditionalChinese:
            switch unit {
            case .day: return "\(value)天"
            case .hour: return "\(value)小時"
            case .minute: return "\(value)分鐘"
            case .second: return "\(value)秒"
            }
        case .japanese:
            switch unit {
            case .day: return "\(value)日"
            case .hour: return "\(value)時間"
            case .minute: return "\(value)分"
            case .second: return "\(value)秒"
            }
        case .korean:
            switch unit {
            case .day: return "\(value)일"
            case .hour: return "\(value)시간"
            case .minute: return "\(value)분"
            case .second: return "\(value)초"
            }
        case .russian:
            switch unit {
            case .day:
                return russianPlural(value, one: "день", few: "дня", many: "дней")
            case .hour:
                return russianPlural(value, one: "час", few: "часа", many: "часов")
            case .minute:
                return russianPlural(value, one: "минута", few: "минуты", many: "минут")
            case .second:
                return russianPlural(value, one: "секунда", few: "секунды", many: "секунд")
            }
        case .french:
            switch unit {
            case .day: return french(value, singular: "jour", plural: "jours")
            case .hour: return french(value, singular: "heure", plural: "heures")
            case .minute: return french(value, singular: "minute", plural: "minutes")
            case .second: return french(value, singular: "seconde", plural: "secondes")
            }
        case .english:
            switch unit {
            case .day: return english(value, singular: "day", plural: "days")
            case .hour: return english(value, singular: "hour", plural: "hours")
            case .minute: return english(value, singular: "minute", plural: "minutes")
            case .second: return english(value, singular: "second", plural: "seconds")
            }
        }
    }

    private func english(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private func french(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value <= 1 ? singular : plural)"
    }

    private func russianPlural(_ value: Int, one: String, few: String, many: String) -> String {
        let absValue = abs(value)
        let mod10 = absValue % 10
        let mod100 = absValue % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = one
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = few
        } else {
            word = many
        }
        return "\(value) \(word)"
    }
}
