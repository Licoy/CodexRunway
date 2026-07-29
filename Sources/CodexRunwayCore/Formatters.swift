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
        if language == .simplifiedChinese {
            var parts: [String] = []
            if days > 0 {
                parts.append("\(days)天")
                if hours > 0 { parts.append("\(hours)小时") }
                return parts.joined()
            }
            if hours > 0 { parts.append("\(hours)小时") }
            if minutes > 0 || hours > 0 { parts.append("\(minutes)分钟") }
            if includeSeconds || parts.isEmpty { parts.append("\(seconds)秒") }
            return parts.joined()
        }
        var parts: [String] = []
        if days > 0 {
            parts.append(unit(days, singular: "day", plural: "days"))
            if hours > 0 { parts.append(unit(hours, singular: "hour", plural: "hours")) }
            return parts.joined(separator: " ")
        }
        if hours > 0 { parts.append(unit(hours, singular: "hour", plural: "hours")) }
        if minutes > 0 || hours > 0 { parts.append(unit(minutes, singular: "minute", plural: "minutes")) }
        if includeSeconds || parts.isEmpty { parts.append(unit(seconds, singular: "second", plural: "seconds")) }
        return parts.joined(separator: " ")
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
            return language == .simplifiedChinese ? "刚刚" : "just now"
        }
        let text = localized(interval, language: language, includeSeconds: includeSeconds)
        return language == .simplifiedChinese ? "\(text)之前" : "\(text) ago"
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
            return language == .simplifiedChinese ? "不到1分钟" : "under 1 minute"
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
            return language == .simplifiedChinese ? "不到1分钟" : "under 1 minute"
        }
        return localized(interval, language: language, includeSeconds: includeSeconds)
    }

    private static func unit(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
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
        formatter.locale = Locale(identifier: language == .simplifiedChinese ? "zh_Hans_CN" : "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d"
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
        formatter.locale = Locale(identifier: language == .simplifiedChinese ? "zh_Hans_CN" : "en_US_POSIX")
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
        formatter.locale = Locale(identifier: language == .simplifiedChinese ? "zh_Hans_CN" : "en_US_POSIX")
        // Fixed patterns avoid locale-style churn (e.g. "Jun 20, 2026" vs numeric).
        formatter.dateFormat = language == .simplifiedChinese ? "yyyy/M/d" : "MMM d, yyyy"
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
