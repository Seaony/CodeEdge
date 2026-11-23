import CoreFoundation
import Foundation

nonisolated enum VercelUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingTeamID
    case invalidTeamID
    case authenticationExpired(Int)
    case permissionDenied(Int)
    case rateLimited
    case providerUnavailable(Int)
    case networkError(String)
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 Vercel AI Gateway API Key，或用于个人预算的 Vercel Access Token 与 Team ID",
                "Set a Vercel AI Gateway API key, or a Vercel access token and Team ID for your personal budget."
            )
        case .missingTeamID:
            AppLocalization.text(
                "读取个人预算需要填写 Vercel Team ID",
                "Set the Vercel Team ID to read your personal budget."
            )
        case .invalidTeamID:
            AppLocalization.text(
                "Vercel Team ID 格式无效，请填写不含空格的团队 ID 或 slug",
                "Invalid Vercel Team ID. Enter the team ID or slug without spaces."
            )
        case let .authenticationExpired(status):
            AppLocalization.text("Vercel 认证失败（HTTP \(status)）", "Vercel API returned HTTP \(status).")
        case let .permissionDenied(status):
            AppLocalization.text("Vercel 拒绝访问（HTTP \(status)）", "Vercel API returned HTTP \(status).")
        case .rateLimited:
            AppLocalization.text("Vercel 请求过于频繁，请稍后重试", "Vercel API rate limit reached.")
        case let .providerUnavailable(status):
            AppLocalization.text("Vercel 服务暂不可用（HTTP \(status)）", "Vercel API returned HTTP \(status).")
        case let .networkError(message):
            AppLocalization.text("Vercel Gateway 网络错误：\(message)", "Vercel Gateway network error: \(message)")
        case let .apiError(status):
            AppLocalization.text(
                "Vercel Gateway 请求失败（HTTP \(status)）",
                "Vercel Gateway request failed (HTTP \(status))"
            )
        case .invalidResponse:
            AppLocalization.text("Vercel Gateway 返回的数据无效", "Vercel Gateway returned an unrecognized response.")
        }
    }
}

nonisolated struct VercelUsageSnapshot: Sendable, Equatable {
    let availableBalanceUSD: Double
    let lifetimeSpendUSD: Double
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "vercel"),
            state: .ready,
            windows: [],
            balance: Self.usd(availableBalanceUSD),
            plan: nil,
            details: [
                UsageDetail(
                    id: "vercel-balance",
                    label: AppLocalization.text("可用余额", "Available balance"),
                    value: Self.usd(availableBalanceUSD)
                ),
                UsageDetail(
                    id: "vercel-lifetime-spend",
                    label: AppLocalization.text("累计消费", "Lifetime spend"),
                    value: Self.usd(lifetimeSpendUSD)
                ),
            ],
            updatedAt: updatedAt,
            message: nil
        )
    }

    static func usd(_ value: Double) -> String {
        value < 0 ? String(format: "-$%.2f", -value) : String(format: "$%.2f", value)
    }
}

