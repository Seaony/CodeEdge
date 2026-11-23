import Foundation
import Testing
@testable import CodeEdge

struct TrustedRouterUsageTests {
    @Test func parsesLimitAndUsageMicrodollars() throws {
        let json = """
        {
          "data": {
            "usage_microdollars": 12500000,
            "usage_daily_microdollars": 1500000,
            "usage_weekly_microdollars": 4250000,
            "usage_monthly_microdollars": 9000000,
            "limit_microdollars": 20000000,
            "limit_remaining_microdollars": 5000000
          }
        }
        """
        let snapshot = try TrustedRouterUsageFetcher.parse(Data(json.utf8))
        let usage = snapshot.toProviderUsage()

        #expect(usage.id.rawValue == "trustedrouter")
        #expect(usage.balance == "$5.00")
        #expect(usage.windows.count == 1)
        // remaining 已扣除预留额度，spent = 20 - 5 = 15，占比 75%。
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.75) < 0.0001)
        #expect(usage.windows.first?.detail == "$15.00 / $20.00")
        #expect(usage.details.first(where: { $0.id == "trustedrouter-remaining" })?.value == "$5.00")
        #expect(usage.details.first(where: { $0.id == "trustedrouter-today" })?.value == "$1.50")
        #expect(usage.details.first(where: { $0.id == "trustedrouter-total" })?.value == "$12.50")
    }

    @Test func preservesZeroDollarLimitWithoutPrimaryWindow() throws {
        let json = """
        {
          "data": {
            "usage_microdollars": 0,
            "usage_daily_microdollars": 0,
            "usage_weekly_microdollars": 0,
            "usage_monthly_microdollars": 0,
            "limit_microdollars": 0,
            "limit_remaining_microdollars": 0
          }
        }
        """
        let usage = try TrustedRouterUsageFetcher.parse(Data(json.utf8)).toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$0.00")
        #expect(usage.details.first(where: { $0.id == "trustedrouter-limit-value" })?.value == "$0.00")
    }

    @Test func rejectsMismatchedLimitPair() {
        let json = """
        {
          "data": {
            "usage_microdollars": 1000000,
            "usage_daily_microdollars": 0,
            "usage_weekly_microdollars": 0,
            "usage_monthly_microdollars": 0,
            "limit_microdollars": 5000000,
            "limit_remaining_microdollars": null
          }
        }
        """
        #expect(throws: TrustedRouterUsageError.parseFailure) {
            _ = try TrustedRouterUsageFetcher.parse(Data(json.utf8))
        }
    }
}
