import Foundation
import Testing
@testable import CodeEdge

struct VercelUsageTests {
    @Test func parsesGatewayCredits() throws {
        let json = #"{"balance":"12.50","total_used":"37.50"}"#
        let snapshot = try VercelUsageFetcher.parse(Data(json.utf8))
        let usage = snapshot.toProviderUsage()
        #expect(usage.balance == "$12.50")
        #expect(usage.details.first(where: { $0.id == "vercel-lifetime-spend" })?.value == "$37.50")
    }

    @Test func parsesPersonalBudgetPreferringCustomOverDefault() throws {
        let now = Date(timeIntervalSince1970: 1_794_614_400) // 2026-11-14 00:00:00 UTC
        let defaultBudget: [String: Any] = [
            "scopeType": "user",
            "scopeId": "usr_1",
            "active": true,
            "archived": false,
            "source": "default",
            "limitAmount": 50.0,
            "currentSpend": 10.0,
            "refreshPeriod": "monthly",
        ]
        let customBudget: [String: Any] = [
            "scopeType": "user",
            "scopeId": "usr_1",
            "active": true,
            "archived": false,
            "limitAmount": 100.0,
            "currentSpend": 25.0,
            "refreshPeriod": "monthly",
        ]
        let snapshot = try VercelUsageFetcher.parsePersonalBudget(
            matches: [defaultBudget, customBudget],
            email: "dev@vercel.com",
            teamID: "team_abc",
            now: now
        )
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.count == 1)
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.25) < 0.0001)
        #expect(usage.windows.first?.detail == "$25.00 / $100.00")
        #expect(usage.balance == "$75.00")
        #expect(usage.windows.first?.resetsAt != nil)
    }

    @Test func handlesMissingPersonalBudgetGracefully() throws {
        let snapshot = try VercelUsageFetcher.parsePersonalBudget(
            matches: [],
            email: "dev@vercel.com",
            teamID: "team_abc"
        )
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.details.contains(where: { $0.id == "vercel-budget-empty" }))
    }
}