nonisolated struct VercelPersonalBudgetSnapshot: Sendable, Equatable {
    let email: String?
    let teamID: String
    let spentUSD: Double?
    let limitUSD: Double?
    let resetsAt: Date?
    let windowMinutes: Int?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        var details: [UsageDetail] = []
        var windows: [UsageWindow] = []
        let balance: String?
        if let spent = spentUSD, let limit = limitUSD {
            let spentText = VercelUsageSnapshot.usd(spent)
            let limitText = VercelUsageSnapshot.usd(limit)
            let remaining = max(0, limit - spent)
            let remainingText = VercelUsageSnapshot.usd(remaining)
            windows.append(UsageWindow(
                id: "vercel-personal-budget",
                label: AppLocalization.text("个人预算", "Personal budget"),
                usedFraction: spent / limit,
                resetsAt: resetsAt,
                detail: "\(spentText) / \(limitText)",
                windowMinutes: windowMinutes
            ))
            balance = remainingText
            details.append(contentsOf: [
                UsageDetail(id: "vercel-budget-spend", label: AppLocalization.text("已用", "Spend"), value: spentText),
                UsageDetail(id: "vercel-budget-limit", label: AppLocalization.text("上限", "Limit"), value: limitText),
                UsageDetail(id: "vercel-budget-remaining", label: AppLocalization.text("剩余", "Remaining"), value: remainingText),
            ])
        } else {
            balance = nil
            details.append(UsageDetail(
                id: "vercel-budget-empty",
                label: AppLocalization.text("未配置个人预算", "No personal budget configured"),
                value: "—"
            ))
        }
        if let email {
            details.append(UsageDetail(id: "vercel-account", label: AppLocalization.text("账号", "Account"), value: email))
        }
        details.append(UsageDetail(id: "vercel-team", label: "Team", value: teamID))

        return ProviderUsage(
            id: ProviderID(rawValue: "vercel"),
            state: .ready,
            windows: windows,
            balance: balance,
            plan: AppLocalization.text("个人预算", "Personal budget"),
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum VercelUsageFetcher {
    static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v1/credits")!
    static let userEndpoint = URL(string: "https://api.vercel.com/v2/user")!
    static let budgetsListBase = "https://api.vercel.com/ai-gateway/budgets/list"
    static let environmentKeys = ["AI_GATEWAY_API_KEY"]
    static let accessTokenEnvironmentKey = "VERCEL_ACCESS_TOKEN"
    static let teamIDEnvironmentKey = "VERCEL_TEAM_ID"

    private struct CreditResponse: Decodable {
        let balance: String
        let totalUsed: String

        private enum CodingKeys: String, CodingKey {
            case balance
            case totalUsed = "total_used"
        }
    }

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        firstNonEmpty([configured, environment["AI_GATEWAY_API_KEY"]])
    }

    static func resolvedAccessToken(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        firstNonEmpty([configured, environment[accessTokenEnvironmentKey]])
    }

    static func resolvedTeamID(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        firstNonEmpty([configured, environment[teamIDEnvironmentKey]])
    }

    static func fetch(
        apiKey configured: String?,
        accessToken configuredAccessToken: String? = nil,
        teamID configuredTeamID: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if let accessToken = resolvedAccessToken(configured: configuredAccessToken, environment: environment) {
            let teamID = resolvedTeamID(configured: configuredTeamID, environment: environment)
            return try await fetchPersonalBudget(
                accessToken: accessToken,
                teamID: teamID,
                session: session,
                now: now
            ).toProviderUsage()
        }
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw VercelUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await perform(request, session: session)
        guard http.statusCode == 200 else { throw VercelUsageError.apiError(http.statusCode) }
        return try parse(data, now: now).toProviderUsage()
    }

    static func fetchPersonalBudget(
        accessToken: String,
        teamID rawTeamID: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> VercelPersonalBudgetSnapshot {
        guard let team = rawTeamID?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
            throw VercelUsageError.missingTeamID
        }
        guard team.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw VercelUsageError.invalidTeamID
        }

        let userRoot = try await fetchVercelJSON(url: userEndpoint, token: accessToken, session: session)
        guard let user = userRoot["user"] as? [String: Any],
              let userID = user["id"] as? String, !userID.isEmpty else {
            throw VercelUsageError.invalidResponse
        }
        let email = (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var matches: [[String: Any]] = []
        var seenCursors: Set<String> = []
        var cursor: String?
        let expectedScopeIDs: Set<String> = [userID, "usr_\(userID)"]

        for page in 0..<20 {
            try Task.checkCancellation()
            var components = URLComponents(string: budgetsListBase)!
            var items = [
                URLQueryItem(name: "teamId", value: team),
                URLQueryItem(name: "scopeType", value: "user"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = items
            guard let url = components.url else { throw VercelUsageError.invalidResponse }

            let body = try await fetchVercelJSON(url: url, token: accessToken, session: session)
            guard let budgets = body["budgets"] as? [Any] else { throw VercelUsageError.invalidResponse }
            for raw in budgets {
                guard let budget = raw as? [String: Any] else { continue }
                guard (budget["scopeType"] as? String) == "user",
                      let scopeID = budget["scopeId"] as? String,
                      expectedScopeIDs.contains(scopeID) else { continue }
                guard let active = strictBool(budget["active"]),
                      let archived = strictBool(budget["archived"]) else {
                    throw VercelUsageError.invalidResponse
                }
                if let rawSource = budget["source"], !(rawSource is NSNull) {
                    guard (rawSource as? String) == "default" else { throw VercelUsageError.invalidResponse }
                }
                if active && !archived {
                    matches.append(budget)
                }
            }

            let rawNext = body["nextCursor"]
            if rawNext == nil || rawNext is NSNull { break }
            guard let next = rawNext as? String, !next.isEmpty,
                  !seenCursors.contains(next), page < 19 else {
                throw VercelUsageError.invalidResponse
            }
            seenCursors.insert(next)
            cursor = next
        }

        return try parsePersonalBudget(matches: matches, email: email, teamID: team, now: now)
    }

    static func parsePersonalBudget(
        matches: [[String: Any]],
        email: String?,
        teamID: String,
        now: Date = Date()
    ) throws -> VercelPersonalBudgetSnapshot {
        let custom = matches.filter { ($0["source"] as? String) != "default" }
        let effective = custom.isEmpty ? matches : custom
        guard effective.count <= 1 else { throw VercelUsageError.invalidResponse }
        guard let budget = effective.first else {
            return VercelPersonalBudgetSnapshot(
                email: email, teamID: teamID, spentUSD: nil, limitUSD: nil,
                resetsAt: nil, windowMinutes: nil, updatedAt: now
            )
        }
        guard let limit = strictNumber(budget["limitAmount"]), limit > 0,
              let spent = strictNumber(budget["currentSpend"]), spent >= 0,
              let refreshPeriod = budget["refreshPeriod"] as? String else {
            throw VercelUsageError.invalidResponse
        }

        let (resetsAt, windowMinutes) = try utcBudgetWindow(period: refreshPeriod, now: now)
        return VercelPersonalBudgetSnapshot(
            email: email,
            teamID: teamID,
            spentUSD: spent,
            limitUSD: limit,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            updatedAt: now
        )
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> VercelUsageSnapshot {
        guard let response = try? JSONDecoder().decode(CreditResponse.self, from: data),
              let balance = money(response.balance),
              let spent = money(response.totalUsed), spent >= 0 else {
            throw VercelUsageError.invalidResponse
        }
        return VercelUsageSnapshot(availableBalanceUSD: balance, lifetimeSpendUSD: spent, updatedAt: now)
    }

    private static func fetchVercelJSON(
        url: URL,
        token: String,
        session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await perform(request, session: session)
        switch http.statusCode {
        case 200:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VercelUsageError.invalidResponse
            }
            return root
        case 401:
            throw VercelUsageError.authenticationExpired(401)
        case 403:
            throw VercelUsageError.permissionDenied(403)
        case 429:
            throw VercelUsageError.rateLimited
        case 500...599:
            throw VercelUsageError.providerUnavailable(http.statusCode)
        default:
            throw VercelUsageError.apiError(http.statusCode)
        }
    }

    private static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VercelUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw VercelUsageError.invalidResponse }
        return (data, http)
    }

    private static func utcBudgetWindow(period: String, now: Date) throws -> (Date?, Int?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let year = components.year, let month = components.month, let day = components.day,
              let weekday = components.weekday else {
            throw VercelUsageError.invalidResponse
        }
        switch period {
        case "daily":
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw VercelUsageError.invalidResponse
            }
            return (end, Int(round(end.timeIntervalSince(start) / 60)))
        case "weekly":
            // Monday 00:00 UTC (Calendar.weekday: 1 = Sunday, 2 = Monday ... 7 = Saturday)
            let daysSinceMonday = (weekday + 5) % 7
            guard let todayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                throw VercelUsageError.invalidResponse
            }
            return (end, Int(round(end.timeIntervalSince(start) / 60)))
        case "monthly":
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                throw VercelUsageError.invalidResponse
            }
            return (end, Int(round(end.timeIntervalSince(start) / 60)))
        case "none":
            return (nil, nil)
        default:
            throw VercelUsageError.invalidResponse
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for raw in values {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func money(_ value: String) -> Double? {
        guard value.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let amount = Double(value), amount.isFinite else { return nil }
        return amount
    }
}
