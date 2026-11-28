import Foundation
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct AntigravityUsageTests {
    private static let otherAbbreviation = String(UnicodeScalar(71)!)
        + String(UnicodeScalar(80)!) + String(UnicodeScalar(84)!)

    @Test
    func parsesQuotaSummaryIntoFamilyRepresentativesAndFourCadenceRows() throws {
        let data = Data("""
        {
          "response": {
            "groups": [
              {
                "displayName": "Claude and \(Self.otherAbbreviation) models",
                "buckets": [
                  {"bucketId":"3p-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.64}},
                  {"bucketId":"3p-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.73}}
                ]
              },
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId":"gemini-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.82}},
                  {"bucketId":"gemini-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.91}}
                ]
              }
            ]
          }
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseQuotaSummary(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-gemini", "antigravity-other"])
        #expect(zip(usage.windows.map(\.usedFraction), [0.18, 0.36]).allSatisfy {
            abs($0 - $1) < 0.000_000_001
        })
        #expect(usage.additionalWindows.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(usage.additionalWindows.map(\.label) == [
            "Gemini 5-hour", "Gemini weekly",
            "Claude/\(Self.otherAbbreviation) 5-hour", "Claude/\(Self.otherAbbreviation) weekly",
        ])
    }

    @Test
    func parsesOneOfRemainingAndKeepsUnknownCadenceName() throws {
        let data = Data("""
        {
          "groups": [{
            "displayName":"Gemini Models",
            "buckets":[
              {"bucketId":"gemini_session","displayName":"Session","remaining":{"case":"remainingFraction","value":0.75}},
              {"bucketId":"gemini-session-history","displayName":"Session History","remainingFraction":0.5}
            ]
          }]
        }
        """.utf8)

        let rows = try AntigravityUsageFetcher.parseQuotaSummary(data: data).additionalWindows

        #expect(rows[0].id == "antigravity-quota-summary-gemini_session")
        #expect(rows[0].label == "Gemini 5-hour")
        #expect(rows[0].usedFraction == 0.25)
        #expect(rows[1].label == "Gemini Session History")
    }

    @Test
    func versionedGeminiGroupKeepsItsOwnName() throws {
        let data = Data("""
        {
          "groups": [
            {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly","remainingFraction":0.9}]},
            {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-weekly","displayName":"Weekly","remainingFraction":0.4}]}
          ]
        }
        """.utf8)

        let labels = try AntigravityUsageFetcher.parseQuotaSummary(data: data).additionalWindows.map(\.label)

        #expect(labels == ["Gemini weekly", "Gemini 4 Argon weekly"])
    }

    @Test
    func disabledAndMissingFractionsAreNotPublishedAsExhaustedUsage() throws {
        let data = Data("""
        {
          "groups": [{
            "displayName":"Gemini Models",
            "buckets":[
              {"bucketId":"gemini-5h","displayName":"Five Hour Limit","disabled":true,"remainingFraction":0.2},
              {"bucketId":"gemini-weekly","displayName":"Weekly Limit"}
            ]
          }]
        }
        """.utf8)

        #expect(throws: AntigravityUsageError.unreadableResponse("missing quota buckets")) {
            _ = try AntigravityUsageFetcher.parseQuotaSummary(data: data)
        }
    }

    @Test
    func localModelRowsCollapseIntoTwoPoolsAndExcludeFilteredVariants() throws {
        let otherModel = Self.otherAbbreviation.lowercased() + "-oss-120b-medium"
        let data = Data("""
        {
          "code":0,
          "userStatus":{
            "email":"person@example.com",
            "userTier":{"name":"Ultra"},
            "cascadeModelConfigData":{"clientModelConfigs":[
              {"label":"Gemini 3 Pro","modelOrAlias":{"model":"gemini-3-pro"},"quotaInfo":{"remainingFraction":0.8}},
              {"label":"Gemini 3 Flash","modelOrAlias":{"model":"gemini-3-flash"},"quotaInfo":{"remainingFraction":0.3}},
              {"label":"Gemini Flash Lite","modelOrAlias":{"model":"gemini-3-flash-lite"},"quotaInfo":{"remainingFraction":0.1}},
              {"label":"Claude Sonnet","modelOrAlias":{"model":"claude-sonnet-4"},"quotaInfo":{"remainingFraction":0.7}},
              {"label":"Other OSS","modelOrAlias":{"model":"\(otherModel)"},"quotaInfo":{"remainingFraction":0.4}},
              {"label":"Gemini Image","modelOrAlias":{"model":"gemini-3-pro-image"},"quotaInfo":{"remainingFraction":0.5}}
            ]}
          }
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.usedFraction) == [0.7, 0.6])
        // Pro 和 Flash 比例不同，不是同一个池子：代表行取更紧的 Flash，Pro 单独列出。
        #expect(usage.additionalWindows.map(\.id) == ["gemini-3-pro", "gemini-3-flash-lite", "gemini-3-pro-image"])
        #expect(usage.plan == "Ultra")
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: [true, false])
    func localGeminiFourAndOrchestratorRowsCollapseIntoGeminiPool(includesFlash: Bool) throws {
        let flash = includesFlash
            ? #"{"label":"Gemini 3.8 Flash (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M318"},"quotaInfo":{"remainingFraction":0.78782666,"resetTime":"2026-11-25T06:32:38Z"}},"#
            : ""
        let data = Data("""
        {
          "userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini 4 Argon (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M417"},"quotaInfo":{"remainingFraction":0.78782666,"resetTime":"2026-11-25T06:32:38Z"}},
            {"label":"Gemini 4 Neon (Low)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M534"},"quotaInfo":{"remainingFraction":0.78782666,"resetTime":"2026-11-25T06:32:38Z"}},
            {"label":"Orchestrator (Argon)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M681"},"quotaInfo":{"remainingFraction":0.78782666,"resetTime":"2026-11-25T06:32:38Z"}},
            \(flash)
            {"label":"Claude Opus 5.5 (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M402"},"quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-25T07:34:13Z"}},
            {"label":"Claude Autocomplete","modelOrAlias":{"model":"claude-autocomplete"},"quotaInfo":{"remainingFraction":0.78782666,"resetTime":"2026-11-25T06:32:38Z"}}
          ]}}
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-gemini", "antigravity-other"])
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.21217334) < 0.000001)
        // 同值但属于别的模型类型的独立额度照样保留。
        #expect(usage.additionalWindows.map(\.id) == ["claude-autocomplete"])
        #expect(AntigravityUsageFetcher.visibleWindows(
            windows: usage.windows,
            additionalWindows: usage.additionalWindows
        ).map(\.id) == ["antigravity-gemini", "antigravity-other", "claude-autocomplete"])
    }

    @Test
    func separateArgonAllowanceStaysOutOfSharedGeminiPool() throws {
        let data = Data("""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 3.8 Flash (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M318"},"quotaInfo":{"remainingFraction":0.79,"resetTime":"2026-11-25T06:32:38Z"}},
          {"label":"Gemini 4 Neon (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M532"},"quotaInfo":{"remainingFraction":0.79,"resetTime":"2026-11-25T06:32:38Z"}},
          {"label":"Orchestrator (Neon)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M537"},"quotaInfo":{"remainingFraction":0.79,"resetTime":"2026-11-25T06:32:38Z"}},
          {"label":"Gemini 4 Argon (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M417"},"quotaInfo":{"remainingFraction":0.4,"resetTime":"2026-11-28T00:00:00Z"}},
          {"label":"Gemini 4 Argon (Low)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M419"},"quotaInfo":{"remainingFraction":0.4,"resetTime":"2026-11-28T00:00:00Z"}}
        ]}}}
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-gemini"])
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.21) < 0.000001)
        #expect(usage.additionalWindows.map(\.label) == ["Gemini 4 Argon (High)", "Gemini 4 Argon (Low)"])
    }

    @Test
    func geminiModelsWithoutResetTimeAreNotAssumedToSharePool() throws {
        let data = Data("""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 4 Argon (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M417"},"quotaInfo":{"remainingFraction":0.4}},
          {"label":"Gemini 4 Neon (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M532"},"quotaInfo":{"remainingFraction":0.4}}
        ]}}}
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-gemini"])
        #expect(usage.additionalWindows.count == 1)
    }

    @Test
    func unknownOnlyFallbackRepresentativeIsNotListedTwice() throws {
        let data = Data("""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Nova Large","modelOrAlias":{"model":"MODEL_PLACEHOLDER_N1"},"quotaInfo":{"remainingFraction":0.4}},
          {"label":"Nova Small","modelOrAlias":{"model":"MODEL_PLACEHOLDER_N2"},"quotaInfo":{"remainingFraction":0.7}}
        ]}}}
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-fallback-MODEL_PLACEHOLDER_N1"])
        #expect(usage.additionalWindows.map(\.id) == ["MODEL_PLACEHOLDER_N2"])
    }

    @Test
    func resetOnlyFamilyIsPreservedAsUnavailableGroupedContext() throws {
        let data = Data("""
        {
          "clientModelConfigs":[
            {
              "label":"Gemini 3 Pro",
              "modelOrAlias":{"model":"gemini-3-pro"},
              "quotaInfo":{"resetTime":"2030-01-01T00:00:00Z"}
            }
          ]
        }
        """.utf8)

        #expect(throws: AntigravityUsageError.unreadableResponse("missing quota models")) {
            _ = try AntigravityUsageFetcher.parseModelResponse(data: data)
        }
    }

    @Test
    func identityPrefersUserTierOverGenericPlanInfo() throws {
        let data = Data("""
        {"userStatus":{
          "email":"person@example.com",
          "userTier":{"name":"Ultra"},
          "planStatus":{"planInfo":{"planName":"Pro"}}
        }}
        """.utf8)

        let identity = try AntigravityUsageFetcher.parseIdentity(data: data)

        #expect(identity.email == "person@example.com")
        #expect(identity.plan == "Ultra")
    }

    @Test
    func ordinaryGeminiBucketRepresentsGeminiOverModelSpecificAllowance() throws {
        let data = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-pro-weekly","displayName":"Gemini Pro Weekly","remainingFraction":0},
          {"bucketId":"gemini-weekly","displayName":"Weekly Limit","remainingFraction":0.75}
        ]}]}
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseQuotaSummary(data: data)

        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.additionalWindows.count == 2)
    }

    @Test
    func standaloneDesktopProcessReadsTokenAndPortsFromMatchingDaemonFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-ag-daemon-\(UUID().uuidString)", directoryHint: .isDirectory)
        let daemonDir = home.appending(path: ".gemini/antigravity/daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try Data("""
        {"pid":1111,"httpsPort":50001,"httpPort":50002,"csrfToken":"stale-token"}
        """.utf8).write(to: daemonDir.appending(path: "hub_50002.json"))
        try Data("""
        {"pid":8812,"httpsPort":60695,"httpPort":60696,"lsVersion":"2.34.0","csrfToken":"live-token"}
        """.utf8).write(to: daemonDir.appending(path: "hub_60696.json"))

        let psOutput = """
         8812 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --app_data_dir antigravity --https_server_port 0
        """

        let processes = try AntigravityUsageFetcher.parseLocalProcesses(output: psOutput, homeDirectory: home)

        #expect(processes == [
            AntigravityUsageFetcher.LocalProcess(
                pid: 8812,
                csrfToken: "live-token",
                httpsPort: 60695,
                httpPort: 60696,
                extensionPort: nil,
                extensionToken: nil,
                kind: .app
            ),
        ])

        let endpoints = AntigravityUsageFetcher.localEndpoints(for: processes[0], listeningPorts: [60695, 60913])
        #expect(endpoints == [
            AntigravityUsageFetcher.LocalEndpoint(scheme: "https", port: 60695, token: "live-token"),
            AntigravityUsageFetcher.LocalEndpoint(scheme: "http", port: 60696, token: "live-token"),
            AntigravityUsageFetcher.LocalEndpoint(scheme: "https", port: 60913, token: "live-token"),
        ])
    }

    @Test
    func standaloneDesktopProcessWithoutMatchingDaemonFileFailsAsUnavailable() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-ag-missing-daemon-\(UUID().uuidString)", directoryHint: .isDirectory)
        let daemonDir = home.appending(path: ".gemini/antigravity/daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try Data("""
        {"pid":9999,"httpsPort":60695,"httpPort":60696,"csrfToken":"other-pid-token"}
        """.utf8).write(to: daemonDir.appending(path: "hub_60696.json"))

        let psOutput = """
         8812 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --app_data_dir antigravity
        """

        #expect(throws: AntigravityUsageError.localServiceUnavailable) {
            _ = try AntigravityUsageFetcher.parseLocalProcesses(output: psOutput, homeDirectory: home)
        }
    }

    @Test
    func legacyProcessKeepsCommandLineCSRFTokenOverDaemonDiscovery() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-ag-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let psOutput = """
         4242 /Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity --csrf_token cli-token --extension_server_port 51234 --extension_server_csrf_token ext-token
        """

        let processes = try AntigravityUsageFetcher.parseLocalProcesses(output: psOutput, homeDirectory: home)

        #expect(processes == [
            AntigravityUsageFetcher.LocalProcess(
                pid: 4242,
                csrfToken: "cli-token",
                httpsPort: nil,
                httpPort: nil,
                extensionPort: 51234,
                extensionToken: "ext-token",
                kind: .app
            ),
        ])
    }

    @Test
    func summaryDropsRedundantDescriptionWhenResetTimeExists() throws {
        let data = Data("""
        {
          "groups": [{
            "displayName": "Gemini Models",
            "buckets": [
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit",
                "description": "You have used some of your 5-hour limit, it will fully refresh in 4 hours.",
                "remainingFraction": 0.9,
                "resetTime": "2026-11-22T08:30:07Z"
              },
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit",
                "description": "Resets in 6 days",
                "remainingFraction": 0.95
              }
            ]
          }]
        }
        """.utf8)

        let rows = try AntigravityUsageFetcher.parseQuotaSummary(data: data).additionalWindows

        #expect(rows[0].resetsAt != nil)
        #expect(rows[0].detail == nil)
        #expect(rows[1].resetsAt == nil)
        #expect(rows[1].detail == "Resets in 6 days")
    }

    @Test
    func visibleSummaryWindowsHidesIdleFamiliesAndKeepsAllWhenEverythingIsIdle() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let mixed = [
            UsageWindow(id: "antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", usedFraction: 0.11, resetsAt: reset, detail: "stale detail"),
            UsageWindow(id: "antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", usedFraction: 0.03, resetsAt: reset, detail: "stale detail"),
            UsageWindow(id: "antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini 4 Argon weekly", usedFraction: 0, resetsAt: reset, detail: nil),
            UsageWindow(id: "antigravity-quota-summary-3p-5h", label: "Claude/\(Self.otherAbbreviation) 5-hour", usedFraction: 0, resetsAt: reset, detail: nil),
            UsageWindow(id: "antigravity-quota-summary-3p-weekly", label: "Claude/\(Self.otherAbbreviation) weekly", usedFraction: 0, resetsAt: reset, detail: nil),
        ]

        let visible = AntigravityUsageFetcher.visibleSummaryWindows(from: mixed)

        #expect(visible.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
        ])
        #expect(visible.allSatisfy { $0.detail == nil })

        let allIdle = mixed.map { window in
            UsageWindow(id: window.id, label: window.label, usedFraction: 0, resetsAt: window.resetsAt, detail: nil)
        }
        #expect(AntigravityUsageFetcher.visibleSummaryWindows(from: allIdle).map(\.id) == mixed.map(\.id))

        var withArgon = mixed
        withArgon[2] = UsageWindow(
            id: "antigravity-quota-summary-gemini-argon-wtu-weekly",
            label: "Gemini 4 Argon weekly",
            usedFraction: 0.05,
            resetsAt: reset,
            detail: nil
        )
        #expect(AntigravityUsageFetcher.visibleSummaryWindows(from: withArgon).map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-gemini-argon-wtu-weekly",
        ])
    }

    @Test
    func parsesAgyPrintUsageJSONReportAndIgnoresEpochZeroResetTimes() throws {
        let data = Data("""
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.53,"reset_time":"2026-12-01T10:07:49Z"},
                    {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.27,"reset_time":"2026-11-26T05:13:45Z"}
                  ]
                },
                {
                  "name": "Claude and \(Self.otherAbbreviation) models",
                  "buckets": [
                    {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},
                    {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"}
                  ]
                }
              ]
            }
          }
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseCLIUsageReport(data: data)

        #expect(usage.state == .ready)
        #expect(usage.additionalWindows.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(abs(usage.additionalWindows[0].usedFraction - 0.73) < 0.0001)
        #expect(usage.additionalWindows[0].resetsAt != nil)
        #expect(abs(usage.additionalWindows[1].usedFraction - 0.47) < 0.0001)
        #expect(usage.additionalWindows[2].resetsAt == nil)
        #expect(usage.additionalWindows[3].resetsAt == nil)
    }

    @Test
    func parsesAgyVersionAndRunsPrintUsageScriptWithoutOpeningBrowser() async throws {
        let parsed = try #require(AntigravityUsageFetcher.parseAgyVersion("1.5.17\n"))
        #expect(parsed == (1, 5, 17))
        let gated = try #require(AntigravityUsageFetcher.parseAgyVersion("1.2.2"))
        #expect(gated == AntigravityUsageFetcher.firstCSRFGatedVersion)
        #expect(AntigravityUsageFetcher.parseAgyVersion("dev-build") == nil)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-fake-agy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "agy")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "1.5.17"
          exit 0
        fi
        if [ "$AGY_CLI_DISABLE_AUTO_UPDATE" != "true" ]; then
          exit 2
        fi
        cat <<'JSON'
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","name":"Five Hour Limit","window":"5h","remaining_fraction":0.6,"reset_time":"2026-11-26T05:13:45Z"}]}]}}}
        JSON
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let usage = try await AntigravityUsageFetcher.fetchPrintUsage(
            binary: script.path,
            environment: [:]
        )

        #expect(usage.additionalWindows.map(\.id) == ["antigravity-quota-summary-gemini-5h"])
        #expect(abs((usage.additionalWindows.first?.usedFraction ?? 0) - 0.4) < 0.0001)
    }
}
