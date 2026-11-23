import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodeEdge

struct KeychainNoUIQueryTests {
    @Test
    func noUIQueryKeepsBothSilentFlags() throws {
        var query: [String: Any] = [:]
        BrowserCookieAccess.applyNoUI(to: &query)

        // 运行时读到的值必须就是系统常量，否则旧式钥匙串仍会弹授权框。
        #expect(BrowserCookieAccess.authenticationUIFailPolicy == "u_AuthUIF")
        #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
    }

    @Test
    func partitionIDParserAndEvaluatorMatchTeam() throws {
        let plist: [String: Any] = ["Partitions": ["teamid:ABC1234567", "apple-tool:"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let hex = data.map { String(format: "%02x", $0) }.joined()

        #expect(BrowserCookieAccess.partitionIDs(fromACLDescription: hex) == ["teamid:ABC1234567", "apple-tool:"])
        #expect(BrowserCookieAccess.evaluatePartitionList(descriptions: [hex], callerTeam: "ABC1234567") == .allowed)
        #expect(BrowserCookieAccess.evaluatePartitionList(descriptions: [hex], callerTeam: "OTHER99999") == .rejected)
        #expect(BrowserCookieAccess.evaluatePartitionList(descriptions: [], callerTeam: nil) == .allowed)
    }

    @Test
    func recordsThrowsCancellationErrorWhenTaskCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try BrowserCookieAccess.verifyRecordsCancellation()
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func partitionRejectedForeignReadNeverCallsReadInBackground() {
        var readCalled = false
        let (status, data) = BrowserCookieAccess.readForeignKeychainItem(
            service: "test.partition.service",
            account: "meta",
            requirePartition: true,
            preflight: { .interactionRequired },
            read: { _ in
                readCalled = true
                return (errSecSuccess, Data("secret".utf8))
            }
        )
        #expect(status == errSecInteractionNotAllowed)
        #expect(data == nil)
        #expect(!readCalled)
    }
}
