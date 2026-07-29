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

    private func title(for alert: RunwayAlert, l10n: L10n) -> String {
        switch alert.kind {
        case .quota:
            return l10n.text(.quotaAlertTitle)
        case .resetCredit:
            return l10n.text(.resetCreditAlertTitle)
        case .rateLimitResetDetected:
            return l10n.text(.rateLimitResetDetectedAlertTitle)
        case .rateLimitResetUpcoming:
            return l10n.text(.rateLimitResetUpcomingAlertTitle)
        }
    }

    private func body(for alert: RunwayAlert, l10n: L10n) -> String {
        switch alert.kind {
        case .quota:
            return String(
                format: l10n.text(.quotaAlertBody),
                displayName(for: alert.name, l10n: l10n),
                alert.threshold.map { "\($0)%" } ?? "--")
        case .resetCredit:
            return l10n.text(.resetCreditAlertBody)
        case .rateLimitResetDetected:
            return l10n.text(.rateLimitResetDetectedAlertBody)
        case .rateLimitResetUpcoming:
            let minutes = alert.threshold ?? 60
            if minutes <= 30 {
                return l10n.text(.rateLimitResetUpcomingAlertBody30m)
            }
            return l10n.text(.rateLimitResetUpcomingAlertBody1h)
        }
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
