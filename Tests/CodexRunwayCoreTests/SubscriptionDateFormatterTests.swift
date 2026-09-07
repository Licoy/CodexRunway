import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Subscription expiry dates")
struct SubscriptionDateFormatterTests {
    @Test("local expiry includes the correct date, time and offset", arguments: [
        ("UTC", "2026-09-07T20:30:00Z", "2026/9/7", "20:30:00", "UTC+00:00"),
        ("Asia/Singapore", "2026-09-07T20:30:00Z", "2026/9/8", "04:30:00", "UTC+08:00"),
        ("Asia/Kolkata", "2026-09-07T20:30:00Z", "2026/9/8", "02:00:00", "UTC+05:30"),
        ("America/Los_Angeles", "2026-09-07T20:30:00Z", "2026/9/7", "13:30:00", "UTC-07:00"),
        ("America/Los_Angeles", "2026-03-08T09:59:59Z", "2026/3/8", "01:59:59", "UTC-08:00"),
        ("America/Los_Angeles", "2026-03-08T10:00:00Z", "2026/3/8", "03:00:00", "UTC-07:00"),
        ("America/Los_Angeles", "2026-11-01T08:30:00Z", "2026/11/1", "01:30:00", "UTC-07:00"),
        ("America/Los_Angeles", "2026-11-01T09:30:00Z", "2026/11/1", "01:30:00", "UTC-08:00"),
    ])
    func localDateTime(example: (String, String, String, String, String)) throws {
        let (timeZoneID, timestamp, dateText, timeText, offsetText) = example
        let expiry = try #require(RunwayDates.parse(timestamp))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneID))

        #expect(SubscriptionDateFormatter.expiresOn(
            expiry, language: .simplifiedChinese, calendar: calendar) == dateText)
        #expect(SubscriptionDateFormatter.expiresAt(
            expiry, language: .simplifiedChinese, calendar: calendar)
            == "\(dateText) \(timeText) (\(offsetText), \(calendar.timeZone.identifier))")
    }

    @Test("app language does not change the local expiry time", arguments: ResolvedLanguage.allCases)
    func languagePreservesTimeZone(language: ResolvedLanguage) throws {
        let expiry = try #require(RunwayDates.parse("2026-09-07T20:30:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let text = SubscriptionDateFormatter.expiresAt(expiry, language: language, calendar: calendar)

        #expect(text.hasSuffix("04:30:00 (UTC+08:00, Asia/Singapore)"))
        if language == .english { #expect(text.hasPrefix("Sep 8, 2026 ")) }
        if language == .simplifiedChinese { #expect(text.hasPrefix("2026/9/8 ")) }
    }

    @Test("subscription expires at its timestamp in every timezone", arguments: [
        "UTC", "Asia/Singapore", "America/Los_Angeles", "Asia/Kolkata",
    ])
    func exactExpiryBoundary(timeZoneID: String) throws {
        let expiry = try #require(RunwayDates.parse("2026-09-07T20:30:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneID))

        #expect(!SubscriptionDateFormatter.isExpired(
            expiry, now: expiry.addingTimeInterval(-1), calendar: calendar))
        #expect(SubscriptionDateFormatter.isExpired(expiry, now: expiry, calendar: calendar))
        #expect(SubscriptionDateFormatter.isExpired(
            expiry, now: expiry.addingTimeInterval(1), calendar: calendar))
        #expect(SubscriptionDateFormatter.isExpired(
            expiry, now: expiry.addingTimeInterval(4 * 3_600), calendar: calendar))
    }
}
