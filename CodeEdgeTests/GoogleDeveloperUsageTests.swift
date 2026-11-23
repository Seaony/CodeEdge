import Foundation
import Testing
@testable import CodeEdge

struct GoogleDeveloperUsageTests {
    @Test func extractsPageTokensAndParsesAppliedCredit() throws {
        let html = #"window.WIZ_global_data = {"SNlM0e":"tok-abc:123","oPEP7c":"dev@example.com"};"#
        #expect(GoogleDeveloperUsageFetcher.pageValue(in: html, key: "SNlM0e") == "tok-abc:123")
        #expect(GoogleDeveloperUsageFetcher.pageValue(in: html, key: "oPEP7c") == "dev@example.com")

        // benefit type 19, offer[1]=expires, offer[6]=[granted, remaining, billingAccount], offer[16]=grantedAt
        let innerPayload = """
        [[[19,null,null,null,null,null,null,null,null,[null,[1798761600,0],null,null,null,null,[["USD",10,0],["USD",6,500000000],"billingAccounts/012345-ABCDEF"],null,null,null,null,null,null,null,null,null,[1796083200,0]]]]]
        """
        let escaped = String(data: try JSONEncoder().encode(innerPayload), encoding: .utf8)!
        let body = ")]}'\n\n123\n[[\"wrb.fr\",\"Ro0AYc\",\(escaped),null,null,null,\"generic\"]]\n"

        let parsed = try GoogleDeveloperUsageFetcher.parseBatchExecute(body, email: "dev@example.com")
        guard case let .usage(usage) = parsed else {
            Issue.record("Expected applied cloud credit usage")
            return
        }
        #expect(usage.id.rawValue == "googledeveloper")
        #expect(usage.windows.count == 1)
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.35) < 0.001)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.balance == 6.5)
        #expect(usage.details.contains(where: { $0.value == "012345-ABCDEF" }))
        #expect(usage.details.contains(where: { $0.value == "dev@example.com" }))
    }

    @Test func detectsUnappliedCloudCredit() throws {
        let innerPayload = "[[[19,null,null,null,null,null,null,null,null,[null,null,null,null,null,null,null]]]]"
        let escaped = String(data: try JSONEncoder().encode(innerPayload), encoding: .utf8)!
        let body = ")]}'\n\n50\n[[\"wrb.fr\",\"Ro0AYc\",\(escaped)]]\n"

        let parsed = try GoogleDeveloperUsageFetcher.parseBatchExecute(body, email: "unapplied@example.com")
        #expect(parsed == .unapplied)
    }

    @Test func ignoresOtherBenefitTypes() throws {
        let innerPayload = "[[[42,null,null,null,null,null,null,null,null,[]]]]"
        let escaped = String(data: try JSONEncoder().encode(innerPayload), encoding: .utf8)!
        let body = ")]}'\n\n50\n[[\"wrb.fr\",\"Ro0AYc\",\(escaped)]]\n"

        let parsed = try GoogleDeveloperUsageFetcher.parseBatchExecute(body, email: "dev@example.com")
        #expect(parsed == .noCredit)
    }
}
