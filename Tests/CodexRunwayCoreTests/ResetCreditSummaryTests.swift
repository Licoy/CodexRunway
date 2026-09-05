import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Reset credit expiry bounds")
struct ResetCreditSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("only available credits contribute to either expiry bound", arguments: ["used", "unavailable", "unknown"])
    func excludesUnavailableCredits(status: String) {
        let credits = [
            credit("early", status: status, offset: 10),
            credit("next", offset: 100),
            credit("latest", offset: 300),
            credit("late", status: status, offset: 500),
        ]
        for ordered in [credits, Array(credits.reversed())] {
            let summary = ResetCreditSummary(snapshot: ResetCreditsSnapshot(
                availableCount: 2, credits: ordered, updatedAt: now))
            #expect(summary.nextExpiryDate == now.addingTimeInterval(100))
            #expect(summary.nextExpiryRemaining == 100)
            #expect(summary.latestExpiryDate == now.addingTimeInterval(300))
            #expect(summary.latestExpiryRemaining == 300)
            #expect(summary.unavailableCount == 2)
        }
    }

    @Test("empty, unavailable and undated credits have no expiry bounds")
    func missingExpiryBounds() {
        let snapshots = [
            ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: now),
            ResetCreditsSnapshot(availableCount: 0, credits: [credit("used", status: "used", offset: 100)], updatedAt: now),
            ResetCreditsSnapshot(availableCount: 1, credits: [credit("undated", offset: nil)], updatedAt: now),
            ResetCreditsSnapshot(availableCount: 3, credits: [], updatedAt: now),
        ]
        for snapshot in snapshots {
            let summary = ResetCreditSummary(snapshot: snapshot)
            #expect(summary.nextExpiryDate == nil)
            #expect(summary.nextExpiryRemaining == nil)
            #expect(summary.latestExpiryDate == nil)
            #expect(summary.latestExpiryRemaining == nil)
            #expect(summary.availableCount == snapshot.availableCount)
        }
    }

    @Test("single, equal and partly undated credits retain the known expiry")
    func equalExpiryBounds() {
        let known = credit("known", offset: 100)
        let groups = [
            [known],
            [known, credit("equal", offset: 100)],
            [credit("undated", offset: nil), known],
            [known, credit("undated", offset: nil)],
        ]
        for credits in groups {
            let summary = ResetCreditSummary(snapshot: ResetCreditsSnapshot(
                availableCount: credits.count, credits: credits, updatedAt: now))
            #expect(summary.nextExpiryDate == now.addingTimeInterval(100))
            #expect(summary.latestExpiryDate == now.addingTimeInterval(100))
            #expect(summary.nextExpiryRemaining == 100)
            #expect(summary.latestExpiryRemaining == 100)
        }
    }

    @Test("expiry bounds preserve snapshot time and server availability")
    func snapshotSemantics() throws {
        let data = Data(#"{"available_count":7,"credits":[{"id":"past","status":"available","expires_at":900},{"id":"future","status":"available","expires_at":1300}]}"#.utf8)
        let snapshot = try ResetCreditsSnapshot.decode(from: data, now: now)
        let summary = ResetCreditSummary(snapshot: snapshot)
        #expect(summary.availableCount == 7)
        #expect(summary.totalCount == 2)
        #expect(summary.expiringCount == 2)
        #expect(summary.nextExpiryDate == now.addingTimeInterval(-100))
        #expect(summary.nextExpiryRemaining == 0)
        #expect(summary.latestExpiryDate == now.addingTimeInterval(300))
        #expect(summary.latestExpiryRemaining == 300)
        #expect(summary.updatedAt == now)
    }

    @Test("preview credits expose three and twenty-five day bounds")
    func previewExpiryBounds() {
        let summary = ResetCreditSummary(snapshot: RunwayPreviewFixtures.resetCredits(now: now))
        #expect(summary.nextExpiryRemaining == TimeInterval(3 * 86_400))
        #expect(summary.latestExpiryRemaining == TimeInterval(25 * 86_400))
        #expect(summary.availableCount == 3)
        #expect(summary.expiringCount == 1)
    }

    private func credit(_ id: String, status: String = "available", offset: TimeInterval?) -> ResetCredit {
        ResetCredit(
            id: id, status: status, createdAt: nil,
            expiresAt: offset.map { now.addingTimeInterval($0) },
            remainingSeconds: max(0, offset ?? 0))
    }
}
