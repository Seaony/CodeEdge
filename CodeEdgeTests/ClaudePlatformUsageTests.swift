import Foundation
import Testing
@testable import CodeEdge

struct ClaudePlatformUsageTests {
    @Test func capsOtherCreditGrantDetailsAt24Rows() throws {
        let future = "2027-01-01T00:00:00Z"
        let tranches = (0..<30).map { index -> [String: Any] in
            [
                "name": "Grant \(index)",
                "granted_amount_minor_units": 1000,
                "remaining_amount_minor_units": 500,
                "expires_at": future,
            ]
        }
        let payload: [String: Any] = [
            "currency": "USD",
            "amount": 15000,
            "promo_tranches": tranches,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let usage = try ClaudePlatformUsageFetcher.parseCredits(data, now: Date(timeIntervalSince1970: 1_794_614_400))
        #expect(usage.details.count == 24)
        #expect(usage.providerCost?.balance == 150)
    }
}
