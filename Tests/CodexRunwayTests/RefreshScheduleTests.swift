import Foundation
import Testing
@testable import CodexRunway

@Suite("Refresh schedule")
struct RefreshScheduleTests {
    @Test("widget cadence remains independent of intervening main refreshes")
    func widgetCadenceIsIndependent() {
        let initialCompletion = Date(timeIntervalSince1970: 1_000)
        var mainSchedule = RefreshSchedule()
        var widgetSchedule = RefreshSchedule()
        mainSchedule.refreshCompleted(at: initialCompletion, interval: 300)
        widgetSchedule.refreshCompleted(at: initialCompletion, interval: 600)

        let mainCompletion = initialCompletion.addingTimeInterval(310)
        #expect(mainSchedule.isDue(at: mainCompletion))
        mainSchedule.refreshStarted()
        mainSchedule.refreshCompleted(at: mainCompletion, interval: 300)

        #expect(!widgetSchedule.isDue(at: initialCompletion.addingTimeInterval(599)))
        #expect(widgetSchedule.isDue(at: initialCompletion.addingTimeInterval(600)))
    }

    @Test("automatic refresh is scheduled from completion instead of start")
    func automaticRefreshIsScheduledFromCompletion() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let completedAt = startedAt.addingTimeInterval(600)
        var schedule = RefreshSchedule()
        schedule.intervalChanged(to: 300, now: startedAt.addingTimeInterval(-300))

        #expect(schedule.isDue(at: startedAt))

        schedule.refreshStarted()

        #expect(!schedule.isDue(at: startedAt.addingTimeInterval(300)))
        #expect(!schedule.isDue(at: completedAt))

        schedule.refreshCompleted(at: completedAt, interval: 300)

        #expect(!schedule.isDue(at: completedAt.addingTimeInterval(299)))
        #expect(schedule.isDue(at: completedAt.addingTimeInterval(300)))
    }

    @Test("interval changes remain anchored to the latest completion")
    func intervalChangesRemainAnchoredToLatestCompletion() {
        let completedAt = Date(timeIntervalSince1970: 2_000)
        var schedule = RefreshSchedule()
        schedule.refreshStarted()
        schedule.refreshCompleted(at: completedAt, interval: 300)

        schedule.intervalChanged(to: 600, now: completedAt.addingTimeInterval(100))

        #expect(!schedule.isDue(at: completedAt.addingTimeInterval(599)))
        #expect(schedule.isDue(at: completedAt.addingTimeInterval(600)))
    }

    @Test("interval changes cannot arm a deadline while refresh is running")
    func intervalChangesDoNotArmDeadlineWhileRefreshIsRunning() {
        let now = Date(timeIntervalSince1970: 3_000)
        var schedule = RefreshSchedule()
        schedule.refreshStarted()

        schedule.intervalChanged(to: 1, now: now)

        #expect(!schedule.isDue(at: .distantFuture))
    }
}
