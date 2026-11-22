import Foundation
import SQLite3
import Testing
@testable import CodeEdge

struct AntigravityLocalUsageTests {
    @Test
    func scansSQLiteConversationsWithStepTimestampRecoveryAndPublicPricing() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-ag-local-\(UUID().uuidString)", directoryHint: .isDirectory)
        let conversations = home.appending(path: ".gemini/antigravity/conversations", directoryHint: .isDirectory)
        let appRoot = home.appending(path: ".gemini/antigravity", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date(timeIntervalSince1970: 1_795_320_000)
        let turn1Time = UInt64(now.addingTimeInterval(-600).timeIntervalSince1970)
        let turn2Time = UInt64(now.addingTimeInterval(-300).timeIntervalSince1970)

        // 外部无关数据库（没有 gen_metadata 表）应被安全忽略。
        try createForeignDB(at: appRoot.appending(path: "conversation_summaries.db"))

        let dbURL = conversations.appending(path: "session-a.db")
        try createConversationDB(
            at: dbURL,
            generations: [
                (
                    idx: 0,
                    blob: makeGenMetadataBlob(
                        model: "gemini-4-neon",
                        label: "Gemini 4 Neon",
                        newInput: 100_000,
                        cacheRead: 200_000,
                        output: 20_000,
                        reasoning: 10_000,
                        responseID: "resp-1",
                        botID: "bot-1",
                        stepUUID: "step-1",
                        embeddedTimestampSec: nil
                    )
                ),
                (
                    idx: 1,
                    blob: makeGenMetadataBlob(
                        model: "gpt-oss-120b-medium",
                        label: nil,
                        newInput: 50_000,
                        cacheRead: 0,
                        output: 10_000,
                        reasoning: 0,
                        responseID: "resp-2",
                        botID: nil,
                        stepUUID: "step-2",
                        embeddedTimestampSec: turn2Time
                    )
                ),
            ],
            steps: [
                (idx: 0, blob: makeStepMetadataBlob(timestampSec: turn1Time, stepUUID: "step-1", botID: "bot-1")),
            ]
        )

        let catalog = try JSONDecoder().decode(
            ModelPricingCatalog.self,
            from: Data("""
            {
              "google": {
                "models": {
                  "gemini-4-neon": {
                    "id": "gemini-4-neon",
                    "cost": {"input": 3, "cache_read": 0.15, "output": 15}
                  }
                }
              },
              "google-vertex": {
                "models": {
                  "openai/gpt-oss-120b-maas": {
                    "id": "openai/gpt-oss-120b-maas",
                    "cost": {"input": 0.2, "output": 0.8}
                  }
                }
              }
            }
            """.utf8)
        )

        let scanner = LocalDailyUsageScanner()
        let summary = await scanner.scan(
            providerID: ProviderID(rawValue: "antigravity"),
            currentWeekStart: now.addingTimeInterval(-3600),
            now: now,
            homeDirectory: home,
            pricingCatalog: catalog
        )

        let resolved = try #require(summary)
        // turn1: 100k + 200k + 20k + 10k = 330k; turn2: 50k + 10k = 60k -> total 390k
        #expect(resolved.today?.tokens == 390_000)
        #expect(resolved.last30Days?.tokens == 390_000)
        #expect(resolved.currentWeek?.tokens == 390_000)

        // turn1 cost: 0.1*3 + 0.2*0.15 + 0.03*15 = 0.30 + 0.03 + 0.45 = 0.78
        // turn2 cost: 0.05*0.2 + 0.01*0.8 = 0.01 + 0.008 = 0.018
        // total = 0.798
        let cost = try #require(resolved.today?.valueUSD)
        #expect(abs(cost - 0.798) < 0.000_001)
        #expect(resolved.todayByModel?.map(\.model) == ["gemini-4-neon", "gpt-oss-120b-medium"])
    }

