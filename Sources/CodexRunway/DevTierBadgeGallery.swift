import CodexRunwayCore
import SwiftUI

/// Dev-only gallery of plan tier badges + subscription expiry phases.
/// Enabled via `--dev-tier-badges` or `CODEX_RUNWAY_DEV_TIER_BADGES=1`.
struct DevTierBadgeGallery: View {
    var l10n: L10n

    private static let tiers: [CodexSubscriptionTier] = [
        .free,
        .plus,
        .pro5x,
        .pro20x,
        .business,
        .team,
        .enterprise,
        .edu,
        .api,
        .unknown,
    ]

    private static let grokTiers: [GrokSubscriptionTier] = Array(GrokSubscriptionTier.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            sectionCard(title: "Codex plan tiers + identity text") {
                ForEach(Array(Self.tiers.enumerated()), id: \.offset) { _, tier in
                    HStack(spacing: 6) {
                        SubscriptionTierBadge(
                            tier: tier,
                            label: SubscriptionTierBadge.localizedTitle(for: tier, l10n: l10n))
                        SubscriptionTierShimmerText(
                            tier: tier,
                            text: "user@example.com",
                            truncationMode: .middle)
                            .frame(maxWidth: 140, alignment: .leading)
                        Text(debugName(tier))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
            }

            sectionCard(title: "Grok plan tiers") {
                ForEach(Array(Self.grokTiers.enumerated()), id: \.offset) { _, tier in
                    HStack(spacing: 6) {
                        SubscriptionTierBadge(
                            tier: tier,
                            label: SubscriptionTierBadge.localizedTitle(for: tier, l10n: l10n))
                        Text(debugName(tier))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
            }

            sectionCard(title: "Subscription expiry") {
                expiryPreviewRow(
                    label: "active",
                    expiresAt: Calendar.current.date(byAdding: .day, value: 40, to: Date()) ?? Date(),
                    now: Date())
                expiryPreviewRow(
                    label: "expiringSoon",
                    expiresAt: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
                    now: Date())
                expiryPreviewRow(
                    label: "expired",
                    expiresAt: Calendar.current.date(byAdding: .day, value: -5, to: Date()) ?? Date(),
                    now: Date())
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Dev · Badges")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("--dev-tier-badges")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Text("Plan tier capsules + expiry phases for visual QA.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunwaySurface.subtleFill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
    }

    private func expiryPreviewRow(label: String, expiresAt: Date, now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SubscriptionExpiryBadge(expiresAt: expiresAt, l10n: l10n, now: now)
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private func debugName(_ tier: CodexSubscriptionTier) -> String {
        switch tier {
        case .free: return "free"
        case .plus: return "plus"
        case .pro5x: return "pro5x"
        case .pro20x: return "pro20x"
        case .business: return "business"
        case .team: return "team"
        case .enterprise: return "enterprise"
        case .edu: return "edu"
        case .api: return "api"
        case .unknown: return "unknown"
        }
    }

    private func debugName(_ tier: GrokSubscriptionTier) -> String {
        switch tier {
        case .free: return "free"
        case .superGrok: return "superGrok"
        case .superGrokHeavy: return "superGrokHeavy"
        case .superGrokLite: return "superGrokLite"
        case .superGrokPlus: return "superGrokPlus"
        case .xBasic: return "xBasic"
        case .xPremium: return "xPremium"
        case .xPremiumPlus: return "xPremiumPlus"
        case .apiKey: return "apiKey"
        case .unknown: return "unknown"
        }
    }
}
