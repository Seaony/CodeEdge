import CryptoKit
import Foundation
import Testing
@testable import CodeEdge

struct CodexBarSync0850Tests {
    @Test func typeSafeAddsSameOriginHeadersAndTreatsCrossOrigin403AsBillingUnavailable() {
        let request = TypeSafeUsageFetcher.makeBillingOverviewRequest(cookie: "session=abc")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://console.typesafe.ai")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://console.typesafe.ai/billing")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "cors")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == "empty")

        #expect(throws: TypeSafeUsageError.billingUnavailable) {
            try TypeSafeUsageFetcher.validate(
                status: 403,
                location: nil,
                body: #"{"detail":"Cross-origin request refused"}"#
            )
        }
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.validate(status: 403, location: nil, body: "")
        }
    }

    @Test func notionParsesPersonalAllowancesEvenWhenLegacyStatusIsNotApplicable() throws {
        let json = """
        {
          "status": "not_applicable",
          "allowances": [
            {
              "bucketId": "auto",
              "cadence": "billing_period",
              "state": "resolved",
              "used": 25,
              "limit": 100,
              "credits": { "used": 250, "limit": 1000 },
              "periodStartMs": 1793491200000,
              "periodEndMs": 1796083200000
            },
            {
              "bucketId": "flex",
              "cadence": "billing_period",
              "state": "resolved",
              "used": 10,
              "limit": 50,
              "credits": { "used": 100, "limit": 500 },
              "periodStartMs": 1793491200000,
              "periodEndMs": 1796083200000
            }
          ]
        }
        """
        let status = try NotionUsageParser.parseRateLimitStatus(Data(json.utf8))
        let snapshot = NotionUsageSnapshot(
            rateLimit: status,
            workspace: NotionWorkspace(id: "ws-1", name: "Personal", planType: "personal", subscriptionTier: "plus"),
            account: nil,
            workspaceCreditBalance: 420,
            updatedAt: Date(timeIntervalSince1970: 1_794_614_400)
        )
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.count == 2)
        #expect(usage.windows[0].label == "Standard")
        #expect(abs(usage.windows[0].usedFraction - 0.25) < 0.0001)
        #expect(usage.windows[1].label == "Select")
        #expect(abs(usage.windows[1].usedFraction - 0.2) < 0.0001)
        #expect(usage.details.contains(where: { $0.id == "notion-workspace-credits" && $0.value == "420" }))
    }

    @Test func mimoParsesOfficialTokenPlanAPIAndRegions() throws {
        #expect(MiMoUsageFetcher.resolvedTokenPlanRegion(configured: nil, environment: [:]) == "cn")
        #expect(MiMoUsageFetcher.resolvedTokenPlanRegion(configured: "sgp", environment: [:]) == "sgp")
        #expect(MiMoUsageFetcher.resolvedTokenPlanRegion(configured: "us", environment: [:]) == nil)

        let json = """
        {
          "object": "token_plan",
          "plan_code": "pro",
          "quota": {
            "total_credits": 1000,
            "used_credits": 250,
            "remaining_credits": 750
          },
          "period": {
            "start_at": "2026-11-01 00:00:00",
            "end_at": "2026-12-01 00:00:00"
          }
        }
        """
        let usage = try MiMoUsageFetcher.parseTokenPlanAPI(Data(json.utf8))
        #expect(usage.plan == "pro")
        #expect(usage.windows.count == 1)
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.25) < 0.0001)
        #expect(usage.windows.first?.resetsAt != nil)
    }

    @Test func siliconFlowParsesChinaConsolePicoYuanWallet() throws {
        #expect(SiliconFlowUsageFetcher.parsePicoYuan("123450000000000") == 123.45)
        #expect(SiliconFlowUsageFetcher.parsePicoYuan("-500000000000") == -0.5)
        #expect(SiliconFlowUsageFetcher.parsePicoYuan("0") == 0)

        let wallet = #"{"code":20000,"data":{"financialInfo":{"balance":"25000000000000"}}}"#
        let usage = try SiliconFlowUsageFetcher.parseChinaWallet(Data(wallet.utf8))
        #expect(usage.balance?.contains("25.00") == true)
    }

    @Test func veniceBlockedCallsKeepFetchedBalance() {
        let now = Date()
        let usdBlocked = VeniceUsageSnapshot(
            canConsume: false, consumptionCurrency: "USD", diem: 3, usd: -0.25, diemEpochAllocation: 100, updatedAt: now
        ).toProviderUsage()
        #expect(usdBlocked.windows.first?.usedFraction == 1)
        #expect(usdBlocked.windows.first?.detail == "-$0.25")
        #expect(usdBlocked.balance == "-$0.25")

        let diemBlocked = VeniceUsageSnapshot(
            canConsume: false, consumptionCurrency: "DIEM", diem: 0, usd: 0.5, diemEpochAllocation: 100, updatedAt: now
        ).toProviderUsage()
        #expect(diemBlocked.windows.first?.usedFraction == 1)
        #expect(diemBlocked.windows.first?.detail == "DIEM 0.00")
        #expect(diemBlocked.balance == "DIEM 0.00")

        let noneBlocked = VeniceUsageSnapshot(
            canConsume: false, consumptionCurrency: "USD", diem: nil, usd: nil, diemEpochAllocation: nil, updatedAt: now
        ).toProviderUsage()
        #expect(noneBlocked.windows.first?.detail == "Balance unavailable for API calls")
        #expect(noneBlocked.balance == nil)
    }

    @Test func ampRecognizesEnterprisePaidWorkspace() throws {
        let output = """
        Signed in as dev@corp.com (Corp)
        Workspace Acme: usage paid by your enterprise
        """
        let snapshot = try AmpUsageFetcher.parseDisplayText(output)
        #expect(snapshot.enterpriseWorkspaces == ["Acme"])
        let usage = AmpUsageFetcher.providerUsage(snapshot)
        #expect(usage.plan == "Enterprise")
        #expect(usage.details.contains(where: { $0.label == "Workspace Acme" }))
    }

    @Test func claudeCLICompletesOnWeeklyOnlyPlan() {
        let weeklyOnly = """
        Settings:  Status   Config   Usage

        Current week (all models)
        ████████████████░░░░░░░░░░░░░░░░  32% used
        Resets Nov 30 at 12:00am (UTC)
        """
        #expect(ClaudeCLIUsageFetcher.usageComplete(weeklyOnly))
    }

    @Test func antigravityDiscoversBundledGeminiAppAgy() {
        let bundled = "/Applications/Gemini.app/Contents/Helpers/agy"
        let resolved = AntigravityUsageFetcher.resolveCommandBinary(
            environment: ["PATH": "/nonexistent", "HOME": "/tmp/nonexistent-home"],
            isExecutable: { $0 == bundled }
        )
        #expect(resolved == bundled)
    }

    @Test func openCodeGoBoundedLocalHistoryReturnsRemoteOnBudgetTimeout() async {
        let remote = ProviderUsage(
            id: ProviderID(rawValue: "opencodego"),
            state: .ready,
            windows: [UsageWindow(id: "5h", label: "5-hour", usedFraction: 0.2, resetsAt: nil, detail: nil)]
        )
        let result = await OpenCodeGoUsageFetcher.enrichWithBoundedLocalHistory(
            remote,
            budget: .milliseconds(50),
            enrich: { usage in
                Thread.sleep(forTimeInterval: 0.3)
                var enriched = usage
                enriched.today = DailyTokenUsage(tokens: 100, valueUSD: 1.0)
                return enriched
            }
        )
        #expect(result.windows == remote.windows)
        #expect(result.today == nil)
    }

    @Test func localDailyUsageScannerPricesMythos52AndGPT62Ultrafast() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeedge-sync-pricing-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeedge-sync-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempHome)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        // 1. Claude Mythos 5.2
        let claudeDir = tempHome.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18
        let iso = ISO8601DateFormatter().string(from: now)
        let claudeLine = """
        {"type":"assistant","timestamp":"\(iso)","requestId":"req-1","message":{"id":"msg-1","model":"claude-mythos-5-2","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try Data((claudeLine + "\n").utf8).write(to: claudeDir.appendingPathComponent("session.jsonl"))

        let scanner = LocalDailyUsageScanner(cacheDirectory: cacheDir)
        let claudeSummary = try #require(scanner.scan(
            providerID: ProviderID(rawValue: "claude"),
            currentWeekStart: now.addingTimeInterval(-86_400),
            now: now,
            homeDirectory: tempHome
        ))
        // $8 input + $40 output = $48
        #expect(abs((claudeSummary.today?.valueUSD ?? 0) - 48.0) < 0.001)

        // 2. Codex GPT-6.2 Astra Ultrafast (promo 3x before 2027-03-01 Pacific)
        let codexDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/18", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexLines = [
            #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"ultrafast"}}}"#,
            #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"gpt-6.2-astra","turn_id":"turn-1"}}"#,
            #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":10000},"total_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":10000}}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(codexLines.utf8).write(to: codexDir.appendingPathComponent("rollout-1.jsonl"))

        let codexSummary = try #require(scanner.scan(
            providerID: ProviderID(rawValue: "codex"),
            currentWeekStart: now.addingTimeInterval(-86_400),
            now: now,
            homeDirectory: tempHome
        ))
        // Base: 100k * 8e-6 ($0.80) + 10k * 4e-5 ($0.40) = $1.20; Ultrafast promo 3x = $3.60
        #expect(abs((codexSummary.today?.valueUSD ?? 0) - 3.60) < 0.001)
    }

    @Test func cursorTokscaleJSONReaderValidatesEnvelopeAndDeduplicatesEvents() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeedge-cursor-tokscale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let cacheDir = tempHome.appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let tsMS = Int64(now.timeIntervalSince1970 * 1000)
        let accountId = "user-123"
        let ownerHash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined()
        let generation = UUID().uuidString
        let payload = """
        {
          "_tokscale": { "version": 1, "accountId": "\(accountId)" },
          "_owner": { "version": 1, "ownerHash": "\(ownerHash)", "generation": "\(generation)" },
          "zzTokscaleOwner": { "version": 1, "generation": "\(generation)" },
          "usageEventsDisplay": [
            {
              "usageEventId": "evt-1",
              "conversationId": "conv-1",
              "timestamp": \(tsMS),
              "model": "claude-4-sonnet",
              "tokenUsage": { "inputTokens": 100, "outputTokens": 50, "totalCents": 10 }
            },
            {
              "usageEventId": "evt-1",
              "conversationId": "conv-1",
              "timestamp": \(tsMS),
              "model": "claude-4-sonnet",
              "tokenUsage": { "inputTokens": 200, "outputTokens": 100, "totalCents": 25 }
            }
          ]
        }
        """
        try Data(payload.utf8).write(to: cacheDir.appendingPathComponent("usage.json"))

        let result = CursorLocalJSONReader.load(home: tempHome, now: now)
        guard case let .report(report) = result else {
            Issue.record("Expected valid Tokscale JSON report")
            return
        }
        #expect(report.isComplete)
        // 去重保留 token 数更高的那条（200+100=300，25 cents = $0.25）
        #expect(report.today?.tokens == 300)
        #expect(abs((report.today?.valueUSD ?? 0) - 0.25) < 0.0001)
    }

    @Test func grokPreservesExplicitZeroPrepaidBalance() {
        let usage = GrokUsageFetcher.providerUsage(
            snapshot: GrokBillingSnapshot(
                usedPercent: 100,
                resetsAt: nil,
                plan: "Pro",
                percentWasPublished: true,
                windowMinutes: 120,
                prepaidBalanceUSD: 0
            ),
            credentials: nil,
            windowMinutes: nil,
            local: (nil, nil),
            now: Date()
        )
        #expect(usage.balance == "$0.00")
    }
}
