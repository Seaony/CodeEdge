import Foundation
import Testing
@testable import CodeEdge

struct MuseAIUsageTests {
    @Test func discoversImmutableAndLegacyNextChunks() {
        let html = """
        <script src="/_next/static/chunks/main-123.js"></script>
        <script src="/_next/static/immutable/chunks/settings~abc.js"></script>
        <script src="/_next/static/immutable/chunks/settings~abc.js"></script>
        """
        let paths = MuseAIUsageFetcher.chunkPaths(html)
        #expect(paths == [
            "/_next/static/chunks/main-123.js",
            "/_next/static/immutable/chunks/settings~abc.js",
        ])
    }

    @Test func marks400And404And409ForRediscoveryButNotTransientErrors() {
        let url = URL(string: "https://muse.ai/")!
        for status in [400, 404, 409] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            #expect(MuseAIUsageFetcher.actionNeedsRediscovery(response))
        }
        for status in [401, 403, 408, 429, 500, 503] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            #expect(!MuseAIUsageFetcher.actionNeedsRediscovery(response))
        }
    }
}
