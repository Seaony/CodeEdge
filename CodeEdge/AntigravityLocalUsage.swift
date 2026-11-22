import Foundation
import SQLite3

nonisolated struct AntigravityDatabaseFingerprint: Equatable, Sendable {
    var mainSize: UInt64
    var mainModifiedNanoseconds: Int64
    var walSize: UInt64
    var walModifiedNanoseconds: Int64

    var latestModifiedDate: Date {
        let latest = max(mainModifiedNanoseconds, walModifiedNanoseconds)
        return Date(timeIntervalSince1970: Double(latest) / 1_000_000_000)
    }
}

nonisolated struct AntigravityLocalUsageEntry: Equatable, Sendable {
    var session: String
    var row: Int64
    var responseID: String?
    var timestamp: Date
    var model: String
    var inputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int

    var billedOutputTokens: Int { outputTokens + reasoningTokens }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens + reasoningTokens
    }
}

/// 读取 Antigravity 在本机保存的会话 SQLite 数据库，统计可验证的 Token 用量与预估金额，
/// 逻辑对齐 CodexBar 的 AntigravityLocalReader / AntigravityLocalSQLite / AntigravityProtoReader。
nonisolated enum AntigravityLocalUsageReader {
    private static let maxBlobBytes = 16 * 1024 * 1024
    private static let maxRowsPerDatabase = 10_000

    private static let routingVariantSuffixes = ["-tiered", "-low", "-thinking"]

    private static let pricingModelAliases: [String: String] = [
        "gemini-pro-default": "gemini-3.1-pro-preview",
        "gemini-pro-agent": "gemini-3.1-pro-preview",
        "gemini-3.1-pro": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-high": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-low": "gemini-3.1-pro-preview",
        "gemini-3.7-flash-safety-le": "gemini-3.7-flash",
    ]

    static let explicitCatalogEntries: [String: (providerID: String, modelID: String)] = [
        "gpt-oss-120b-medium": (providerID: "google-vertex", modelID: "openai/gpt-oss-120b-maas"),
    ]

    static func pricingBaseModelID(for model: String) -> String? {
        let lowered = model.lowercased()
        if let alias = pricingModelAliases[lowered] { return alias }
        guard let suffix = routingVariantSuffixes.first(where: lowered.hasSuffix) else { return nil }
        let base = String(model.dropLast(suffix.count))
        return base.isEmpty ? nil : pricingModelAliases[base.lowercased()] ?? base
    }

    static func databaseRoots(homeDirectory: URL, environment: [String: String]) -> [URL] {
        let geminiHome: URL
        if let override = environment["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            geminiHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            geminiHome = homeDirectory.appending(path: ".gemini", directoryHint: .isDirectory)
        }
        let candidates = [
            geminiHome.appending(path: "antigravity-cli/conversations", directoryHint: .isDirectory),
            geminiHome.appending(path: "antigravity", directoryHint: .isDirectory),
            geminiHome.appending(path: "antigravity/conversations", directoryHint: .isDirectory),
        ]
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    static func discoverDatabases(roots: [URL]) -> [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let resolved = root.resolvingSymlinksInPath()
            guard let items = try? manager.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items where item.pathExtension.lowercased() == "db" {
                let real = item.resolvingSymlinksInPath()
                guard (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                if seen.insert(real.path).inserted {
                    urls.append(real)
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    static func fingerprint(of url: URL) -> AntigravityDatabaseFingerprint? {
        let resolved = url.resolvingSymlinksInPath()
        guard let main = fileStats(atPath: resolved.path) else { return nil }
        let wal = fileStats(atPath: resolved.path + "-wal")
        return AntigravityDatabaseFingerprint(
            mainSize: main.size,
            mainModifiedNanoseconds: main.modifiedNanoseconds,
            walSize: wal?.size ?? 0,
            walModifiedNanoseconds: wal?.modifiedNanoseconds ?? 0
        )
    }

    static func readDatabase(at url: URL) -> [AntigravityLocalUsageEntry]? {
        let attempt = readDatabase(at: url, immutable: false)
        if !attempt.cannotOpen {
            return attempt.entries
        }
        // 已干净关闭的无 -wal WAL 数据库用普通只读模式可能报 SQLITE_CANTOPEN，改用 immutable 读取并校验前后文件不变。
        guard let before = IdleDatabaseState.read(at: url) else { return nil }
        let fallback = readDatabase(at: url, immutable: true)
        guard IdleDatabaseState.read(at: url) == before else { return nil }
        return fallback.entries
    }

    static func deduplicated(_ entries: [AntigravityLocalUsageEntry]) -> [AntigravityLocalUsageEntry] {
        struct RowKey: Hashable {
            let session: String
            let row: Int64
        }
        struct ResponseKey: Hashable {
            let session: String
            let responseID: String
        }
        var seenRows = Set<RowKey>()
        var seenResponses = Set<ResponseKey>()
        var result: [AntigravityLocalUsageEntry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            let rowKey = RowKey(session: entry.session, row: entry.row)
            guard !seenRows.contains(rowKey) else { continue }
            if let responseID = entry.responseID {
                let responseKey = ResponseKey(session: entry.session, responseID: responseID)
                guard !seenResponses.contains(responseKey) else { continue }
                seenResponses.insert(responseKey)
            }
            seenRows.insert(rowKey)
            result.append(entry)
        }
        return result
    }

    // MARK: - SQLite

    private struct DatabaseReadAttempt {
        var entries: [AntigravityLocalUsageEntry]?
        var cannotOpen: Bool
    }

    private struct IdleDatabaseState: Equatable {
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64
        let header: Data

        static func read(at url: URL) -> Self? {
            let resolved = url.resolvingSymlinksInPath()
            guard !FileManager.default.fileExists(atPath: resolved.path + "-wal"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let handle = try? FileHandle(forReadingFrom: resolved)
            else { return nil }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 100) else { return nil }
            return Self(size: size, modified: modified, fileNumber: fileNumber, header: header)
        }

        static func immutableURI(for url: URL) -> String? {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "%?#")
            guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "file:\(path)?immutable=1"
        }
    }

    private static func readDatabase(at url: URL, immutable: Bool) -> DatabaseReadAttempt {
        var handle: OpaquePointer?
        let openStatus: Int32
        if immutable {
            guard let uri = IdleDatabaseState.immutableURI(for: url) else {
                return DatabaseReadAttempt(entries: nil, cannotOpen: false)
            }
            openStatus = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        } else {
            openStatus = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        }
        guard openStatus == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            return DatabaseReadAttempt(entries: nil, cannotOpen: openStatus == SQLITE_CANTOPEN)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        let began = sqlite3_exec(db, "BEGIN DEFERRED", nil, nil, nil)
        guard began == SQLITE_OK else {
            return DatabaseReadAttempt(entries: nil, cannotOpen: began == SQLITE_CANTOPEN)
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        let support = tableSupport(db, table: "gen_metadata", requiredColumns: ["idx", "data"])
        switch support {
        case .foreign:
            return DatabaseReadAttempt(entries: [], cannotOpen: false)
        case .unsupported:
            return DatabaseReadAttempt(entries: nil, cannotOpen: sqlite3_errcode(db) == SQLITE_CANTOPEN)
        case .supported:
            break
        }

        let session = url.deletingPathExtension().lastPathComponent
        guard var parsed = readGenerationRows(db) else {
            return DatabaseReadAttempt(entries: nil, cannotOpen: sqlite3_errcode(db) == SQLITE_CANTOPEN)
        }

        if !parsed.pendingTimestampRows.isEmpty,
           tableSupport(db, table: "steps", requiredColumns: ["idx", "metadata"]) == .supported {
            var needed: [String: [StepOccurrence]] = [:]
            for stepUUID in Set(parsed.pendingTimestampRows.map(\.stepUUID)) {
                needed[stepUUID] = parsed.stepOccurrences[stepUUID] ?? []
            }
            if let stepScan = readStepTimestamps(db, needed: needed),
               embeddedTimestampsAgree(needed, with: stepScan, botIDUses: parsed.botIDUses) {
                recoverStepTimestamps(into: &parsed, stepScan: stepScan)
            }
        }

        return DatabaseReadAttempt(entries: finalizeEntries(parsed.resolvedRows, session: session), cannotOpen: false)
    }

    private enum TableSupport {
        case supported
        case foreign
        case unsupported
    }

    private static func tableSupport(
        _ db: OpaquePointer,
        table: String,
        requiredColumns: Set<String>
    ) -> TableSupport {
        var statement: OpaquePointer?
        let checkSQL = "SELECT 1 FROM main.sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(db, checkSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .unsupported
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = table.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        let exists = sqlite3_step(statement)
        if exists == SQLITE_DONE { return .foreign }
        guard exists == SQLITE_ROW else { return .unsupported }

        var infoStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA main.table_info(\(table))", -1, &infoStatement, nil) == SQLITE_OK,
              let infoStatement
        else { return .unsupported }
        defer { sqlite3_finalize(infoStatement) }

        var columns = Set<String>()
        while sqlite3_step(infoStatement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(infoStatement, 1) {
                columns.insert(String(cString: raw).lowercased())
            }
        }
        return requiredColumns.isSubset(of: columns) ? .supported : .unsupported
    }

    private struct ResolvedTurnRow {
        let row: Int64
        let turn: ProtoReader.ParsedTurn
    }

    private struct PendingTimestampRow {
        let row: Int64
        let stepUUID: String
        let turn: ProtoReader.ParsedTurn
    }

    private struct StepOccurrence {
        let row: Int64
        let timestampMs: Int64?
        let botID: String?
    }

    private struct ExactStepTimestamp {
        let stepUUID: String
        let timestampMs: Int64
    }

    private struct StepTimestampScan {
        let timestamps: [String: [Int64]]
        let byBotID: [String: ExactStepTimestamp]
        let ambiguousBotIDs: Set<String>
    }

    private struct GenerationScan {
        var resolvedRows: [ResolvedTurnRow] = []
        var pendingTimestampRows: [PendingTimestampRow] = []
        var stepOccurrences: [String: [StepOccurrence]] = [:]
        var botIDUses: [String: Int] = [:]
    }

    private static func readGenerationRows(_ db: OpaquePointer) -> GenerationScan? {
        let query = """
        SELECT idx, data
        FROM main.gen_metadata NOT INDEXED
        WHERE typeof(data) = 'blob' AND length(data) > 0 AND length(data) <= ?
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(maxBlobBytes))
        sqlite3_bind_int64(statement, 2, Int64(maxRowsPerDatabase))

        var scan = GenerationScan()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { continue }
            let row = sqlite3_column_int64(statement, 0)
            guard row >= 0, let bytes = blobBytes(statement, column: 1) else { continue }
            guard let turn = ProtoReader.parseTurn(bytes) else { continue }
            if let botID = turn.usage?.botID {
                scan.botIDUses[botID, default: 0] += 1
            }
            if let stepUUID = turn.stepUUID {
                scan.stepOccurrences[stepUUID, default: []].append(StepOccurrence(
                    row: row,
                    timestampMs: turn.timestampMs,
                    botID: turn.usage?.botID
                ))
            }
            if turn.timestampMs == nil, let stepUUID = turn.stepUUID {
                scan.pendingTimestampRows.append(PendingTimestampRow(row: row, stepUUID: stepUUID, turn: turn))
            } else if turn.usage != nil, turn.timestampMs != nil {
                scan.resolvedRows.append(ResolvedTurnRow(row: row, turn: turn))
            }
        }
        return scan
    }

    private static func readStepTimestamps(
        _ db: OpaquePointer,
        needed: [String: [StepOccurrence]]
    ) -> StepTimestampScan? {
        guard !needed.isEmpty else {
            return StepTimestampScan(timestamps: [:], byBotID: [:], ambiguousBotIDs: [])
        }
        let query = """
        SELECT idx, metadata
        FROM main.steps NOT INDEXED
        WHERE typeof(metadata) = 'blob' AND length(metadata) > 0 AND length(metadata) <= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(maxBlobBytes))

        var stepTimestamps: [String: [StepOccurrence]] = [:]
        var exactByBotID: [String: ExactStepTimestamp] = [:]
        var ambiguousBotIDs = Set<String>()
        var sawUnidentifiedRows = false

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { continue }
            let row = sqlite3_column_int64(statement, 0)
            guard row >= 0, let bytes = blobBytes(statement, column: 1),
                  let parsed = ProtoReader.parseStepMetadata(bytes)
            else { continue }
            if let botID = parsed.botID {
                recordExactBotID(
                    botID,
                    stepUUID: parsed.stepUUID,
                    timestampMs: parsed.timestampMs,
                    exact: &exactByBotID,
                    ambiguous: &ambiguousBotIDs
                )
            }
            guard let stepUUID = parsed.stepUUID else {
                sawUnidentifiedRows = true
                continue
            }
            if needed[stepUUID] != nil {
                stepTimestamps[stepUUID, default: []].append(StepOccurrence(
                    row: row,
                    timestampMs: parsed.timestampMs,
                    botID: parsed.botID
                ))
            }
        }

        let resolved = resolveStepTimestamps(
            stepTimestamps,
            needed: needed,
            ambiguousBotIDs: ambiguousBotIDs,
            unidentifiedRowsPresent: sawUnidentifiedRows
        )
        return StepTimestampScan(
            timestamps: resolved,
            byBotID: exactByBotID,
            ambiguousBotIDs: ambiguousBotIDs
        )
    }

    private static func recordExactBotID(
        _ botID: String,
        stepUUID: String?,
        timestampMs: Int64?,
        exact: inout [String: ExactStepTimestamp],
        ambiguous: inout Set<String>
    ) {
        guard !ambiguous.contains(botID) else { return }
        guard let stepUUID, let timestampMs else {
            exact.removeValue(forKey: botID)
            ambiguous.insert(botID)
            return
        }
        if let existing = exact[botID] {
            if existing.timestampMs != timestampMs || existing.stepUUID != stepUUID {
                exact.removeValue(forKey: botID)
                ambiguous.insert(botID)
            }
        } else {
            exact[botID] = ExactStepTimestamp(stepUUID: stepUUID, timestampMs: timestampMs)
        }
    }

    private static func embeddedTimestampsAgree(
        _ occurrences: [String: [StepOccurrence]],
        with stepScan: StepTimestampScan,
        botIDUses: [String: Int]
    ) -> Bool {
        for (stepUUID, rows) in occurrences {
            for row in rows {
                guard let timestampMs = row.timestampMs, let botID = row.botID else { continue }
                guard !stepScan.ambiguousBotIDs.contains(botID) else { return false }
                if let exact = stepScan.byBotID[botID],
                   exact.stepUUID != stepUUID || (botIDUses[botID] == 1 && exact.timestampMs != timestampMs) {
                    return false
                }
            }
        }
        return true
    }

    private static func resolveStepTimestamps(
        _ stepTimestamps: [String: [StepOccurrence]],
        needed: [String: [StepOccurrence]],
        ambiguousBotIDs: Set<String>,
        unidentifiedRowsPresent: Bool
    ) -> [String: [Int64]] {
        var resolved: [String: [Int64]] = [:]
        for (stepUUID, timestamps) in stepTimestamps {
            guard let occurrences = needed[stepUUID] else { continue }
            let sortedOccurrences = occurrences.sorted { $0.row < $1.row }
            guard Set(sortedOccurrences.map(\.row)).count == sortedOccurrences.count else { continue }
            let neededCount = sortedOccurrences.count
            let sorted = timestamps.sorted { $0.row < $1.row }
            guard !zip(sorted, sorted.dropFirst()).contains(where: { $0.row == $1.row }) else { continue }
            let orderedTimestamps = sorted.map { step in
                step.botID.map { ambiguousBotIDs.contains($0) } == true ? nil : step.timestampMs
            }
            let selected: [Int64]
            if orderedTimestamps.count == 1, neededCount == 1 || !unidentifiedRowsPresent,
               let shared = orderedTimestamps[0] {
                selected = Array(repeating: shared, count: neededCount)
            } else {
                guard orderedTimestamps.count >= neededCount else { continue }
                let candidates = orderedTimestamps.prefix(neededCount)
                guard candidates.allSatisfy({ $0 != nil }) else { continue }
                selected = candidates.compactMap(\.self)
            }
            guard zip(sortedOccurrences, selected).allSatisfy({ pair in
                pair.0.timestampMs == nil || pair.0.timestampMs == pair.1
            }) else { continue }
            resolved[stepUUID] = selected
        }
        return resolved
    }

    private static func recoverStepTimestamps(
        into scan: inout GenerationScan,
        stepScan: StepTimestampScan
    ) {
        var occurrenceOffsets: [String: [Int64: Int]] = [:]
        for (stepUUID, occurrences) in scan.stepOccurrences {
            let sorted = occurrences.map(\.row).sorted()
            guard Set(sorted).count == sorted.count else { continue }
            occurrenceOffsets[stepUUID] = Dictionary(
                uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) }
            )
        }
        for pending in scan.pendingTimestampRows.sorted(by: { $0.row < $1.row }) {
            if let botID = pending.turn.usage?.botID {
                if stepScan.ambiguousBotIDs.contains(botID) { continue }
                if let exact = stepScan.byBotID[botID] {
                    guard exact.stepUUID == pending.stepUUID else { continue }
                }
                if scan.botIDUses[botID] == 1, let exact = stepScan.byBotID[botID] {
                    var turn = pending.turn
                    turn.timestampMs = exact.timestampMs
                    if turn.usage != nil {
                        scan.resolvedRows.append(ResolvedTurnRow(row: pending.row, turn: turn))
                    }
                    continue
                }
            }
            guard let timestamps = stepScan.timestamps[pending.stepUUID],
                  let offset = occurrenceOffsets[pending.stepUUID]?[pending.row],
                  timestamps.indices.contains(offset)
            else { continue }
            var turn = pending.turn
            turn.timestampMs = timestamps[offset]
            if turn.usage != nil {
                scan.resolvedRows.append(ResolvedTurnRow(row: pending.row, turn: turn))
            }
        }
        scan.resolvedRows.sort { $0.row < $1.row }
    }

    private static func finalizeEntries(
        _ rows: [ResolvedTurnRow],
        session: String
    ) -> [AntigravityLocalUsageEntry] {
        var modelsByLabel: [String: String] = [:]
        var conflictingLabels = Set<String>()
        for item in rows {
            if let label = item.turn.label, let model = item.turn.model {
                if let existing = modelsByLabel[label], existing != model {
                    conflictingLabels.insert(label)
                } else {
                    modelsByLabel[label] = model
                }
            }
        }
        return rows.compactMap { item in
            guard let usage = item.turn.usage, let timestampMs = item.turn.timestampMs else { return nil }
            let inherited = item.turn.label.flatMap { conflictingLabels.contains($0) ? nil : modelsByLabel[$0] }
            let rawModel = (item.turn.model ?? inherited ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModel.isEmpty ? "unknown" : rawModel
            guard let total = checkedSum([usage.newInput, usage.cacheRead, usage.output, usage.reasoning]),
                  total >= 0
            else { return nil }
            return AntigravityLocalUsageEntry(
                session: session,
                row: item.row,
                responseID: usage.responseID,
                timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000),
                model: model,
                inputTokens: usage.newInput,
                cacheReadTokens: usage.cacheRead,
                cacheWriteTokens: 0,
                outputTokens: usage.output,
                reasoningTokens: usage.reasoning
            )
        }
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func blobBytes(_ statement: OpaquePointer, column: Int32) -> [UInt8]? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= maxBlobBytes, let pointer = sqlite3_column_blob(statement, column) else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private static func fileStats(atPath path: String) -> (size: UInt64, modifiedNanoseconds: Int64)? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return (UInt64(max(0, info.st_size)), nanoseconds)
    }

    // MARK: - Protobuf Reader

    private struct ProtoReader {
        private enum InvalidError: Error { case malformed }

        struct ParsedUsage: Equatable {
            var newInput = 0
            var cacheRead = 0
            var output = 0
            var reasoning = 0
            var responseID: String?
            var modelID: Int?
            var botID: String?
            var botIDInvalid = false
        }

        struct ParsedTurn: Equatable {
            var usage: ParsedUsage?
            var timestampMs: Int64?
            var model: String?
            var label: String?
            var stepUUID: String?
        }

        struct StepMetadata: Equatable {
            var stepUUID: String?
            var botID: String?
            var timestampMs: Int64?
        }

        private struct Timestamp {
            var seconds: UInt64?
            var nanos: UInt64 = 0

            func milliseconds() throws -> Int64? {
                guard let seconds else { return nil }
                guard seconds > 0, seconds <= 253_402_300_799, nanos <= 999_999_999,
                      let secondsInt = Int64(exactly: seconds),
                      let nanosInt = Int64(exactly: nanos)
                else { throw InvalidError.malformed }
                return secondsInt * 1_000 + nanosInt / 1_000_000
            }
        }

        private struct Field {
            let number: Int
            let wire: Int
            let data: ArraySlice<UInt8>?
            let value: UInt64?

            func message() throws -> ArraySlice<UInt8> {
                guard wire == 2, let data else { throw InvalidError.malformed }
                return data
            }

            func integer() throws -> UInt64 {
                guard wire == 0, let value else { throw InvalidError.malformed }
                return value
            }

            func counter() throws -> Int {
                guard let count = try Int(exactly: integer()) else { throw InvalidError.malformed }
                return count
            }

            func string() throws -> String? {
                guard let text = try String(bytes: message(), encoding: .utf8) else {
                    throw InvalidError.malformed
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
        }

        private let bytes: ArraySlice<UInt8>
        private var offset: Int
        private var isMalformed = false

        private init(slice: ArraySlice<UInt8>) {
            bytes = slice
            offset = slice.startIndex
        }

        private mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.endIndex else { break }
                let byte = bytes[offset]
                offset += 1
                if index == 9, byte > 1 { break }
                result |= UInt64(byte & 0x7F) << (index * 7)
                if byte & 0x80 == 0 { return result }
            }
            isMalformed = true
            return nil
        }

        private mutating func nextField() -> Field? {
            guard offset < bytes.endIndex else { return nil }
            guard let tag = readVarint(), tag >> 3 > 0, tag >> 3 <= 536_870_911 else {
                isMalformed = true
                return nil
            }
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            if wire == 0 {
                guard let value = readVarint() else { return nil }
                return Field(number: number, wire: wire, data: nil, value: value)
            }
            let count: Int? = switch wire {
            case 1: 8
            case 2: readVarint().flatMap(Int.init(exactly:))
            case 5: 4
            default: nil
            }
            guard let count, count <= bytes.endIndex - offset else {
                isMalformed = true
                return nil
            }
            let end = offset + count
            let slice = bytes[offset..<end]
            offset = end
            return Field(number: number, wire: wire, data: slice, value: nil)
        }

        private static func walk(_ slice: ArraySlice<UInt8>, visit: (Field) throws -> Void) throws {
            var reader = ProtoReader(slice: slice)
            while reader.offset < reader.bytes.endIndex {
                guard let field = reader.nextField() else { break }
                try visit(field)
            }
            guard !reader.isMalformed else { throw InvalidError.malformed }
        }

        static func parseTurn(_ rootBytes: [UInt8]) -> ParsedTurn? {
            var turn = ParsedTurn()
            var time = Timestamp()
            var foundChat = false
            do {
                try walk(rootBytes[...]) { field in
                    switch field.number {
                    case 1:
                        foundChat = true
                        try parseChat(field.message(), turn: &turn, time: &time)
                    case 4:
                        turn.stepUUID = try field.string()
                    default:
                        break
                    }
                }
                guard foundChat else { return nil }
                turn.timestampMs = try time.milliseconds()
                return turn
            } catch {
                return nil
            }
        }

        static func parseStepMetadata(_ rootBytes: [UInt8]) -> StepMetadata? {
            var stepUUID: String?
            var botID: String?
            var botIDInvalid = false
            var time = Timestamp()
            var timestampValid = true
            do {
                try walk(rootBytes[...]) { field in
                    switch field.number {
                    case 1:
                        do {
                            try parseTimestamp(field.message(), time: &time)
                        } catch {
                            timestampValid = false
                        }
                    case 9:
                        do {
                            try walk(field.message()) { subfield in
                                if subfield.number == 7 {
                                    let value = try subfield.string()
                                    if !botIDInvalid { botID = value }
                                }
                            }
                        } catch {
                            botID = nil
                            botIDInvalid = true
                        }
                    case 12:
                        stepUUID = try field.string()
                    default:
                        break
                    }
                }
                let ms = timestampValid ? try time.milliseconds() : nil
                return StepMetadata(stepUUID: stepUUID, botID: botID, timestampMs: ms)
            } catch {
                return nil
            }
        }

        private static func parseChat(
            _ slice: ArraySlice<UInt8>,
            turn: inout ParsedTurn,
            time: inout Timestamp
        ) throws {
            try walk(slice) { field in
                switch field.number {
                case 4:
                    var usage = turn.usage ?? ParsedUsage()
                    try parseUsage(field.message(), usage: &usage)
                    turn.usage = usage
                case 9:
                    try walk(field.message()) { genField in
                        if genField.number == 4 {
                            try parseTimestamp(genField.message(), time: &time)
                        }
                    }
                case 19:
                    turn.model = try field.string()
                case 21:
                    turn.label = try field.string()
                default:
                    break
                }
            }
        }

        private static func parseUsage(
            _ slice: ArraySlice<UInt8>,
            usage: inout ParsedUsage
        ) throws {
            try walk(slice) { field in
                switch field.number {
                case 1: usage.modelID = try field.counter()
                case 2: usage.newInput = try field.counter()
                case 5: usage.cacheRead = try field.counter()
                case 7:
                    do {
                        let value = try field.string()
                        if !usage.botIDInvalid { usage.botID = value }
                    } catch {
                        usage.botID = nil
                        usage.botIDInvalid = true
                    }
                case 9: usage.reasoning = try field.counter()
                case 10: usage.output = try field.counter()
                case 11: usage.responseID = try field.string()
                default: break
                }
            }
        }

        private static func parseTimestamp(
            _ slice: ArraySlice<UInt8>,
            time: inout Timestamp
        ) throws {
            try walk(slice) { field in
                switch field.number {
                case 1:
                    let seconds = try field.integer()
                    guard seconds > 0, seconds <= 253_402_300_799 else { throw InvalidError.malformed }
                    time.seconds = seconds
                case 2:
                    let nanos = try field.integer()
                    guard nanos <= 999_999_999 else { throw InvalidError.malformed }
                    time.nanos = nanos
                default:
                    break
                }
            }
        }
    }
}
