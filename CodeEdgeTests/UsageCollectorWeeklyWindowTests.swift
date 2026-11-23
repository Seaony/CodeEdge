import Foundation
import Testing
@testable import CodeEdge

@MainActor
struct UsageCollectorWeeklyWindowTests {
    @Test(arguments: ["Weekly", "每周"])
    func identifiesCLIWeeklyWindowByStableIdentifier(label: String) throws {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = UsageWindow(
            id: "claude-weekly", label: label, usedFraction: 0.4, resetsAt: reset
        )
        let usage = ProviderUsage(
            id: descriptor.id, state: .ready,
            windows: [
                UsageWindow(id: "claude-session", label: "会话", usedFraction: 0.1),
                weekly,
            ]
        )

        #expect(UsageCollector.weeklyWindow(in: usage, descriptor: descriptor) == weekly)
    }

    @Test
    func identifiesAPIWeeklyWindowBeforeModelSpecificWindows() throws {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        let weekly = UsageWindow(id: "claude-seven_day", label: "Weekly", usedFraction: 0.4)
        let usage = ProviderUsage(
            id: descriptor.id, state: .ready,
            windows: [
                UsageWindow(id: "claude-seven_day_opus", label: "Opus", usedFraction: 0.7),
                weekly,
            ]
        )

        #expect(UsageCollector.weeklyWindow(in: usage, descriptor: descriptor) == weekly)
    }

    @Test
    func doesNotUseSessionAsWeeklyWindow() throws {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        let usage = ProviderUsage(
            id: descriptor.id, state: .ready,
            windows: [UsageWindow(id: "claude-session", label: "Session", usedFraction: 0.1)]
        )

        #expect(UsageCollector.weeklyWindow(in: usage, descriptor: descriptor) == nil)
    }

    @Test
    func formatsWeeklyEstimateAsTokensWhenPricingIsUnavailable() {
        #expect(
            ProviderDetailCard.formattedWeeklyEstimate(
                DailyTokenUsage(tokens: 84_300_000, valueUSD: 41.56)
            ) == "≈ $41.56"
        )
        #expect(
            ProviderDetailCard.formattedWeeklyEstimate(
                DailyTokenUsage(tokens: 84_300_000, valueUSD: nil, partialValueUSD: 0.86)
            ) == "≈ 84.3M"
        )
        #expect(
            ProviderDetailCard.formattedWeeklyEstimate(
                DailyTokenUsage(tokens: 0, valueUSD: nil)
            ) == "—"
        )
        #expect(ProviderDetailCard.formattedWeeklyEstimate(nil) == "—")
    }
}
