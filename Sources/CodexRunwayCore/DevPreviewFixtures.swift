import Foundation

/// Dev/preview fixtures for offscreen UI renders (`--render-main-panel-mock`).
/// Lives in core because several display models only have internal memberwise inits.
/// Never used at runtime outside dev render flags; contains no real account data.
public enum RunwayPreviewFixtures {
    public static func rateWindow(
        usedPercent: Int,
        windowMinutes: Int?,
        resetsAt: Date?) -> RateWindow
    {
        RateWindow(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }

    public static func accountDisplay(
        tier: CodexSubscriptionTier,
        displayName: String,
        email: String?,
        expiresAt: Date?) -> CodexAccountDisplay
    {
        CodexAccountDisplay(
            isAuthenticated: true,
            displayName: displayName,
            email: email,
            username: nil,
            accountId: "acct-preview-0001",
            subscriptionTier: tier,
            subscriptionExpiresAt: expiresAt)
    }

    public static func quotaEstimate(now: Date) -> QuotaEstimateSnapshot {
        let day: TimeInterval = 24 * 3_600
        let quota = QuotaSnapshot(
            plan: "pro",
            primary: rateWindow(usedPercent: 37, windowMinutes: 300, resetsAt: now.addingTimeInterval(2.6 * 3_600)),
            secondary: rateWindow(
                usedPercent: 40,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(3.2 * day)),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)
        let rows = (0..<7).map { offset -> ApiEquivalentDailyRow in
            let date = QuotaEstimateCalculator.addUTCDays(QuotaEstimateCalculator.utcDay(now), -offset)
            let credits = 8.5 + Double(offset) * 1.4
            return ApiEquivalentDailyRow(
                date: date,
                totals: ApiEquivalentTotals(
                    totalTokens: Int(credits * 120_000),
                    uncachedInputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    turns: 12 + offset,
                    threads: 3),
                estimatedUSD: nil,
                rawCredits: credits,
                creditsReported: true,
                totalsReported: true)
        }
        let previous = QuotaEstimateHistorySample(
            cycleStartDate: QuotaEstimateCalculator.addUTCDays(QuotaEstimateCalculator.utcDay(now), -13),
            estimatedCredits: 220,
            usedPercent: 55,
            usedCredits: 121,
            recordedAt: now.addingTimeInterval(-8 * day))
        return QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: rows,
            mode: .auto,
            history: [previous],
            now: now)
    }

    public static func resetCredits(now: Date) -> ResetCreditsSnapshot {
        let day: TimeInterval = 24 * 3_600
        let credits = [
            ResetCredit(
                id: "credit-1",
                status: "available",
                createdAt: now.addingTimeInterval(-12 * day),
                expiresAt: now.addingTimeInterval(3 * day),
                remainingSeconds: 3 * day),
            ResetCredit(
                id: "credit-2",
                status: "available",
                createdAt: now.addingTimeInterval(-6 * day),
                expiresAt: now.addingTimeInterval(16 * day),
                remainingSeconds: 16 * day),
            ResetCredit(
                id: "credit-3",
                status: "available",
                createdAt: now.addingTimeInterval(-2 * day),
                expiresAt: now.addingTimeInterval(25 * day),
                remainingSeconds: 25 * day),
            ResetCredit(
                id: "credit-4",
                status: "used",
                createdAt: now.addingTimeInterval(-30 * day),
                expiresAt: now.addingTimeInterval(-2 * day),
                remainingSeconds: 0),
        ]
        return ResetCreditsSnapshot(
            availableCount: 3,
            credits: credits,
            updatedAt: now)
    }

