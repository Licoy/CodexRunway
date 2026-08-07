import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok billing")
struct GrokBillingTests {
    @Test("decodes the current credits config wrapper")
    func decodesCurrentCreditsConfig() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 42.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-06-01T00:00:00Z",
              "end": "2026-06-08T00:00:00Z"
            },
            "monthlyLimit": {"val": 9999},
            "used": {"val": 9999},
            "onDemandCap": {"val": 5000},
            "onDemandUsed": {"val": 300},
            "prepaidBalance": {"val": 1250},
            "productUsage": [
              {"product": "GrokBuild", "usagePercent": 30.0},
              {"product": "GrokImagine", "usagePercent": 8.5},
              {"product": "GrokChat", "usagePercent": 4.0}
            ],
            "isUnifiedBillingUser": true
          },
          "on_demand_enabled": true,
          "subscription_tier": "SuperGrok Heavy"
        }
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data, now: now)

        #expect(snapshot.plan == "SuperGrok Heavy")
        #expect(snapshot.includedUsagePercent == 42.5)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.period?.startsAt == iso8601("2026-06-01T00:00:00Z"))
        #expect(snapshot.period?.resetsAt == iso8601("2026-06-08T00:00:00Z"))
        #expect(snapshot.includedLimitCents == 9999)
        #expect(snapshot.includedUsedCents == 9999)
        #expect(snapshot.prepaidBalanceCents == 1250)
        #expect(snapshot.onDemandEnabled == true)
        #expect(snapshot.onDemandUsedCents == 300)
        #expect(snapshot.onDemandLimitCents == 5000)
        #expect(snapshot.productUsage.map(\.product) == ["GrokBuild", "GrokImagine", "GrokChat"])
        #expect(snapshot.productUsage.map(\.usagePercent) == [30.0, 8.5, 4.0])
        #expect(snapshot.isUnifiedBillingUser == true)
        #expect(snapshot.source == .current)
        #expect(snapshot.updatedAt == now)
    }

    @Test("post-reset credits with period but no percent decode as 0% used")
    func postResetCreditsWithoutPercentAreZeroUsed() throws {
        // Live shape after weekly reset before first billable request: currentPeriod
        // is present, creditUsagePercent / productUsage / monthlyLimit are omitted.
        let data = Data(#"""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-06T16:46:56.082611+00:00",
              "end": "2026-08-13T16:46:56.082611+00:00"
            },
            "onDemandCap": {"val": 0},
            "onDemandUsed": {"val": 0},
            "isUnifiedBillingUser": true,
            "prepaidBalance": {"val": 0},
            "billingPeriodStart": "2026-08-06T16:46:56.082611+00:00",
            "billingPeriodEnd": "2026-08-13T16:46:56.082611+00:00"
          }
        }
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data, now: now)

        #expect(snapshot.includedUsagePercent == 0)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.period?.startsAt != nil)
        #expect(snapshot.period?.resetsAt != nil)
        #expect(snapshot.productUsage.isEmpty)
        #expect(snapshot.isUnifiedBillingUser == true)
        #expect(snapshot.prepaidBalanceCents == 0)
        #expect(snapshot.source == .current)
        #expect(snapshot.updatedAt == now)
    }

    @Test("explicit zero creditUsagePercent stays current source")
    func explicitZeroCreditUsagePercent() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 0,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-06T16:46:56Z",
              "end": "2026-08-13T16:46:56Z"
            }
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 0)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.source == .current)
    }

    @Test("falls back to deprecated fields inside the config wrapper")
    func decodesDeprecatedWrapper() throws {
        let data = Data(#"""
        {
          "config": {
            "monthlyLimit": {"val": 2000},
            "used": {"val": 850},
            "onDemandCap": {"val": 500},
            "onDemandUsed": {"val": 25},
            "billingPeriodStart": "2026-06-01T00:00:00Z",
            "billingPeriodEnd": "2026-07-01T00:00:00Z"
          },
          "onDemandEnabled": false,
          "subscriptionTier": "SuperGrok"
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)

        #expect(snapshot.plan == "SuperGrok")
        #expect(snapshot.includedUsagePercent == 42.5)
        #expect(snapshot.period?.kind == .monthly)
        #expect(snapshot.period?.startsAt == iso8601("2026-06-01T00:00:00Z"))
        #expect(snapshot.period?.resetsAt == iso8601("2026-07-01T00:00:00Z"))
        #expect(snapshot.includedLimitCents == 2000)
        #expect(snapshot.includedUsedCents == 850)
        #expect(snapshot.onDemandEnabled == false)
        #expect(snapshot.onDemandUsedCents == 25)
        #expect(snapshot.onDemandLimitCents == 500)
        #expect(snapshot.source == .deprecated)
    }

    @Test("falls back to the legacy flat billing shape")
    func decodesLegacyFlatShape() throws {
        let data = Data(#"""
        {
          "billingCycle": {
            "billingPeriodStart": "2026-06-01T00:00:00Z",
            "billingPeriodEnd": "2026-07-01T00:00:00Z"
          },
          "monthlyLimit": {"val": 4000},
          "onDemandCap": {"val": 900},
          "on_demand_enabled": true,
          "usage": {
            "includedUsed": {"val": 1000},
            "onDemandUsed": {"val": 75},
            "totalUsed": {"val": 1200}
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)

        #expect(snapshot.includedUsagePercent == 30)
        #expect(snapshot.period?.kind == .monthly)
        #expect(snapshot.onDemandEnabled == true)
        #expect(snapshot.onDemandUsedCents == 75)
        #expect(snapshot.onDemandLimitCents == 900)
        #expect(snapshot.source == .legacyFlat)
    }

    @Test("current fields take precedence and empty cents use proto3 zero")
    func currentFieldsTakePrecedence() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 12.25,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_MONTHLY",
              "start": "2026-06-01T00:00:00Z",
              "end": "2026-07-01T00:00:00Z"
            },
            "monthlyLimit": {"val": 100},
            "used": {"val": 99},
            "prepaidBalance": {},
            "onDemandCap": {},
            "onDemandUsed": {}
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)

        #expect(snapshot.includedUsagePercent == 12.25)
        #expect(snapshot.period?.kind == .monthly)
        #expect(snapshot.prepaidBalanceCents == 0)
        #expect(snapshot.onDemandUsedCents == 0)
        #expect(snapshot.onDemandLimitCents == 0)
        #expect(snapshot.source == .current)
    }

    @Test("invalid billing dates drop period but keep usage percent")
    func invalidDateDropsPeriodOnly() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 10,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "not-a-date",
              "end": "2026-07-01T00:00:00Z"
            }
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 10)
        #expect(snapshot.period == nil)
        #expect(snapshot.source == .current)
    }

    @Test("unknown period types drop period but keep usage percent")
    func unknownPeriodTypeDropsPeriodOnly() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 22.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_DAILY",
              "start": "2026-07-01T00:00:00Z",
              "end": "2026-07-02T00:00:00Z"
            }
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 22.5)
        #expect(snapshot.period == nil)
        #expect(snapshot.source == .current)
    }

    @Test("live-shaped fractional second timestamps with +00:00 decode")
    func liveShapedFractionalTimestampsDecode() throws {
        let data = Data(#"""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-30T16:46:56.082611+00:00",
              "end": "2026-08-06T16:46:56.082611+00:00"
            },
            "creditUsagePercent": 15.0,
            "productUsage": [
              {"product": "GrokBuild", "usagePercent": 15.0}
            ],
            "isUnifiedBillingUser": true,
            "prepaidBalance": {"val": 0}
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 15)
        #expect(snapshot.period?.kind == .weekly)
        #expect(snapshot.period?.startsAt != nil)
        #expect(snapshot.period?.resetsAt != nil)
        #expect(snapshot.productUsage.map(\.product) == ["GrokBuild"])
        #expect(snapshot.source == .current)
    }

    @Test("malformed productUsage does not discard usage percent")
    func malformedProductUsageIsIgnored() throws {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 33,
            "productUsage": {"GrokBuild": 33}
          }
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 33)
        #expect(snapshot.productUsage.isEmpty)
        #expect(snapshot.source == .current)
    }

    @Test("unknown billing structures fail explicitly")
    func unknownStructureFails() {
        let data = Data(#"{"config": {}}"#.utf8)

        #expect(throws: GrokBillingDecodingError.unknownStructure) {
            try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        }
    }

    @Test("string-encoded creditUsagePercent is accepted")
    func stringEncodedPercentIsAccepted() throws {
        let data = Data(#"{"config":{"creditUsagePercent":"42.5"}}"#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        #expect(snapshot.includedUsagePercent == 42.5)
        #expect(snapshot.source == .current)
    }

    @Test("top-level non-object JSON is normalized as unknown billing structures")
    func topLevelNonObjectIsNormalized() {
        let data = Data(#"["not","an","object"]"#.utf8)

        #expect(throws: GrokBillingDecodingError.unknownStructure) {
            try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        }
    }

    @Test("an unrecognized wrapper falls through to a valid legacy flat payload")
    func unknownWrapperFallsThroughToLegacy() throws {
        let data = Data(#"""
        {
          "config": {},
          "monthlyLimit": {"val": 1000},
          "usage": {"totalUsed": {"val": 250}}
        }
        """#.utf8)

        let snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: data)

        #expect(snapshot.includedUsagePercent == 25)
        #expect(snapshot.source == .legacyFlat)
    }

    @Test("non-finite percentages fail decoding")
    func nonFinitePercentageFails() {
        let data = Data(#"{"config":{"creditUsagePercent":1e400}}"#.utf8)

        #expect(throws: (any Error).self) {
            try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        }
    }

    @Test("decodes USD allowance from the cents billing shape")
    func decodesMoneyAllowanceFromCentsShape() throws {
        let data = Data(#"""
        {
          "config": {
            "monthlyLimit": {"val": 15000},
            "used": {"val": 277},
            "billingPeriodStart": "2026-08-01T00:00:00+00:00",
            "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
          }
        }
        """#.utf8)

        let money = try GrokQuotaSnapshot.decodeMoneyAllowance(from: data)
        #expect(money.limitCents == 15_000)
        #expect(money.usedCents == 277)
    }

    @Test("decodes subscription tier display from settings")
    func decodesSettingsPlan() {
        let data = Data(#"""
        {"subscription_tier_display":"SuperGrok","force_update":false}
        """#.utf8)
        #expect(GrokQuotaSnapshot.decodeSettingsPlan(from: data) == "SuperGrok")

        let heavy = Data(#"""
        {"subscription_tier_display":"SuperGrok Heavy"}
        """#.utf8)
        #expect(GrokQuotaSnapshot.decodeSettingsPlan(from: heavy) == "SuperGrok Heavy")
    }

    @Test("merges USD allowance without clobbering credits percent snapshot")
    func mergesMoneyAllowance() throws {
        let credits = Data(#"""
        {
          "config": {
            "creditUsagePercent": 6.0,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-30T16:46:56Z",
              "end": "2026-08-06T16:46:56Z"
            }
          }
        }
        """#.utf8)
        var snapshot = try GrokQuotaSnapshot.decodeBillingResponse(from: credits)
        snapshot = snapshot
            .mergingMoneyAllowance(limitCents: 15_000, usedCents: 277)
            .mergingPlan("SuperGrok", overwrite: true)

        #expect(snapshot.includedUsagePercent == 6.0)
        #expect(snapshot.includedLimitCents == 15_000)
        #expect(snapshot.includedUsedCents == 277)
        #expect(snapshot.includedRemainingCents == 14_723)
        #expect(snapshot.plan == "SuperGrok")
    }
}

@Suite("Grok subscription tier")
struct GrokSubscriptionTierTests {
    @Test("maps JWT numeric tier claims")
    func mapsJWTClaims() {
        #expect(GrokSubscriptionTier.displayName(fromJWTTierClaim: 0) == "Free")
        #expect(GrokSubscriptionTier.displayName(fromJWTTierClaim: 1) == "SuperGrok")
        #expect(GrokSubscriptionTier.displayName(fromJWTTierClaim: 5) == "SuperGrok Heavy")
        #expect(GrokSubscriptionTier.displayName(fromJWTTierClaim: 4) == "X Premium+")
        #expect(GrokSubscriptionTier.displayName(fromJWTTierClaim: 99) == "Tier 99")
        #expect(GrokSubscriptionTier.resolve(fromJWTTierClaim: 1) == .superGrok)
        #expect(GrokSubscriptionTier.resolve(fromJWTTierClaim: 5) == .superGrokHeavy)
        #expect(GrokSubscriptionTier.resolve(fromJWTTierClaim: 99) == .unknown)
    }

    @Test("normalizes API and display names")
    func normalizesNames() {
        #expect(GrokSubscriptionTier.displayName(from: "supergrok") == "SuperGrok")
        #expect(GrokSubscriptionTier.displayName(from: "GrokPro") == "SuperGrok")
        #expect(GrokSubscriptionTier.displayName(from: "SuperGrokPro") == "SuperGrok Heavy")
        #expect(GrokSubscriptionTier.displayName(from: "SuperGrok Heavy") == "SuperGrok Heavy")
        #expect(GrokSubscriptionTier.displayName(from: "  ") == nil)
        #expect(GrokSubscriptionTier.resolve("SuperGrok Lite") == .superGrokLite)
        #expect(GrokSubscriptionTier.resolve("X Premium+") == .xPremiumPlus)
        #expect(GrokSubscriptionTier.resolve("api_key") == .apiKey)
        #expect(GrokSubscriptionTier.resolve(nil) == .unknown)
    }

    @Test("reads tier claim from an unsigned JWT access token")
    func readsJWTAccessToken() {
        // header.payload.sig — payload is {"tier":1}
        let token = "eyJhbGciOiJub25lIn0.eyJ0aWVyIjoxfQ.sig"
        #expect(GrokSubscriptionTier.displayName(fromAccessToken: token) == "SuperGrok")
        #expect(GrokSubscriptionTier.jwtTierClaim(from: token) == 1)
        #expect(GrokSubscriptionTier.resolve(fromAccessToken: token) == .superGrok)
    }
}

private func iso8601(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
