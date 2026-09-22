import CodexRunwayCore
import Foundation
@preconcurrency import UserNotifications

enum RunwayNotificationDeliveryResult {
    case requested
    case developmentMode
}

struct RunwayNotificationService {
    var environment = UserNotificationEnvironment(bundlePathExtension: Bundle.main.bundleURL.pathExtension)
    private static let delegate = RunwayNotificationDelegate()

    func deliver(_ alerts: [RunwayAlert], l10n: L10n) {
        guard !alerts.isEmpty, environment.canUseUserNotifications else { return }
        let requests = alerts.map { alert in
            let content = UNMutableNotificationContent()
            content.title = title(for: alert, l10n: l10n)
            content.body = body(for: alert, l10n: l10n)
            content.sound = .default
            return UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        }
        add(requests)
    }

    func deliverTest(l10n: L10n) -> RunwayNotificationDeliveryResult {
        guard environment.canUseUserNotifications else { return .developmentMode }
        let content = UNMutableNotificationContent()
        content.title = l10n.text(.testNotificationTitle)
        content.body = l10n.text(.testNotificationBody)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-runway-test-\(UUID().uuidString)",
            content: content,
            trigger: nil)
        add([request])
        return .requested
    }

    private func add(_ requests: [UNNotificationRequest]) {
        let center = UNUserNotificationCenter.current()
        center.delegate = Self.delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for request in requests {
                center.add(request)
            }
        }
    }

    func title(for alert: RunwayAlert, l10n: L10n, now: Date = Date()) -> String {
        switch alert.kind {
        case .quota:
            return l10n.text(.quotaAlertTitle)
        case .resetCredit:
            return l10n.text(.resetCreditAlertTitle)
        case .rateLimitResetDetected:
            if let resetType = alert.resetType {
                return String(
                    format: l10n.text(.rateLimitResetDetectedTypedAlertTitle),
                    resetType.localizedName(l10n: l10n))
            }
            return l10n.text(.rateLimitResetDetectedAlertTitle)
        case .rateLimitResetUpcoming:
            if let boundary = notificationBoundary(for: alert), boundary <= now {
                if let resetType = alert.resetType {
                    return String(
                        format: l10n.text(.rateLimitResetSchedulePassedTypedAlertTitle),
                        resetType.localizedName(l10n: l10n))
                }
                return l10n.text(.rateLimitResetSchedulePassedAlertTitle)
            }
            if alert.scheduleBasis == .contextualInference {
                if let resetType = alert.resetType {
                    return String(
                        format: l10n.text(.rateLimitResetPreviewTypedAlertTitle),
                        resetType.localizedName(l10n: l10n))
                }
                return l10n.text(.rateLimitResetPreviewAlertTitle)
            }
            if alert.endDate != nil {
                if let resetType = alert.resetType {
                    return String(
                        format: l10n.text(.rateLimitResetUpcomingTypedRangeAlertTitle),
                        resetType.localizedName(l10n: l10n))
                }
                return l10n.text(.rateLimitResetUpcomingRangeAlertTitle)
            }
            if let resetType = alert.resetType {
                return String(
                    format: l10n.text(.rateLimitResetUpcomingTypedAlertTitle),
                    resetType.localizedName(l10n: l10n))
            }
            return l10n.text(.rateLimitResetUpcomingAlertTitle)
        }
    }

    func body(
        for alert: RunwayAlert,
        l10n: L10n,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()) -> String
    {
        switch alert.kind {
        case .quota:
            return String(
                format: l10n.text(.quotaAlertBody),
                displayName(for: alert.name, l10n: l10n),
                alert.threshold.map { "\($0)%" } ?? "--")
        case .resetCredit:
            return l10n.text(.resetCreditAlertBody)
        case .rateLimitResetDetected:
            return switch alert.resetType {
            case .banked:
                l10n.text(.rateLimitResetDetectedBankedAlertBody)
            case .globalAndBanked:
                l10n.text(.rateLimitResetDetectedGlobalAndBankedAlertBody)
            case .global, nil:
                l10n.text(.rateLimitResetDetectedAlertBody)
            }
        case .rateLimitResetUpcoming:
            return upcomingBody(for: alert, l10n: l10n, calendar: calendar, now: now)
        }
    }

    private func upcomingBody(
        for alert: RunwayAlert,
        l10n: L10n,
        calendar: Calendar,
        now: Date) -> String
    {
        if let boundary = notificationBoundary(for: alert), boundary <= now {
            let when = scheduleText(for: alert, l10n: l10n, calendar: calendar) ?? "—"
            let key: L10nKey = alert.scheduleBasis == .contextualInference
                ? .rateLimitResetPreviewPassedAlertBody
                : .rateLimitResetSchedulePassedAlertBody
            return String(format: l10n.text(key), when)
        }
        if alert.endDate != nil {
            return upcomingRangeBody(for: alert, l10n: l10n, calendar: calendar)
        }
        return upcomingPointBody(for: alert, l10n: l10n, calendar: calendar)
    }

    private func upcomingRangeBody(
        for alert: RunwayAlert,
        l10n: L10n,
        calendar: Calendar) -> String
    {
        let range = scheduleText(for: alert, l10n: l10n, calendar: calendar) ?? "—"
        if let confidence = alert.confidencePercent {
            let key: L10nKey = alert.scheduleBasis == .contextualInference
                ? .rateLimitResetPreviewRangeDetailAlertBody
                : .rateLimitResetUpcomingRangeDetailAlertBody
            return String(format: l10n.text(key), range, "\(confidence)%")
        }
        if alert.scheduleBasis == .contextualInference {
            return String(format: l10n.text(.rateLimitResetPreviewLegacyAlertBody), range)
        }
        return String(format: l10n.text(.rateLimitResetUpcomingRangeAlertBody), range)
    }

    private func upcomingPointBody(
        for alert: RunwayAlert,
        l10n: L10n,
        calendar: Calendar) -> String
    {
        let relative = l10n.text(
            (alert.threshold ?? 60) <= 30
                ? .rateLimitResetUpcomingAlertBody30m
                : .rateLimitResetUpcomingAlertBody1h)
        guard let when = scheduleText(for: alert, l10n: l10n, calendar: calendar) else {
            return alert.scheduleBasis == .contextualInference
                ? l10n.text(.rateLimitResetPreviewAlertBody)
                : relative
        }
        guard let confidence = alert.confidencePercent else {
            return alert.scheduleBasis == .contextualInference
                ? String(format: l10n.text(.rateLimitResetPreviewLegacyAlertBody), when)
                : relative
        }
        let key: L10nKey = alert.scheduleBasis == .contextualInference
            ? .rateLimitResetPreviewDetailAlertBody
            : .rateLimitResetUpcomingDetailAlertBody
        if alert.scheduleBasis == .contextualInference {
            return String(format: l10n.text(key), when, "\(confidence)%")
        }
        return String(format: l10n.text(key), when, "\(confidence)%", relative)
    }

    private func scheduleText(
        for alert: RunwayAlert,
        l10n: L10n,
        calendar: Calendar) -> String?
    {
        guard let startAt = alert.date else { return nil }
        let endAt = alert.endDate ?? startAt
        return ResetLabelFormatter.scheduledLabel(
            for: RateLimitResetScheduleWindow(
                startAt: startAt,
                endAt: endAt,
                isRange: alert.endDate != nil),
            language: l10n.language,
            calendar: calendar)
    }

    private func notificationBoundary(for alert: RunwayAlert) -> Date? {
        alert.endDate?.addingTimeInterval(60) ?? alert.date
    }

    private func displayName(for name: String, l10n: L10n) -> String {
        if name == "5-hour" { return l10n.text(.fiveHourUsage) }
        if name == "Weekly" { return l10n.text(.weeklyUsage) }
        return name
    }
}

private final class RunwayNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .sound])
    }
}
