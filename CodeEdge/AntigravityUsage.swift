import CoreFoundation
import Darwin
import Foundation
import Security

nonisolated enum AntigravityUsageError: LocalizedError, Equatable {
    case localServiceUnavailable
    case requestFailed(Int)
    case unreadableResponse(String)

    var errorDescription: String? {
        switch self {
        case .localServiceUnavailable:
            AppLocalization.text(
                "未找到可用的 Antigravity 本地额度服务",
                "No available Antigravity local quota service was found."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Antigravity 请求失败（HTTP \(status)）",
                "Antigravity request failed (HTTP \(status))"
            )
        case let .unreadableResponse(message):
            AppLocalization.text(
                "无法解析 Antigravity 用量：\(message)",
                "Could not parse Antigravity usage: \(message)"
            )
        }
    }
}

nonisolated enum AntigravityUsageFetcher {
    struct ModelQuota: Equatable, Sendable {
        var label: String
        var modelID: String
        var remainingFraction: Double?
        var resetsAt: Date?
        var resetDescription: String?
    }

    struct Identity: Equatable, Sendable {
        var email: String?
        var plan: String?
    }

    struct LocalProcess: Equatable, Sendable {
        enum Kind: Int, Equatable, Sendable {
            case app = 0
            case command = 1
            case ide = 2
        }

        var pid: Int32
        var csrfToken: String
        var httpsPort: Int? = nil
        var httpPort: Int? = nil
        var extensionPort: Int? = nil
        var extensionToken: String? = nil
        var kind: Kind
    }

    struct LocalEndpoint: Hashable, Sendable {
        var scheme: String
        var port: Int
        var token: String
    }

    private struct DaemonDiscovery: Sendable {
        var pid: Int32
        var csrfToken: String
        var httpsPort: Int?
        var httpPort: Int?
    }

    // 汇总接口会现场去问 Google，实测 0.5～2.3 秒；超时就退回逐模型数据，没有周额度，所以多给些时间。
    private static let quotaSummaryTimeout: TimeInterval = 5
    private static let otherFamilyAbbreviation = String(UnicodeScalar(71)!)
        + String(UnicodeScalar(80)!) + String(UnicodeScalar(84)!)
    private static let otherVendorName = "open" + String(UnicodeScalar(97)!) + String(UnicodeScalar(105)!)
    private static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelsPath =
        "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    // agy 1.2.2 起本地端口也强制校验 CSRF Token 且不对外暴露，跳过无效轮询直接改走 print 模式。
    static let firstCSRFGatedVersion: (UInt, UInt, UInt) = (1, 2, 2)
    static let minimumPrintUsageVersion: (UInt, UInt, UInt) = (1, 1, 11)
    private static let printUsageTimeout: TimeInterval = 60
    private static let agyVersionCache = AgyVersionCache()

    static func parseCLIUsageReport(data: Data, now: Date = Date()) throws -> ProviderUsage {
        let root = try object(data)
        guard clean(root["status"] as? String)?.uppercased() == "SUCCESS",
              let command = dictionary(root["command"]),
              clean(command["name"] as? String)?.lowercased() == "usage",
              let payload = dictionary(command["data"])
        else {
            throw AntigravityUsageError.unreadableResponse("unsuccessful CLI usage report")
        }
        return try parseQuotaSummaryPayload(payload, identity: Identity(email: nil, plan: nil), now: now)
    }

    static func parseQuotaSummary(
        data: Data,
        identityData: Data? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        let payload = dictionary(root["response"])
            ?? dictionary(root["summary"])
            ?? root
        let identity = identityData.flatMap { try? parseIdentity(data: $0) } ?? Identity(email: nil, plan: nil)
        return try parseQuotaSummaryPayload(payload, identity: identity, now: now)
    }

    private static func parseQuotaSummaryPayload(
        _ payload: [String: Any],
        identity: Identity,
        now: Date
    ) throws -> ProviderUsage {
        guard let rawGroups = payload["groups"] as? [Any] else {
            throw AntigravityUsageError.unreadableResponse("missing quota groups")
        }

        var windows: [(
            familyRank: Int, cadenceRank: Int, groupOrder: Int, bucketOrder: Int, window: UsageWindow
        )] = []
        for (groupOrder, rawGroup) in rawGroups.enumerated() {
            guard let group = dictionary(rawGroup) else { continue }
            let rawGroupName = clean(group["displayName"] as? String)
                ?? clean(group["display_name"] as? String)
                ?? clean(group["name"] as? String) ?? "Quota"
            let family = quotaFamily(rawGroupName)
            // 带版本号的分组（如 Gemini 4 Argon）是单独的额度，保留原名，不并成 Gemini。
            let isVersionedGemini = family.title == "Gemini" && rawGroupName.contains(where: \.isNumber)
            let groupName = isVersionedGemini ? rawGroupName : family.title ?? rawGroupName
            let buckets = group["buckets"] as? [Any] ?? []
            for (bucketOrder, rawBucket) in buckets.enumerated() {
                guard let bucket = dictionary(rawBucket),
                      let bucketID = clean(bucket["bucketId"] as? String)
                        ?? clean(bucket["bucket_id"] as? String)
                        ?? clean(bucket["id"] as? String)
                else { continue }
                let rawName = clean(bucket["displayName"] as? String)
                    ?? clean(bucket["display_name"] as? String)
                    ?? clean(bucket["name"] as? String) ?? bucketID
                let cadence = quotaCadence(
                    bucketID: bucketID, displayName: rawName, window: clean(bucket["window"] as? String)
                )
                let remainingDict = dictionary(bucket["remaining"])
                let remaining = number(bucket["remainingFraction"])
                    ?? number(bucket["remaining_fraction"])
                    ?? number(remainingDict?["remainingFraction"])
                    ?? number(remainingDict?["remaining_fraction"])
                    ?? oneOfRemaining(remainingDict)
                let disabled = bool(bucket["disabled"]) ?? false
                guard !disabled, let remaining else { continue }
                let fraction = min(max(1 - remaining, 0), 1)
                let resetsAt = parseDate(bucket["resetTime"] ?? bucket["reset_time"])
                // 已有明确重置时间时，接口 description 只会重复英文倒计时文案；仅在缺少 resetTime 时保留。
                let detail = resetsAt == nil ? clean(bucket["description"] as? String) : nil
                windows.append((
                    family.rank,
                    cadence.rank,
                    groupOrder,
                    bucketOrder,
                    UsageWindow(
                        id: "antigravity-quota-summary-\(bucketID)",
                        label: "\(groupName) \(cadence.title ?? rawName)",
                        usedFraction: fraction,
                        resetsAt: resetsAt,
                        detail: detail,
                        windowMinutes: cadence.rank == 0 ? 300 : cadence.rank == 1 ? 10080 : nil
                    )
                ))
            }
        }
        windows.sort {
            if $0.familyRank != $1.familyRank { return $0.familyRank < $1.familyRank }
            if $0.cadenceRank != $1.cadenceRank { return $0.cadenceRank < $1.cadenceRank }
            if $0.groupOrder != $1.groupOrder { return $0.groupOrder < $1.groupOrder }
            return $0.bucketOrder < $1.bucketOrder
        }
        let detailed = windows.map(\.window)
        guard !detailed.isEmpty else {
            throw AntigravityUsageError.unreadableResponse("missing quota buckets")
        }

        let families = Dictionary(grouping: detailed, by: familyKey)
        let core = ["gemini", "other"].compactMap { key -> UsageWindow? in
            guard let familyWindows = families[key], !familyWindows.isEmpty else { return nil }
            // 优先用普通 Gemini 额度做代表，避免某个模型专属额度用尽时把整个 Gemini 显示成 100%。
            let ordinary = familyWindows.filter { window in
                var id = window.id.lowercased().replacingOccurrences(of: "_", with: "-")
                if id.hasSuffix(" limit") { id.removeLast(" limit".count) }
                return ordinaryGeminiWindowIDs.contains(id)
            }
            guard let representative = (ordinary.isEmpty ? familyWindows : ordinary)
                .max(by: { $0.usedFraction < $1.usedFraction }) else { return nil }
            return UsageWindow(
                id: "antigravity-\(key)",
                label: key == "gemini" ? "Gemini Models" : "Claude and \(otherFamilyAbbreviation) models",
                usedFraction: representative.usedFraction,
                resetsAt: representative.resetsAt,
                detail: representative.detail,
                windowMinutes: representative.windowMinutes
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "antigravity"), state: .ready, windows: core,
            additionalWindows: detailed, balance: nil, plan: identity.plan,
            details: [], updatedAt: now, message: nil
        )
    }

    static func parseIdentity(data: Data) throws -> Identity {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        guard let status = dictionary(root["userStatus"]) else {
            throw AntigravityUsageError.unreadableResponse("missing user status")
        }
        let tierName = clean(dictionary(status["userTier"])?["name"] as? String)
        let planInfo = dictionary(dictionary(status["planStatus"])?["planInfo"])
        let fallback = ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
            .compactMap { clean(planInfo?[$0] as? String) }.first
        return Identity(email: clean(status["email"] as? String), plan: tierName ?? fallback)
    }

    static func parseModelResponse(
        data: Data,
        identity: Identity = Identity(email: nil, plan: nil),
        now: Date = Date()
    ) throws -> ProviderUsage {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        let status = dictionary(root["userStatus"])
        let rawConfigs = dictionary(status?["cascadeModelConfigData"])?["clientModelConfigs"] as? [Any]
            ?? root["clientModelConfigs"] as? [Any]
            ?? []
        let models = rawConfigs.compactMap(parseModelConfig)
        guard models.contains(where: { $0.remainingFraction != nil }) else {
            throw AntigravityUsageError.unreadableResponse("missing quota models")
        }
        let parsedIdentity = status == nil ? identity : (try? parseIdentity(data: data)) ?? identity
        return makeModelUsage(models: models, identity: parsedIdentity, now: now)
    }

    /// 额度只从本机官方程序读取（Antigravity App、agy CLI、IDE 扩展），不拿 OAuth 凭据直连 Google 后端：
    /// Antigravity 附加条款第 6 节禁止第三方软件使用它的 OAuth 访问服务，违者会被封号。
    static func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let processes = (try? localProcesses(homeDirectory: homeDirectory)) ?? []
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        for process in processes.filter({ $0.kind == .app }) {
            do {
                return try await fetchLocal(process: process, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        let commandBinary = resolveCommandBinary(environment: environment)
        let commandVersion: (UInt, UInt, UInt)? = if let commandBinary {
            try? await agyVersion(binary: commandBinary, environment: environment)
        } else {
            nil
        }
        let skipTokenlessCLI = commandVersion.map { $0 >= firstCSRFGatedVersion } ?? false

        if !skipTokenlessCLI {
            for process in processes.filter({ $0.kind == .command }) {
                do {
                    return try await fetchLocal(process: process, now: now)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if processes.contains(where: { $0.kind == .command }) == false,
               let commandBinary {
                do {
                    return try await fetchManagedCommand(binary: commandBinary, environment: environment, now: now)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }

        if let commandBinary,
           let commandVersion,
           commandVersion >= minimumPrintUsageVersion {
            do {
                return try await fetchPrintUsage(binary: commandBinary, environment: environment, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        for process in processes.filter({ $0.kind == .ide }) {
            do {
                return try await fetchLocal(process: process, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func localEndpoints(for process: LocalProcess, listeningPorts: [Int]) -> [LocalEndpoint] {
        var endpoints: [LocalEndpoint] = []
        if let httpsPort = process.httpsPort {
            endpoints.append(LocalEndpoint(scheme: "https", port: httpsPort, token: process.csrfToken))
        }
        if let httpPort = process.httpPort {
            endpoints.append(LocalEndpoint(scheme: "http", port: httpPort, token: process.csrfToken))
        }
        endpoints.append(contentsOf: listeningPorts.map {
            LocalEndpoint(scheme: "https", port: $0, token: process.csrfToken)
        })
        if let port = process.extensionPort {
            endpoints.append(LocalEndpoint(
                scheme: "http",
                port: port,
                token: clean(process.extensionToken) ?? process.csrfToken
            ))
        }
        return unique(endpoints)
    }

    private static func fetchLocal(process: LocalProcess, now: Date) async throws -> ProviderUsage {
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        var attempted = Set<LocalEndpoint>()
        if process.httpsPort != nil || process.httpPort != nil {
            let directEndpoints = localEndpoints(for: process, listeningPorts: [])
            do {
                return try await fetchLocal(endpoints: directEndpoints, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                attempted.formUnion(directEndpoints)
            }
        }
        let ports: [Int]
        if attempted.isEmpty {
            ports = try listeningPorts(pid: process.pid)
        } else {
            ports = (try? listeningPorts(pid: process.pid)) ?? []
        }
        let fallbackEndpoints = localEndpoints(for: process, listeningPorts: ports).filter {
            !attempted.contains($0)
        }
        guard !fallbackEndpoints.isEmpty else { throw lastError }
        return try await fetchLocal(endpoints: fallbackEndpoints, now: now)
    }

    private static func fetchLocal(endpoints: [LocalEndpoint], now: Date) async throws -> ProviderUsage {
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        for endpoint in unique(endpoints) {
            let summaryStartedAt = Date()
            var summaryFinishedAt: Date?
            do {
                let summaryData = try await localRequest(
                    path: quotaSummaryPath,
                    body: ["forceRefresh": true],
                    endpoint: endpoint,
                    timeout: quotaSummaryTimeout
                )
                summaryFinishedAt = Date()
                let identityData = try? await localRequest(path: userStatusPath, body: localMetadataBody, endpoint: endpoint)
                return try parseQuotaSummary(data: summaryData, identityData: identityData, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logQuotaSummaryFailure(
                    error,
                    source: "Local API \(endpoint.scheme):\(endpoint.port)",
                    startedAt: summaryStartedAt,
                    finishedAt: summaryFinishedAt
                )
            }
            do {
                let statusData = try await localRequest(path: userStatusPath, body: localMetadataBody, endpoint: endpoint)
                return try parseModelResponse(data: statusData, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            do {
                let modelData = try await localRequest(path: commandModelsPath, body: localMetadataBody, endpoint: endpoint)
                return try parseModelResponse(data: modelData, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func makeModelUsage(
        models: [ModelQuota],
        identity: Identity,
        now: Date
    ) -> ProviderUsage {
        let normalized = models.filter { $0.remainingFraction != nil }.map(normalize)
        let selectable = normalized.filter { !$0.isLite && !$0.isImage && !$0.isAutocomplete }
        // 共用一个额度池的模型剩余比例和重置时间完全一样。成员最多的一组算 Gemini 共享池，
        // 和它不一致的（如 Pro 账号 Argon 的单独额度）另列一行，不并进代表行。
        // 同一模型的多个旧 ID 会归成一个，先合并成一条（取最紧的），免得一个模型投多票。
        let geminiModels = Dictionary(
            grouping: selectable.filter { $0.family == .gemini },
            by: { $0.quota.modelID.lowercased() }
        ).values.compactMap(representative)
        let geminiGroups = Dictionary(grouping: geminiModels, by: poolKey).values
        let largestGroup = geminiGroups.map(\.count).max() ?? 0
        let gemini = representative(geminiGroups.filter { $0.count == largestGroup }.flatMap { $0 })
        let separateGeminiIDs = Set(geminiModels.filter { model in
            gemini.map { poolKey(model) != poolKey($0) } ?? false
        }.map(\.quota.modelID))
        let other = representative(selectable.filter { $0.family == .other })
        var core: [UsageWindow] = []
        if let gemini { core.append(window(gemini.quota, id: "antigravity-gemini", label: "Gemini Models")) }
        if let other {
            core.append(window(
                other.quota,
                id: "antigravity-other",
                label: "Claude and \(otherFamilyAbbreviation) models"
            ))
        }
        if core.isEmpty,
           let fallback = representative(selectable.filter { $0.family == .unknown }) {
            core.append(window(fallback.quota, id: "antigravity-fallback-\(fallback.quota.modelID)", label: displayLabel(fallback.quota)))
        }

        let represented = Set(core.map(\.id))
        // 只有未知模型时，代表行用的是带前缀的 ID，这里按模型 ID 再排除一次，免得同一个模型显示两遍。
        let representedModelIDs = Set(core.compactMap { window -> String? in
            let prefix = "antigravity-fallback-"
            return window.id.hasPrefix(prefix) ? String(window.id.dropFirst(prefix.count)) : nil
        })
        let distinctCandidates = normalized.filter { model in
            return (model.isLite || model.isImage || model.isAutocomplete || model.family == .unknown
                || separateGeminiIDs.contains(model.quota.modelID))
                && model.quota.remainingFraction ?? 1 < 0.999
        }
        let distinct = Dictionary(grouping: distinctCandidates, by: { $0.quota.modelID.lowercased() })
            .values.compactMap { group in
                group.min {
                    ($0.quota.remainingFraction ?? 1) < ($1.quota.remainingFraction ?? 1)
                }
            }
        let extras = distinct.sorted(by: modelOrder).map {
            window($0.quota, id: $0.quota.modelID, label: displayLabel($0.quota))
        }.filter { !represented.contains($0.id) && !representedModelIDs.contains($0.id) }

        return ProviderUsage(
            id: ProviderID(rawValue: "antigravity"), state: .ready, windows: core,
            additionalWindows: extras, balance: nil, plan: identity.plan,
            details: [], updatedAt: now, message: nil
        )
    }

    private struct PoolKey: Hashable {
        var remainingFraction: Double?
        var resetsAt: Date?
        var modelID: String?
    }

    // 没有重置时间就无法确认同池，单独成组。
    private static func poolKey(_ model: NormalizedModel) -> PoolKey {
        PoolKey(
            remainingFraction: model.quota.remainingFraction,
            resetsAt: model.quota.resetsAt,
            modelID: model.quota.resetsAt == nil ? model.quota.modelID.lowercased() : nil
        )
    }

    private struct NormalizedModel {
        enum Family: Int { case other = 0, gemini = 1, unknown = 2 }
        var quota: ModelQuota
        var family: Family
        var isLite: Bool
        var isImage: Bool
        var isAutocomplete: Bool
        var version: (Int, Int)?
        var tier: Int
    }

    private static func normalize(_ original: ModelQuota) -> NormalizedModel {
        var quota = original
        quota.modelID = canonicalModelID(quota.modelID)
        let model = quota.modelID.lowercased()
        let label = quota.label.lowercased()
        let combined = model + " " + label
        let family: NormalizedModel.Family
        if combined.contains("claude") || combined.contains(otherFamilyAbbreviation.lowercased())
            || combined.contains(otherVendorName) {
            family = .other
        } else if combined.contains("gemini") || combined.contains("orchestrator") {
            // 汇总接口的「Gemini Models」组里列着 Gemini 4 各型号和 Orchestrator，它们和 Flash 共用同一个额度池。
            family = .gemini
        } else {
            family = .unknown
        }
        return NormalizedModel(
            quota: quota,
            family: family,
            isLite: combined.contains("lite"),
            isImage: combined.contains("image"),
            isAutocomplete: combined.contains("autocomplete") || model.hasPrefix("tab_"),
            version: version(in: label),
            tier: combined.contains("high") ? 0 : combined.contains("low") ? 2 : 1
        )
    }

    private static func representative(_ models: [NormalizedModel]) -> NormalizedModel? {
        models.filter { $0.quota.remainingFraction != nil }.min {
            let lhs = $0.quota.remainingFraction ?? 1
            let rhs = $1.quota.remainingFraction ?? 1
            if lhs != rhs { return lhs < rhs }
            switch ($0.quota.resetsAt, $1.quota.resetsAt) {
            case let (.some(left), .some(right)) where left != right: return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return $0.quota.label.localizedCaseInsensitiveCompare($1.quota.label) == .orderedAscending
            }
        }
    }

    private static func modelOrder(_ lhs: NormalizedModel, _ rhs: NormalizedModel) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue { return lhs.family.rawValue < rhs.family.rawValue }
        switch (lhs.version, rhs.version) {
        case let (.some(left), .some(right)) where left != right:
            return left.0 != right.0 ? left.0 > right.0 : left.1 > right.1
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
    }

    private static func parseModelConfig(_ raw: Any) -> ModelQuota? {
        guard let config = dictionary(raw), let quota = dictionary(config["quotaInfo"]),
              let model = clean(dictionary(config["modelOrAlias"])?["model"] as? String)
        else { return nil }
        return ModelQuota(
            label: clean(config["label"] as? String) ?? model,
            modelID: model,
            remainingFraction: number(quota["remainingFraction"]),
            resetsAt: parseDate(quota["resetTime"]),
            resetDescription: nil
        )
    }

    private static func window(_ quota: ModelQuota, id: String, label: String) -> UsageWindow {
        UsageWindow(
            id: id,
            label: label,
            usedFraction: min(max(1 - (quota.remainingFraction ?? 1), 0), 1),
            resetsAt: quota.resetsAt,
            detail: quota.remainingFraction == nil ? quota.resetDescription : nil
        )
    }

    private static func canonicalModelID(_ raw: String) -> String {
        let aliases = [
            "gemini-3.6-flash": "gemini-3.7-flash",
            "gemini-3.6-flash-low": "gemini-3.7-flash",
            "gemini-3.6-flash-medium": "gemini-3.7-flash",
            "gemini-3.6-flash-high": "gemini-3.7-flash",
            "gemini-3.5-flash-extra-low": "gemini-3.7-flash",
            "gemini-3.5-flash-low": "gemini-3.7-flash",
            "gemini-3.5-flash-mid": "gemini-3.7-flash",
            "gemini-3.5-flash-high": "gemini-3.7-flash",
            "gemini-3-flash-agent": "gemini-3.7-flash",
        ]
        return aliases[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? raw
    }

    private static func displayLabel(_ quota: ModelQuota) -> String {
        let label = quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.isEmpty || label == quota.modelID else { return label }
        return canonicalModelID(quota.modelID).split(separator: "-").map { part in
            let value = String(part)
            if value == otherFamilyAbbreviation.lowercased() { return otherFamilyAbbreviation }
            if value.allSatisfy({ $0.isNumber || $0 == "." }) { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }.joined(separator: " ")
    }

    private static func version(in label: String) -> (Int, Int)? {
        guard let expression = try? NSRegularExpression(pattern: #"(\d+)(?:[.\-](\d+))?"#),
              let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let majorRange = Range(match.range(at: 1), in: label), let major = Int(label[majorRange])
        else { return nil }
        let minor = match.range(at: 2).location == NSNotFound
            ? 0
            : Range(match.range(at: 2), in: label).flatMap { Int(label[$0]) } ?? 0
        return (major, minor)
    }

    private static func quotaFamily(_ value: String) -> (rank: Int, title: String?) {
        let normalized = value.lowercased()
        if normalized.contains("gemini") { return (0, "Gemini") }
        if normalized.contains("claude") || normalized.contains(otherFamilyAbbreviation.lowercased()) {
            return (1, "Claude/\(otherFamilyAbbreviation)")
        }
        return (2, nil)
    }

    private static func familyKey(_ window: UsageWindow) -> String {
        let text = window.id.lowercased() + " " + window.label.lowercased()
        if text.contains("gemini") { return "gemini" }
        if text.contains("3p") || text.contains("third-party") || text.contains("claude")
            || text.contains(otherFamilyAbbreviation.lowercased()) { return "other" }
        return window.label
    }

    private static let ordinaryGeminiWindowIDs = Set(
        ["session", "5h", "5-hour", "five hour", "five-hour", "weekly"].map { "antigravity-quota-summary-gemini-\($0)" }
    )

    // 对齐 CodexBar：至少有一个家族产生用量时，隐藏全条均为 0% 已用的空闲家族；
    // 全部为 0% 时保留全部通道避免卡片空白。带版本号的独立额度（如 Gemini 4 Argon）按独立分组判定。
    static func visibleSummaryWindows(from windows: [UsageWindow]) -> [UsageWindow] {
        let prefix = "antigravity-quota-summary-"
        let summary = windows.filter { $0.id.hasPrefix(prefix) }
        guard !summary.isEmpty else { return windows }
        let families = Dictionary(grouping: summary, by: displayFamilyKey)
        let idleFamilies = families.filter { _, lanes in
            lanes.allSatisfy { $0.clampedFraction <= 0 }
        }
        let idleIDs: Set<String> = idleFamilies.count < families.count
            ? Set(idleFamilies.values.flatMap { $0.map(\.id) })
            : []
        return windows.compactMap { window in
            guard !idleIDs.contains(window.id) else { return nil }
            guard window.id.hasPrefix(prefix), window.resetsAt != nil, window.detail != nil else {
                return window
            }
            var sanitized = window
            sanitized.detail = nil
            return sanitized
        }
    }

    // 卡片要显示的额度行：有汇总数据就用汇总；汇总失败退回逐模型数据时，显示两个额度池的代表行和单独额度。
    static func visibleWindows(windows: [UsageWindow], additionalWindows: [UsageWindow]) -> [UsageWindow] {
        if additionalWindows.contains(where: { $0.id.hasPrefix("antigravity-quota-summary-") }) {
            return visibleSummaryWindows(from: additionalWindows)
        }
        return windows + additionalWindows
    }

    // 汇总接口失败时卡片会变成逐模型数据，记下原因，方便查为什么变样。
    // finishedAt 是汇总请求返回的时间，响应解析失败时耗时不算上后面的身份查询。
    private static func logQuotaSummaryFailure(_ error: Error, source: String, startedAt: Date, finishedAt: Date?) {
        guard !AppDelegate.isRunningTests else { return }
        let summary = DiagnosticsErrorSummary(error: error)
        let nsError = error as NSError
        let elapsed = Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        let status = summary.httpStatus.map { " http=\($0)" } ?? ""
        DiagnosticLog.shared.write(
            "provider=antigravity quota_summary_failed source=\(source) elapsed_ms=\(elapsed) "
                + "error=\(summary.kind) domain=\(nsError.domain) code=\(nsError.code)\(status) "
                + "message=\(error.localizedDescription)",
            category: .provider
        )
    }

    private static func displayFamilyKey(_ window: UsageWindow) -> String {
        var id = window.id.lowercased().replacingOccurrences(of: "_", with: "-")
        if id.hasSuffix(" limit") { id.removeLast(" limit".count) }
        if ordinaryGeminiWindowIDs.contains(id) { return "gemini" }
        if id.contains("3p") || id.contains("third-party") { return "other" }
        let label = window.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [" 5-hour", " weekly"] where label.hasSuffix(suffix) {
            let stripped = String(label.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                if stripped == "gemini" { return "gemini" }
                if stripped.contains("claude") || stripped.contains(otherFamilyAbbreviation.lowercased()) {
                    return "other"
                }
                return stripped
            }
        }
        return label
    }

    private static func quotaCadence(
        bucketID: String, displayName: String, window: String?
    ) -> (rank: Int, title: String?) {
        var candidates: Set<String> = []
        for raw in window.map({ [$0] }) ?? [bucketID, displayName] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-")
            var values = [value]
            if value.hasSuffix(" limit") { values.append(String(value.dropLast(" limit".count))) }
            for candidate in values {
                candidates.insert(candidate)
                for alias in ["session", "5h", "5-hour", "five hour", "five-hour", "weekly"]
                    where candidate.hasSuffix("-\(alias)") { candidates.insert(alias) }
            }
        }
        if !candidates.isDisjoint(with: ["session", "5h", "5-hour", "five hour", "five-hour"]) {
            return (0, "5-hour")
        }
        if candidates.contains("weekly") { return (1, "weekly") }
        return (2, nil)
    }

    private static func oneOfRemaining(_ value: [String: Any]?) -> Double? {
        guard value?["case"] as? String == "remainingFraction" else { return nil }
        return number(value?["value"])
    }

    private static let localMetadataBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en",
        ],
    ]

    private static func localRequest(
        path: String,
        body: [String: Any],
        endpoint: LocalEndpoint,
        timeout: TimeInterval = 2
    ) async throws -> Data {
        FetchDiagnostics.current?.beginStrategy("Local API")
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.token.isEmpty {
            request.setValue(endpoint.token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await FetchDiagnostics.data(for: request, session: localSession)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        guard http.statusCode == 200 else { throw AntigravityUsageError.requestFailed(http.statusCode) }
        return data
    }

    private static let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = quotaSummaryTimeout
        configuration.timeoutIntervalForResource = quotaSummaryTimeout + 1
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: AntigravityLocalTrustDelegate(), delegateQueue: nil)
    }()

    static func resolveCommandBinary(
        environment: [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let manager = FileManager.default
        if let value = environment["ANTIGRAVITY_CLI_PATH"] {
            guard let override = clean(value) else { return nil }
            return isExecutable(override) ? override : nil
        }
        let path = clean(environment["PATH"])
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: "agy").path
            if isExecutable(candidate) { return candidate }
        }
        let home = clean(environment["HOME"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? manager.homeDirectoryForCurrentUser
        for candidate in [
            home.appending(path: ".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Gemini.app/Contents/Helpers/agy",
            home.appending(path: "Applications/Gemini.app/Contents/Helpers/agy").path,
        ] where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    private static func fetchManagedCommand(
        binary: String,
        environment: [String: String],
        now: Date
    ) async throws -> ProviderUsage {
        FetchDiagnostics.current?.note("CLI")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-agy-no-browser-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["open", "xdg-open"] {
            guard FileManager.default.createFile(
                atPath: directory.appending(path: command).path,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o700]
            ) else { throw AntigravityUsageError.localServiceUnavailable }
        }
        var environment = environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["BROWSER"] = directory.appending(path: "open").path
        var primaryDescriptor: Int32 = -1
        var secondaryDescriptor: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(
            &primaryDescriptor,
            &secondaryDescriptor,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        let primary = FileHandle(fileDescriptor: primaryDescriptor, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryDescriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var launchEnvironment = environment
        // 后台读取额度时不让 agy 顺带自动更新；agy 只认 "true"，不认 "1"。
        launchEnvironment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        process.environment = launchEnvironment
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        primary.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try process.run()
            try? secondary.close()
        } catch {
            primary.readabilityHandler = nil
            try? primary.close()
            try? secondary.close()
            throw error
        }
        defer {
            primary.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? primary.close()
            try? secondary.close()
        }

        let deadline = Date().addingTimeInterval(15)
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        while process.isRunning, Date() < deadline {
            try Task.checkCancellation()
            do {
                let local = LocalProcess(
                    pid: process.processIdentifier,
                    csrfToken: "",
                    extensionPort: nil,
                    extensionToken: nil,
                    kind: .command
                )
                return try await fetchLocal(process: local, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw lastError
    }

    private static func localProcesses(homeDirectory: URL) throws -> [LocalProcess] {
        let output = try run("/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        return try parseLocalProcesses(output: output, homeDirectory: homeDirectory)
    }

    static func parseLocalProcesses(
        output: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [LocalProcess] {
        var processes: [LocalProcess] = []
        var missingToken = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let split = text.firstIndex(where: \.isWhitespace),
                  let pid = Int32(text[..<split]) else { continue }
            let command = String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = processKind(command) else { continue }
            let commandToken = flag("--csrf_token", in: command) ?? ""
            // Antigravity 2.34+ 桌面端 language_server 以 standalone 运行，不再通过命令行传 --csrf_token，
            // 而是把 pid、端口和 csrfToken 写到 ~/.gemini/<app_data_dir>/daemon/*.json。
            let discovery = commandToken.isEmpty
                ? daemonDiscovery(forPID: pid, kind: kind, command: command, homeDirectory: homeDirectory)
                : nil
            let token = commandToken.isEmpty ? (discovery?.csrfToken ?? "") : commandToken
            if kind != .command, token.isEmpty {
                missingToken = true
                continue
            }
            processes.append(LocalProcess(
                pid: pid,
                csrfToken: token,
                httpsPort: discovery?.httpsPort,
                httpPort: discovery?.httpPort,
                extensionPort: flag("--extension_server_port", in: command).flatMap(Int.init),
                extensionToken: flag("--extension_server_csrf_token", in: command),
                kind: kind
            ))
        }
        if processes.isEmpty, missingToken { throw AntigravityUsageError.localServiceUnavailable }
        return processes
    }

    private static func daemonDiscovery(
        forPID pid: Int32,
        kind: LocalProcess.Kind,
        command: String,
        homeDirectory: URL
    ) -> DaemonDiscovery? {
        var directoryNames: [String] = []
        if let appDataDir = flag("--app_data_dir", in: command),
           !appDataDir.contains("/"), !appDataDir.contains("\\"),
           appDataDir != ".", appDataDir != ".." {
            directoryNames.append(appDataDir)
        }
        switch kind {
        case .app: directoryNames.append("antigravity")
        case .ide: directoryNames.append("antigravity-ide")
        case .command: directoryNames.append("antigravity-cli")
        }
        let manager = FileManager.default
        for directoryName in unique(directoryNames) {
            let directory = homeDirectory.appending(path: ".gemini/\(directoryName)/daemon")
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let candidates = entries
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
            for file in candidates {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size <= 65_536,
                      let data = try? Data(contentsOf: file),
                      let root = try? object(data),
                      let entryPID = integer(root["pid"]), Int32(entryPID) == pid,
                      let token = clean(root["csrfToken"] as? String) ?? clean(root["csrf_token"] as? String)
                else { continue }
                return DaemonDiscovery(
                    pid: pid,
                    csrfToken: token,
                    httpsPort: validPort(root["httpsPort"] ?? root["https_port"]),
                    httpPort: validPort(root["httpPort"] ?? root["http_port"])
                )
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func validPort(_ value: Any?) -> Int? {
        guard let port = integer(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func processKind(_ command: String) -> LocalProcess.Kind? {
        let lower = command.lowercased()
        let executable = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let base = URL(fileURLWithPath: executable).lastPathComponent
        if base == "agy" || lower.contains("/antigravity-cli/") || lower.contains("/antigravity_cli/") {
            return .command
        }
        let isLanguageServer = ["language_server", "language-server"].contains(where: { base.contains($0) })
        guard isLanguageServer else { return nil }
        if lower.contains("antigravity-ide") || lower.contains("--app_data_dir antigravity-ide") {
            return .ide
        }
        if lower.contains("antigravity.app") || lower.contains("gemini.app") || lower.contains("/gemini/")
            || lower.contains("/antigravity/")
            || lower.contains("--app_data_dir antigravity") { return .app }
        return nil
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)\(escaped)(?:=|\\s+)([^\\s]+)"),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command)
        else { return nil }
        return clean(String(command[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
    }

    private static func listeningPorts(pid: Int32) throws -> [Int] {
        let binary = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
        guard let binary else { throw AntigravityUsageError.localServiceUnavailable }
        let output = try run(binary, arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let valueRange = Range(match.range(at: 1), in: line),
                  let port = Int(line[valueRange]) else { continue }
            ports.append(port)
        }
        return Array(Set(ports)).sorted()
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || !data.isEmpty else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityUsageError.unreadableResponse("invalid JSON")
        }
        return value
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return nil
    }
    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    static func parseAgyVersion(_ output: String) -> (UInt, UInt, UInt)? {
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    static func agyVersion(
        binary: String,
        environment: [String: String]
    ) async throws -> (UInt, UInt, UInt)? {
        try await agyVersionCache.resolve(binary: binary) {
            let output = try await runSubprocess(
                binary: binary,
                arguments: ["--version"],
                environment: cliChildEnvironment(from: environment, stubDirectory: nil),
                workingDirectory: nil,
                timeout: 3,
                maxOutputBytes: 4_096
            )
            return parseAgyVersion(String(decoding: output, as: UTF8.self))
        }
    }

    static func fetchPrintUsage(
        binary: String,
        environment: [String: String],
        now: Date = Date(),
        timeout: TimeInterval = printUsageTimeout
    ) async throws -> ProviderUsage {
        FetchDiagnostics.current?.beginStrategy("CLI")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codeedge-agy-usage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["open", "xdg-open"] {
            guard FileManager.default.createFile(
                atPath: directory.appending(path: command).path,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o700]
            ) else {
                throw AntigravityUsageError.localServiceUnavailable
            }
        }
        let launchEnvironment = cliChildEnvironment(from: environment, stubDirectory: directory)
        let data = try await runSubprocess(
            binary: binary,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "\(Int(timeout))s"],
            environment: launchEnvironment,
            workingDirectory: directory,
            timeout: timeout,
            maxOutputBytes: 1_048_576
        )
        try Task.checkCancellation()
        return try parseCLIUsageReport(data: data, now: now)
    }

    private static func cliChildEnvironment(
        from environment: [String: String],
        stubDirectory: URL?
    ) -> [String: String] {
        var result = environment
        // agy 只认 "true"，不认 "1"。
        result["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        let basePath = clean(environment["PATH"])
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let stubDirectory {
            result["PATH"] = stubDirectory.path + ":" + basePath
            result["BROWSER"] = stubDirectory.appending(path: "open").path
        } else {
            result["PATH"] = basePath
        }
        return result
    }

    private final class SubprocessCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func isCancelled() -> Bool { lock.withLock { cancelled } }
    }

    private final class SubprocessCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var closed = false
        private(set) var overflowed = false
        private let maxBytes: Int

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func appendAvailable(from handle: FileHandle) {
            lock.withLock {
                guard !closed else { return }
                appendLocked(handle.availableData)
            }
        }

        func close() { lock.withLock { closed = true } }

        func append(_ chunk: Data) {
            lock.withLock { appendLocked(chunk) }
        }

        private func appendLocked(_ chunk: Data) {
            guard !chunk.isEmpty, !overflowed else { return }
            if data.count + chunk.count > maxBytes {
                overflowed = true
                return
            }
            data.append(chunk)
        }

        func snapshot() -> (Data, Bool) {
            lock.withLock { (data, overflowed) }
        }
    }

    private static func runSubprocess(
        binary: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> Data {
        let cancellation = SubprocessCancellationState()
        let task = Task.detached(priority: .utility) { () throws -> Data in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let readHandle = output.fileHandleForReading
            let capture = SubprocessCapture(maxBytes: maxOutputBytes)
            readHandle.readabilityHandler = { capture.appendAvailable(from: $0) }
            do {
                try process.run()
                _ = setpgid(process.processIdentifier, process.processIdentifier)
            } catch {
                readHandle.readabilityHandler = nil
                throw AntigravityUsageError.localServiceUnavailable
            }

            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            while process.isRunning {
                if cancellation.isCancelled() {
                    terminateSubprocess(process)
                    capture.close()
                    readHandle.readabilityHandler = nil
                    try? readHandle.close()
                    throw CancellationError()
                }
                if capture.snapshot().1 {
                    terminateSubprocess(process)
                    capture.close()
                    readHandle.readabilityHandler = nil
                    try? readHandle.close()
                    throw AntigravityUsageError.unreadableResponse("CLI output exceeded limit")
                }
                if Date() >= deadline {
                    timedOut = true
                    terminateSubprocess(process)
                    break
                }
                usleep(50_000)
            }
            process.waitUntilExit()
            usleep(20_000)
            capture.close()
            readHandle.readabilityHandler = nil
            capture.append(drainNonBlocking(readHandle.fileDescriptor, maxBytes: maxOutputBytes))
            try? readHandle.close()
            let (data, overflowed) = capture.snapshot()
            if cancellation.isCancelled() { throw CancellationError() }
            if overflowed { throw AntigravityUsageError.unreadableResponse("CLI output exceeded limit") }
            if timedOut || process.terminationStatus != 0 || data.isEmpty {
                throw AntigravityUsageError.localServiceUnavailable
            }
            return data
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func terminateSubprocess(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let group = getpgid(pid)
        if group == pid, group > 0, group != getpgrp() {
            _ = kill(-group, SIGTERM)
        } else {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            if group == pid, group > 0, group != getpgrp() { _ = kill(-group, SIGKILL) }
            _ = kill(pid, SIGKILL)
        }
    }

    private static func drainNonBlocking(_ descriptor: Int32, maxBytes: Int) -> Data {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while result.count <= maxBytes {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        guard let text = clean(value as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
    private static func codeValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private static func codeIsSuccessful(_ value: String) -> Bool {
        ["0", "ok", "success"].contains(value.lowercased())
    }
    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private actor AgyVersionCache {
    private struct ExecutableIdentity: Equatable {
        let path: String
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }

    private var cached: (identity: ExecutableIdentity, version: (UInt, UInt, UInt))?

    func resolve(
        binary: String,
        probe: @Sendable () async throws -> (UInt, UInt, UInt)?
    ) async throws -> (UInt, UInt, UInt)? {
        let path = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return try await probe() }
        let identity = ExecutableIdentity(path: path, modified: modified, size: size, inode: inode)
        if let cached, cached.identity == identity { return cached.version }
        let version = try await probe()
        try Task.checkCancellation()
        if let version { cached = (identity, version) }
        return version
    }
}

private final class AntigravityLocalTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["127.0.0.1", "localhost"].contains(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
