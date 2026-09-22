import CodexRunwayCore
import Foundation
import Testing
@testable import CodexRunway

@Suite("Reset type presentation")
@MainActor
struct RunwayResetTypePresentationTests {
    @Test("menu, details, and widget keep current and next reset types distinct")
    func resetTypePresentationUsesSnapshotDerivation() async throws {
        let now = Date()
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .yes, now: now)
        snapshot.events.append(scheduledBankedReset(at: now.addingTimeInterval(3_600)))

        let defaults = UserDefaults(suiteName: "codex-runway-reset-type-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.rateLimitResetTodayText == "是 · 全局重置")
        let verdictLine = try #require(model.rateLimitResetTodayLines.first)
        #expect(verdictLine.title == "今天有新的 Codex 重置吗？")
        #expect(verdictLine.value == "是")
        let nextLine = try #require(model.rateLimitResetTodayLines.first {
            $0.title == "预计下次重置"
        })
        #expect(nextLine.value.contains("重置卡 · "))
        let widget = try #require(model.makeWidgetSnapshot(now: now).resetToday)
        #expect(widget.resetType == .global)
        #expect(widget.nextScheduledResetType == .banked)
    }

    @Test("no-reset menu hint names the last type and relative time")
    func noResetHintIncludesLastTypeAndAgo() async throws {
        let now = Date()
        let lastAt = now.addingTimeInterval(-30 * 3_600)
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        snapshot.events = [
            RateLimitResetTodayEvent(
                kind: .resetCompleted,
                announcedAt: lastAt,
                effectiveAt: lastAt,
                scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
                source: RateLimitResetTodaySource(
                    origin: .operator,
                    postID: "op_4c549b7d3147b644968bb73a"),
                confidence: 1,
                rationale: "Operator-confirmed Codex quota reset without an X announcement.",
                text: "Operator confirmed."),
        ]
        let ago = try #require(
            DurationFormatter.relativePastSingleUnit(
                since: lastAt,
                now: now,
                language: .simplifiedChinese))

        let defaults = UserDefaults(suiteName: "codex-runway-reset-none-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.rateLimitResetTodayText == "否")
        #expect(model.rateLimitResetTodayLines.first?.title == "今天有新的 Codex 重置吗？")
        #expect(model.rateLimitResetTodayLines.first?.value == "否")
        let statusLine = try #require(model.rateLimitResetTodayLines.first { $0.title == "状态" })
        #expect(statusLine.value == "今日暂无已完成或已排期的重置，上次发生全局重置为\(ago)之前")
    }

    @Test("scheduled menu title uses percent plus yes")
    func scheduledMenuTitleUsesPercentPlusYes() async throws {
        let now = Date()
        let effectiveAt = now.addingTimeInterval(3_600)
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        snapshot.events = [
            RateLimitResetTodayEvent(
                kind: .resetScheduled,
                announcedAt: now.addingTimeInterval(-600),
                effectiveAt: effectiveAt,
                schedulePrecision: .datetime,
                scheduleBasis: .explicit,
                scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
                source: RateLimitResetTodaySource(
                    handle: "thsottiaux",
                    postID: "2090000000000000002",
                    url: URL(string: "https://x.com/thsottiaux/status/2090000000000000002")!),
                confidence: 0.6,
                rationale: "Explicit Codex quota reset schedule.",
                text: "Reset later today."),
        ]
        snapshot.resetTimeline = RateLimitResetTimeline(nextSchedule: snapshot.events[0])

        let defaults = UserDefaults(suiteName: "codex-runway-reset-scheduled-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.rateLimitResetTodayText == "≥60%是 · 全局重置")
        #expect(model.rateLimitResetTodayLines.first?.title == "接下来会有 Codex 重置吗？")
        #expect(model.rateLimitResetTodayLines.first?.value == "≥60%是")
        let statusLine = try #require(model.rateLimitResetTodayLines.first { $0.title == "状态" })
        #expect(statusLine.value.contains("约≥60%的可能性会进行全局重置"))
        let widget = try #require(model.makeWidgetSnapshot(now: now).resetToday)
        #expect(widget.confidencePercent == 60)
        #expect(widget.confidenceBand == .warn)
    }

    @Test("same-time schedules merge their reset type in secondary details")
    func sameTimeSchedulesMergeSecondaryType() async throws {
        let now = Date()
        let effectiveAt = now.addingTimeInterval(3_600)
        var global = scheduledBankedReset(at: effectiveAt)
        global.resetType = .global
        global.source.postID = "2090000000000000101"
        var banked = scheduledBankedReset(at: effectiveAt)
        banked.source.postID = "2090000000000000102"
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        snapshot.events = [global, banked]
        snapshot.resetTimeline = RateLimitResetTimeline(nextSchedule: global)

        let defaults = UserDefaults(suiteName: "codex-runway-reset-combined-next-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let nextLine = try #require(model.rateLimitResetTodayLines.first {
            $0.title == "预计下次重置"
        })
        #expect(nextLine.value.contains("全局重置 + 重置卡 · "))
    }

    @Test("tick rebuilds all menu details after schedule grace expires")
    func tickRebuildsExpiredScheduleDetails() async throws {
        let now = Date()
        let effectiveAt = now.addingTimeInterval(60)
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        snapshot.events = [scheduledBankedReset(at: effectiveAt)]
        snapshot.resetTimeline = RateLimitResetTimeline(nextSchedule: snapshot.events[0])

        let defaults = UserDefaults(suiteName: "codex-runway-reset-expired-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.rateLimitResetTodayLines.contains { $0.title == "置信度" })
        #expect(model.rateLimitResetTodayLines.contains { $0.title == "预计下次重置" })

        model.tick(now: effectiveAt.addingTimeInterval(RateLimitResetTodaySnapshot.scheduleGrace + 1))

        #expect(model.rateLimitResetTodayText == "否")
        #expect(model.rateLimitResetTodayLines.first?.title == "今天有新的 Codex 重置吗？")
        #expect(!model.rateLimitResetTodayLines.contains { $0.title == "置信度" })
        #expect(!model.rateLimitResetTodayLines.contains { $0.title == "预计下次重置" })
        #expect(!model.rateLimitResetTodayLines.contains { $0.title == "最近依据" })
    }

    private func scheduledBankedReset(at effectiveAt: Date) -> RateLimitResetTodayEvent {
        RateLimitResetTodayEvent(
            kind: .resetScheduled,
            resetType: .banked,
            announcedAt: effectiveAt.addingTimeInterval(-3_600),
            effectiveAt: effectiveAt,
            schedulePrecision: .datetime,
            scheduleBasis: .explicit,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(
                handle: "thsottiaux",
                postID: "2090000000000000001",
                url: URL(string: "https://x.com/thsottiaux/status/2090000000000000001")!),
            confidence: 0.99,
            rationale: "Explicit Codex reset-bank credit schedule.",
            text: "A reset-bank credit is scheduled.")
    }

    private func services(snapshot: RateLimitResetTodaySnapshot) -> RunwayModelServices {
        RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.badServerResponse) },
            fetchResetCredits: { _ in throw URLError(.badServerResponse) },
            fetchRateLimitResetToday: { snapshot },
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.badServerResponse) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.badServerResponse) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.badServerResponse) },
            dryRunSessions: { throw URLError(.badServerResponse) },
            scanRecentSessions: { _ in throw URLError(.badServerResponse) })
    }

    private func isolatedAccountStore() -> AccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reset-type-test-\(UUID().uuidString)", isDirectory: true)
        return AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("auth.json"))
    }
}
