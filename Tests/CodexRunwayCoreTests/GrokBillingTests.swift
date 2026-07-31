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
            "prepaidBalance": {"val": 1250}
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
        #expect(snapshot.prepaidBalanceCents == 1250)
        #expect(snapshot.onDemandEnabled == true)
        #expect(snapshot.onDemandUsedCents == 300)
        #expect(snapshot.onDemandLimitCents == 5000)
        #expect(snapshot.source == .current)
        #expect(snapshot.updatedAt == now)
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

    @Test("invalid billing dates fail instead of dropping reset data")
    func invalidDateFails() {
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

        #expect(throws: GrokBillingDecodingError.invalidDate("not-a-date")) {
            try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        }
    }

    @Test("unknown billing structures fail explicitly")
    func unknownStructureFails() {
        let data = Data(#"{"config": {}}"#.utf8)

        #expect(throws: GrokBillingDecodingError.unknownStructure) {
            try GrokQuotaSnapshot.decodeBillingResponse(from: data)
        }
    }

    @Test("top-level JSON type mismatches are normalized as unknown billing structures")
    func topLevelTypeMismatchIsNormalized() {
        let data = Data(#"{"config":{"creditUsagePercent":"42.5"}}"#.utf8)

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
}

private func iso8601(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