    @Test
    func deduplicatesDuplicateResponseIDsAcrossDatabases() {
        let now = Date(timeIntervalSince1970: 1_795_320_000)
        let first = AntigravityLocalUsageEntry(
            session: "same-session", row: 0, responseID: "resp-dup",
            timestamp: now, model: "gemini-4-neon",
            inputTokens: 1_000, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 200, reasoningTokens: 0
        )
        let copy = AntigravityLocalUsageEntry(
            session: "same-session", row: 1, responseID: "resp-dup",
            timestamp: now, model: "gemini-4-neon",
            inputTokens: 1_000, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 200, reasoningTokens: 0
        )

        #expect(AntigravityLocalUsageReader.deduplicated([first, copy]) == [first])
    }

    @Test
    func weeklyWindowSelectsMostConstrainedAntigravityWeeklySummaryBucket() throws {
        let descriptor = try #require(ProviderCatalog.all.first { $0.id.rawValue == "antigravity" })
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: [
                UsageWindow(id: "antigravity-gemini", label: "Gemini Models", usedFraction: 0.14, resetsAt: reset, windowMinutes: 300),
                UsageWindow(id: "antigravity-other", label: "Claude and GPT models", usedFraction: 0, resetsAt: reset, windowMinutes: 300),
            ],
            additionalWindows: [
                UsageWindow(id: "antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", usedFraction: 0.14, resetsAt: reset, windowMinutes: 300),
                UsageWindow(id: "antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", usedFraction: 0.04, resetsAt: reset, windowMinutes: 10_080),
                UsageWindow(id: "antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", usedFraction: 0, resetsAt: reset, windowMinutes: 10_080),
            ],
            updatedAt: Date()
        )

        let weekly = UsageCollector.weeklyWindow(in: usage, descriptor: descriptor)
        #expect(weekly?.id == "antigravity-quota-summary-gemini-weekly")
        #expect(weekly?.usedFraction == 0.04)
    }

    // MARK: - SQLite & Protobuf Fixtures

    private func createForeignDB(at url: URL) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE summaries (id TEXT PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
    }

    private func createConversationDB(
        at url: URL,
        generations: [(idx: Int64, blob: [UInt8])],
        steps: [(idx: Int64, blob: [UInt8])]
    ) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK)
        for row in generations {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, row.idx)
            _ = row.blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
            sqlite3_bind_int64(stmt, 3, Int64(row.blob.count))
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
        sqlite3_finalize(stmt)

        stmt = nil
        #expect(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, metadata) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK)
        for row in steps {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, row.idx)
            _ = row.blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
        sqlite3_finalize(stmt)
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        encodeVarint(UInt64(number << 3)) + encodeVarint(value)
    }

    private func bytesField(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        encodeVarint(UInt64((number << 3) | 2)) + encodeVarint(UInt64(payload.count)) + payload
    }

    private func stringField(_ number: Int, _ text: String) -> [UInt8] {
        bytesField(number, Array(text.utf8))
    }

    private func makeGenMetadataBlob(
        model: String,
        label: String?,
        newInput: UInt64,
        cacheRead: UInt64,
        output: UInt64,
        reasoning: UInt64,
        responseID: String?,
        botID: String?,
        stepUUID: String?,
        embeddedTimestampSec: UInt64?
    ) -> [UInt8] {
        var usage: [UInt8] = []
        usage += varintField(1, 1532)
        usage += varintField(2, newInput)
        if cacheRead > 0 { usage += varintField(5, cacheRead) }
        if let botID { usage += stringField(7, botID) }
        if reasoning > 0 { usage += varintField(9, reasoning) }
        usage += varintField(10, output)
        if let responseID { usage += stringField(11, responseID) }

        var chat: [UInt8] = []
        chat += bytesField(4, usage)
        if let embeddedTimestampSec {
            let ts = varintField(1, embeddedTimestampSec)
            let gen = bytesField(4, ts)
            chat += bytesField(9, gen)
        }
        chat += stringField(19, model)
        if let label { chat += stringField(21, label) }

        var root = bytesField(1, chat)
        if let stepUUID { root += stringField(4, stepUUID) }
        return root
    }

    private func makeStepMetadataBlob(timestampSec: UInt64, stepUUID: String, botID: String?) -> [UInt8] {
        var root = bytesField(1, varintField(1, timestampSec))
        if let botID {
            root += bytesField(9, stringField(7, botID))
        }
        root += stringField(12, stepUUID)
        return root
    }
}
