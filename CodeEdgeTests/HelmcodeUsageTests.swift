import Foundation
import Testing
@testable import CodeEdge

struct HelmcodeUsageTests {
    @Test func parsesIndependentBillingPeriodCreditPlan() throws {
        let json = """
        {
          "enabled": true,
          "allowanceCredits": 200,
          "usedCredits": 45.5,
          "periodStart": "2026-11-01T00:00:00Z",
          "periodEnd": "2026-12-01T00:00:00Z",
          "packCredits": 25,
          "frozen": false,
          "models": [
            {"model": "claude-sonnet", "creditsThisMonth": 30.25, "approxCreditsPerMTokens": 12.5},
            {"model": "gpt-6", "creditsThisMonth": null, "approxCreditsPerMTokens": 20}
          ]
        }
        """
        let usage = try #require(try HelmcodeUsageFetcher.parseCreditPlan(Data(json.utf8), tenantName: "NaN Builders"))
        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.id == "helmcode-credits")
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - (45.5 / 200.0)) < 0.0001)
        #expect(usage.windows.first?.detail == "45.5 / 200")
        #expect(usage.details.contains(where: { $0.id == "helmcode-topup-credits" && $0.value == "25" }))
        #expect(usage.details.contains(where: { $0.label == "claude-sonnet" && $0.value == "30.25 (12.5/1M)" }))
        #expect(usage.details.contains(where: { $0.label == "gpt-6" && $0.value == "— (20/1M)" }))
    }

    @Test func disabledCreditPlanReturnsNilToAllowLegacyQuotaFallback() throws {
        let json = #"{"enabled":false}"#
        let result = try HelmcodeUsageFetcher.parseCreditPlan(Data(json.utf8))
        #expect(result == nil)
    }
}