    public static func apiCostSummary(now: Date) -> ApiEquivalentSummary {
        let day: TimeInterval = 24 * 3_600
        let calendar = Calendar(identifier: .gregorian)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        func totals(_ total: Int, turns: Int) -> ApiEquivalentTotals {
            ApiEquivalentTotals(
                totalTokens: total,
                uncachedInputTokens: Int(Double(total) * 0.22),
                cachedInputTokens: Int(Double(total) * 0.64),
                outputTokens: Int(Double(total) * 0.14),
                turns: turns,
                threads: max(1, turns / 6))
        }

        let dailyRows = (0..<5).reversed().map { offset -> ApiEquivalentDailyRow in
            let date = calendar.startOfDay(for: now.addingTimeInterval(-Double(offset) * day))
            return ApiEquivalentDailyRow(
                date: dayFormatter.string(from: date),
                totals: totals(2_400_000 + offset * 380_000, turns: 42 + offset * 7),
                estimatedUSD: Decimal(string: "\(3.42 + Double(offset) * 1.18)"),
                rawCredits: 0)
        }
        let modelRows = [
            ApiEquivalentBreakdownRow(
                name: "gpt-5.3-codex",
                totals: totals(9_800_000, turns: 160),
                estimatedUSD: Decimal(string: "16.62"),
                rawCredits: 0),
            ApiEquivalentBreakdownRow(
                name: "gpt-5.3-codex-mini",
                totals: totals(2_300_000, turns: 55),
                estimatedUSD: Decimal(string: "2.11"),
                rawCredits: 0),
        ]
        let projectRows = [
            ApiEquivalentBreakdownRow(
                name: "codex-runway",
                totals: totals(7_100_000, turns: 122),
                estimatedUSD: Decimal(string: "11.84"),
                rawCredits: 0),
            ApiEquivalentBreakdownRow(
                name: "dotfiles",
                totals: totals(5_000_000, turns: 93),
                estimatedUSD: Decimal(string: "6.89"),
                rawCredits: 0),
        ]
        let clientRows = [
            ApiEquivalentBreakdownRow(
                name: "codex-cli",
                totals: totals(12_100_000, turns: 215),
                estimatedUSD: Decimal(string: "18.73"),
                rawCredits: 0),
        ]
        return ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: DateInterval(start: now.addingTimeInterval(-5 * day), end: now),
            estimatedUSD: Decimal(string: "18.73"),
            totals: totals(12_100_000, turns: 215),
            dailyRows: dailyRows,
            modelRows: modelRows,
            projectRows: projectRows,
            clientRows: clientRows,
            rawCredits: 0,
            warnings: [],
            pricingVersion: "2026-05",
            calculatedAt: now)
    }

    public static func recentSessions(now: Date) -> [SessionActivityItem] {
        func totals(_ total: Int, turns: Int) -> ApiEquivalentTotals {
            ApiEquivalentTotals(
                totalTokens: total,
                uncachedInputTokens: Int(Double(total) * 0.2),
                cachedInputTokens: Int(Double(total) * 0.66),
                outputTokens: Int(Double(total) * 0.14),
                turns: turns,
                threads: 1)
        }
        return [
            SessionActivityItem(
                id: "session-1",
                title: "Redesign popover layout",
                projectName: "codex-runway",
                cwd: "/Users/dev/codex-runway",
                updatedAt: now.addingTimeInterval(-8 * 60),
                state: .recent,
                totals: totals(1_860_000, turns: 34),
                estimatedUSD: Decimal(string: "2.84")),
            SessionActivityItem(
                id: "session-2",
                title: "Fix flaky repository test",
                projectName: "codex-runway",
                cwd: "/Users/dev/codex-runway",
                updatedAt: now.addingTimeInterval(-95 * 60),
                state: .needsAttention,
                totals: totals(640_000, turns: 12),
                estimatedUSD: Decimal(string: "0.97")),
            SessionActivityItem(
                id: "session-3",
                title: "Migrate settings storage",
                projectName: "dotfiles",
                cwd: "/Users/dev/dotfiles",
                updatedAt: now.addingTimeInterval(-6 * 3_600),
                state: .failed,
                totals: totals(210_000, turns: 5),
                estimatedUSD: Decimal(string: "0.31")),
        ]
    }

    public static func managedAccounts(now: Date) -> [ManagedAccount] {
        let day: TimeInterval = 24 * 3_600
        return [
            ManagedAccount(
                id: "account-1",
                sortIndex: 0,
                authMode: .oauth,
                email: "dev@example.com",
                username: "dev",
                accountId: "acct-preview-0001",
                displayName: "dev@example.com",
                planType: "pro-20x",
                subscriptionExpiresAt: now.addingTimeInterval(26 * day),
                createdAt: now.addingTimeInterval(-90 * day),
                lastUsedAt: now.addingTimeInterval(-3_600),
                lastQuotaAt: now.addingTimeInterval(-1_800),
                cachedQuota: CachedAccountQuota(
                    plan: "pro-20x",
                    primaryUsedPercent: 37,
                    primaryResetsAt: now.addingTimeInterval(2.6 * 3_600),
                    primaryWindowMinutes: 300,
                    secondaryUsedPercent: 58,
                    secondaryResetsAt: now.addingTimeInterval(3.2 * day),
                    secondaryWindowMinutes: 10_080,
                    updatedAt: now.addingTimeInterval(-1_800))),
            ManagedAccount(
                id: "account-2",
                sortIndex: 1,
                authMode: .oauth,
                email: "work@example.com",
                username: "work",
                accountId: "acct-preview-0002",
                displayName: "work@example.com",
                planType: "plus",
                subscriptionExpiresAt: now.addingTimeInterval(5 * day),
                createdAt: now.addingTimeInterval(-30 * day),
                lastUsedAt: now.addingTimeInterval(-2 * day),
                lastQuotaAt: now.addingTimeInterval(-2 * day),
                cachedQuota: CachedAccountQuota(
                    plan: "plus",
                    primaryUsedPercent: 82,
                    primaryResetsAt: now.addingTimeInterval(1.1 * 3_600),
                    primaryWindowMinutes: 300,
                    secondaryUsedPercent: 91,
                    secondaryResetsAt: now.addingTimeInterval(1.4 * day),
                    secondaryWindowMinutes: 10_080,
                    updatedAt: now.addingTimeInterval(-2 * day))),
            ManagedAccount(
                id: "account-3",
                sortIndex: 2,
                authMode: .apiKey,
                email: nil,
                username: nil,
                accountId: "acct-preview-0003",
                displayName: "API Key",
                planType: "api",
                createdAt: now.addingTimeInterval(-10 * day),
                requiresReauth: true),
        ]
    }
}
