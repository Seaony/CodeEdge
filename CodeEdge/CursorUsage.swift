import CryptoKit
import Foundation

nonisolated enum CursorUsageError: LocalizedError, Equatable {
    case appSessionExpired

    var errorDescription: String? {
        AppLocalization.text(
            "Cursor 应用的登录已过期，请打开 Cursor 重新登录，或在浏览器登录 cursor.com 后重新填写 Cookie。",
            "Cursor app session expired. Open Cursor to sign in again, or sign in to cursor.com in your browser and update the cookie."
        )
    }
}

enum CursorUsageFetcher {
    static func fetch(
        credential: String,
        allowLocalSpendFallback: Bool = false,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let cookie = try cookieHeader(credential)
        async let summaryData = request(
            path: "/api/usage-summary",
            cookie: cookie,
            session: session
        )
        async let userData = optionalRequest(
            path: "/api/auth/me",
            cookie: cookie,
            session: session
        )
        async let sandData = optionalRequest(
            path: "/api/dashboard/get-sand-usage-status",
            method: "POST",
            cookie: cookie,
            session: session
        )
        let summary: Data
        do {
            summary = try await summaryData
        } catch let UsageCollectionError.requestFailed(status) where [401, 403].contains(status)
            && isExpiredAppToken(credential, now: now) {
            // 从 Cursor 应用读到的令牌过期时说明原因，而不是只报 HTTP 401。
            throw CursorUsageError.appSessionExpired
        }
        let user = await userData.flatMap { try? JSONDecoder().decode(CursorUser.self, from: $0) }
        let sand = await sandData.flatMap { try? JSONDecoder().decode(CursorSand.self, from: $0) }
        let parsedSummary = try? JSONDecoder().decode(CursorSummary.self, from: summary)
        let teamBudget: CursorTeamBudget? = if parsedSummary?.isTeamPlan == true, let email = user?.email {
            try? await fetchTeamBudget(cookie: cookie, email: email, session: session)
        } else {
            nil
        }
        try Task.checkCancellation()
        // 统一计费账号的月度花费单独从 usage-status 读，旧的请求额度接口对它们无意义。
        let isUnified = parsedSummary?.usesUnifiedPersonalBilling == true
        let unified: CursorUnifiedUsage? = if isUnified {
            await optionalRequest(path: "/api/dashboard/v2/usage-status?scope=user", cookie: cookie, session: session)
                .flatMap { try? JSONDecoder().decode(CursorUnifiedUsage.self, from: $0) }
        } else {
            nil
        }
        let requestUsageData: Data? = if !isUnified, teamBudget == nil,
                                       let userID = user?.sub ?? identity(from: cookie)?.subject {
            await optionalRequest(
                path: "/api/usage?user=\(userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
                cookie: cookie,
                session: session
            )
        } else {
            nil
        }
        let legacy = requestUsageData.flatMap { try? JSONDecoder().decode(CursorLegacyUsage.self, from: $0) }
        try Task.checkCancellation()
        var usage = try parse(
            summaryData: summary,
            user: user,
            legacy: legacy,
            sand: sand,
            teamBudget: teamBudget,
            unified: unified,
            now: now
        )
        // 本地 Tokscale 缓存不含账号身份，只能在自动模式下作为本地用量补充，不能覆盖手动凭据。
        if allowLocalSpendFallback,
           case let .report(report) = CursorLocalJSONReader.load(now: now) {
            if usage.today == nil { usage.today = report.today }
            if usage.last30Days == nil { usage.last30Days = report.last30Days }
            if usage.last30DaysDaily.isEmpty { usage.last30DaysDaily = report.last30DaysDaily }
        }
        return usage
    }

    static func parse(
        summaryData: Data,
        user: CursorUser? = nil,
        legacy: CursorLegacyUsage? = nil,
        sand: CursorSand? = nil,
        teamBudget: CursorTeamBudget? = nil,
        unified: CursorUnifiedUsage? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let summary: CursorSummary
        do {
            summary = try JSONDecoder().decode(CursorSummary.self, from: summaryData)
        } catch {
            throw UsageCollectionError.unreadableResponse
        }
        let plan = summary.individualUsage?.plan
        let overall = summary.individualUsage?.overall
        let pooled = summary.teamUsage?.pooled
        let planUsed = plan?.used.map(Double.init)
        let planLimit = plan?.limit.map(Double.init)
        let overallUsed = overall?.used.map(Double.init)
        let overallLimit = overall?.limit.map(Double.init)
        let pooledUsed = pooled?.used.map(Double.init)
        let pooledLimit = pooled?.limit.map(Double.init)

        let teamBudget = summary.isTeamPlan ? teamBudget : nil
        let autoPercent = teamBudget == nil ? plan?.autoPercentUsed.map(clampedPercent) : nil
        let apiPercent = teamBudget == nil ? plan?.apiPercentUsed.map(clampedPercent) : nil
        let totalPercent: Double?
        if let teamBudget {
            totalPercent = clampedPercent(teamBudget.usedUSD / teamBudget.limitUSD * 100)
        } else if let reported = plan?.totalPercentUsed {
            totalPercent = clampedPercent(reported)
        } else if let autoPercent, let apiPercent {
            totalPercent = clampedPercent((autoPercent + apiPercent) / 2)
        } else if let apiPercent {
            totalPercent = apiPercent
        } else if let autoPercent {
            totalPercent = autoPercent
        } else if let used = planUsed, let limit = planLimit, limit > 0 {
            totalPercent = clampedPercent(used / limit * 100)
        } else if let used = overallUsed, let limit = overallLimit, limit > 0 {
            totalPercent = clampedPercent(used / limit * 100)
        } else if let used = pooledUsed, let limit = pooledLimit, limit > 0 {
            totalPercent = clampedPercent(used / limit * 100)
        } else {
            totalPercent = nil
        }

        let reset = date(summary.billingCycleEnd)
        let billingCycleMinutes = windowMinutes(start: date(summary.billingCycleStart), end: reset)
        let legacyUsed = legacy?.gpt4?.numRequestsTotal ?? legacy?.gpt4?.numRequests
        let legacyLimit = legacy?.gpt4?.maxRequestUsage
        let hasLegacy = teamBudget == nil && legacyUsed != nil && (legacyLimit ?? 0) > 0
        let hasSandLimit = sand?.includedLimitZero.map { !$0 } ?? sand?.hasNonZeroIncludedLimit
        let hasSandTrial = hasSandLimit != true && date(sand?.sandTrialExpiresAt).map { $0 > now } == true
        let sandReset = hasSandTrial ? nil : date(sand?.nextResetTimestampUtc)
        // X 订阅共用一个每周额度池，usage-summary 里的月度数据已过时，用每周池做主额度。
        let sharedWeeklyReset: Date? = if !hasLegacy, sand?.isUnified == true, hasSandLimit == true || hasSandTrial,
                                          sand?.usagePercent != nil, let sandReset, sandReset > now {
            sandReset
        } else {
            nil
        }
        var windows: [UsageWindow] = []
        if let sharedWeeklyReset, let percent = sand?.usagePercent {
            windows.append(UsageWindow(
                id: "cursor-weekly",
                label: "Weekly",
                usedFraction: clampedPercent(percent) / 100,
                resetsAt: sharedWeeklyReset,
                detail: nil,
                windowMinutes: 10080
            ))
        } else if hasLegacy || totalPercent != nil {
            windows.append(UsageWindow(
                id: "cursor-total",
                label: "Total",
                usedFraction: hasLegacy
                    ? Double(legacyUsed ?? 0) / Double(legacyLimit ?? 1)
                    : (totalPercent ?? 0) / 100,
                resetsAt: reset,
                detail: hasLegacy ? "\(legacyUsed ?? 0) / \(legacyLimit ?? 0) requests" : nil,
                windowMinutes: billingCycleMinutes
            ))
        }
        if !hasLegacy, sharedWeeklyReset == nil, let autoPercent {
            windows.append(UsageWindow(
                id: "cursor-auto",
                label: "Cursor",
                usedFraction: autoPercent / 100,
                resetsAt: reset,
                detail: nil,
                windowMinutes: billingCycleMinutes
            ))
        }
        if !hasLegacy, sharedWeeklyReset == nil, let apiPercent {
            windows.append(UsageWindow(
                id: "cursor-api",
                label: "Third Party",
                usedFraction: apiPercent / 100,
                resetsAt: reset,
                detail: nil,
                windowMinutes: billingCycleMinutes
            ))
        }
        var additional: [UsageWindow] = []
        if !hasLegacy, sharedWeeklyReset == nil, hasSandLimit == true || hasSandTrial, let percent = sand?.usagePercent {
            additional.append(UsageWindow(
                id: "cursor-grok-bot",
                label: "Grok Bot",
                usedFraction: clampedPercent(percent) / 100,
                resetsAt: sandReset,
                detail: nil,
                windowMinutes: sandReset == nil ? nil : 10080
            ))
        }

        let personalUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100
        let personalLimit = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100 }
        let teamUsed = summary.teamUsage?.onDemand?.used.map { Double($0) / 100 }
        let teamLimit = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100 }
        let monthly = summary.usesUnifiedPersonalBilling ? unified?.currentMonthlyUsage(at: now) : nil
        let cost: ProviderCostSummary? = if let monthly {
            ProviderCostSummary(
                used: monthly.usedCents / 100,
                limit: monthly.limitCents / 100,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else if (personalLimit ?? 0) > 0 {
            ProviderCostSummary(
                used: personalUsed,
                limit: personalLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else if (teamLimit ?? 0) > 0 {
            ProviderCostSummary(
                used: teamUsed ?? 0,
                limit: teamLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else if personalUsed > 0 {
            ProviderCostSummary(
                used: personalUsed,
                limit: personalLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else {
            nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "cursor"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: nil,
            plan: membershipLabel(summary.membershipType),
            providerCost: cost,
            details: hasLegacy ? [UsageDetail(
                id: "cursor-request-quota",
                label: "Request quota",
                value: "\(legacyUsed ?? 0) / \(legacyLimit ?? 0)"
            )] : [],
            updatedAt: now,
            message: nil
        )
    }

    static func cookieHeader(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UsageCollectionError.missingCredential }
        if value.contains("WorkosCursorSessionToken=") || value.contains(";") {
            return value
        }
        guard let identity = try? tokenIdentity(value), let userID = identity.subject else {
            throw UsageCollectionError.missingCredential
        }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(encoded)"
    }

    private static func request(
        path: String,
        method: String = "GET",
        cookie: String,
        session: URLSession,
        body: [String: Any] = [:],
        timeout: TimeInterval = 20
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cursor.com\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageCollectionError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageCollectionError.requestFailed(http.statusCode)
        }
        return data
    }

    private static func fetchTeamBudget(
        cookie: String,
        email: String,
        session: URLSession
    ) async throws -> CursorTeamBudget? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(10)
        let teamsData = try await request(
            path: "/api/dashboard/teams", method: "POST", cookie: cookie, session: session,
            timeout: deadline.timeIntervalSinceNow
        )
        let teams = try JSONDecoder().decode(CursorTeams.self, from: teamsData)
        guard let teamID = teams.selectedID(cookie: cookie) else { return nil }
        var expectedPages: Int?
        var budget: CursorTeamBudget?
        for page in 1...20 {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            let data = try await request(
                path: "/api/dashboard/get-team-spend", method: "POST", cookie: cookie, session: session,
                body: ["teamId": teamID, "page": page, "pageSize": 50, "sortBy": "name", "sortDirection": "asc"],
                timeout: remaining
            )
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
            let spend = try JSONDecoder().decode(CursorTeamSpend.self, from: data)
            guard let pages = spend.totalPages, (1...20).contains(pages),
                  expectedPages == nil || expectedPages == pages,
                  !spend.teamMemberSpend.isEmpty, spend.teamMemberSpend.count <= 50,
                  page == pages || spend.teamMemberSpend.count == 50 else { return nil }
            expectedPages = pages
            for member in spend.teamMemberSpend where member.email?
                .trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(email) == .orderedSame {
                guard budget == nil, let memberBudget = member.budget else { return nil }
                budget = memberBudget
            }
            if page == pages { return budget }
        }
        return nil
    }

    private static func optionalRequest(
        path: String,
        method: String = "GET",
        cookie: String,
        session: URLSession
    ) async -> Data? {
        try? await request(path: path, method: method, cookie: cookie, session: session)
    }

    private static func identity(from cookie: String) -> CursorIdentity? {
        guard let component = cookie.split(separator: ";").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("WorkosCursorSessionToken=")
        }) else { return nil }
        let value = component.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        let decoded = value.removingPercentEncoding ?? value
        guard let token = decoded.components(separatedBy: "::").last else { return nil }
        return try? tokenIdentity(token)
    }

    static func isExpiredAppToken(_ credential: String, now: Date) -> Bool {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("WorkosCursorSessionToken="), !value.contains(";"),
              let expiry = (try? tokenPayload(value))?["exp"] as? Double
        else { return false }
        return Date(timeIntervalSince1970: expiry) <= now
    }

    private static func tokenPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw UsageCollectionError.missingCredential }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageCollectionError.missingCredential }
        return json
    }

    private static func tokenIdentity(_ token: String) throws -> CursorIdentity {
        let json = try tokenPayload(token)
        let subject = (json["sub"] as? String)?
            .split(separator: "|", omittingEmptySubsequences: true).last.map(String.init)
        return CursorIdentity(subject: subject, email: json["email"] as? String)
    }

    private nonisolated static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = end.timeIntervalSince(start) / 60
        guard minutes.isFinite, minutes > 0 else { return nil }
        return Int(exactly: minutes.rounded()).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func membershipLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let label = switch raw.lowercased() {
        case "enterprise": "Enterprise"
        case "express": "Start"
        case "free": "Free"
        case "free_trial": "Pro Trial"
        case "hobby": "Hobby"
        case "pro", "pro_student": "Pro"
        case "pro_plus": "Pro+"
        case "team": "Team"
        case "ultra": "Ultra"
        default: raw
        }
        return "Cursor \(label)"
    }
}

struct CursorUser: Decodable {
    var email: String?
    var name: String?
    var sub: String?
}

struct CursorLegacyUsage: Decodable {
    struct Model: Decodable {
        var numRequests: Int?
        var numRequestsTotal: Int?
        var maxRequestUsage: Int?
    }
    var gpt4: Model?
    enum CodingKeys: String, CodingKey { case gpt4 = "gpt-4" }
}

struct CursorSand: Decodable {
    var currentPeriodStart: String?
    var nextResetTimestampUtc: String?
    var usagePercent: Double?
    var hasNonZeroIncludedLimit: Bool?
    var includedLimitZero: Bool?
    var sandTrialExpiresAt: String?
    var isUnified: Bool?
}

struct CursorUnifiedUsage: Decodable {
    struct MonthlyUsage: Decodable {
        var usedCents: Double
        var limitCents: Double
        var periodStart: String
        var resetsAt: String
    }

    var availability: String
    var monthlyUsage: MonthlyUsage?

    // 只采用当前计费周期内、数值有效的月度花费。
    func currentMonthlyUsage(at now: Date) -> MonthlyUsage? {
        let formatter = ISO8601DateFormatter()
        func parse(_ raw: String) -> Date? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        guard availability == "available", let usage = monthlyUsage,
              usage.usedCents.isFinite, usage.usedCents >= 0,
              usage.limitCents.isFinite, usage.limitCents >= 0,
              let start = parse(usage.periodStart), let reset = parse(usage.resetsAt),
              start <= now, now < reset else { return nil }
        return usage
    }
}

struct CursorTeamBudget {
    var usedUSD: Double
    var limitUSD: Double
}

private struct CursorTeams: Decodable {
    struct Team: Decodable { var id: Int }
    var teams: [Team]

    func selectedID(cookie: String) -> Int? {
        let ids = Set(teams.map(\.id).filter { $0 > 0 })
        guard ids.count == teams.count else { return nil }
        let cookies = cookie.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        }
        for name in ["portal-selected-team-id", "team_id"] {
            let values = cookies.filter { $0.first == Substring(name) }
            if !values.isEmpty {
                guard values.count == 1, values[0].count == 2,
                      let id = Int(values[0][1]), ids.contains(id) else { return nil }
                return id
            }
        }
        return ids.count == 1 ? ids.first : nil
    }
}

private struct CursorTeamSpend: Decodable {
    struct Member: Decodable {
        var email: String?
        var overallSpendCents: Double?
        var effectivePerUserLimitDollars: Double?
        var monthlyLimitDollars: Double?

        var budget: CursorTeamBudget? {
            guard let used = overallSpendCents, used.isFinite, used >= 0,
                  let limit = effectivePerUserLimitDollars ?? monthlyLimitDollars,
                  limit.isFinite, limit > 0 else { return nil }
            return CursorTeamBudget(usedUSD: used / 100, limitUSD: limit)
        }
    }
    var teamMemberSpend: [Member]
    var totalPages: Int?
}

private struct CursorIdentity {
    var subject: String?
    var email: String?
}

private struct CursorSummary: Decodable {
    struct UsageBlock: Decodable {
        struct Plan: Decodable {
            var used: Int?
            var limit: Int?
            var autoPercentUsed: Double?
            var apiPercentUsed: Double?
            var totalPercentUsed: Double?
        }
        struct Amount: Decodable { var used: Int?; var limit: Int? }
        var plan: Plan?
        var onDemand: Amount?
        var overall: Amount?
        var pooled: Amount?
    }
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var limitType: String?
    var individualUsage: UsageBlock?
    var teamUsage: UsageBlock?

    var usesUnifiedPersonalBilling: Bool {
        membershipType?.lowercased().hasPrefix("unified_") == true && limitType?.lowercased() == "user"
    }

    var isTeamPlan: Bool {
        ["enterprise", "business", "team", "teams"].contains(membershipType?.lowercased() ?? "")
            || limitType?.lowercased() == "team"
    }
}

/// 读取 Tokscale 生成的 Cursor JSON 缓存（`~/.config/tokscale/cursor-cache/usage.json`）。
/// 一旦存在 canonical `usage.json`，即作为权威来源，不再混用旧 CSV。
nonisolated enum CursorLocalJSONReader {
    enum Result: Equatable {
        case absent
        case unavailable
        case report(Report)
    }

    struct Report: Equatable {
        let today: DailyTokenUsage?
        let last30Days: DailyTokenUsage?
        let last30DaysDaily: [DailyTokenUsagePoint]
        let meteredCostUSD: Double?
        let isComplete: Bool
    }

    static func cacheDirectory(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home {
            return home.appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        }
        if let dir = environment["TOKSCALE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("cursor-cache", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
    }

    static func load(
        home: URL? = nil,
        now: Date = Date(),
        historyDays: Int = 30,
        calendar: Calendar = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result {
        let url = cacheDirectory(home: home, environment: environment).appendingPathComponent("usage.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return .unavailable }
        } catch {
            let nsError = error as NSError
            return nsError.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
                ? .absent : .unavailable
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return .unavailable
        }
        let rows = document.rows.compactMap(\.value)
        let isComplete = rows.count == document.rows.count
        let todayStart = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let since = calendar.date(byAdding: .day, value: -(max(1, historyDays) - 1), to: todayStart) else {
            return .unavailable
        }

        let deduped = deduplicated(rows).filter { row in
            let date = Date(timeIntervalSince1970: Double(row.timestampMS) / 1000)
            return date >= since && date <= end
        }
        guard !deduped.isEmpty else {
            return .report(Report(
                today: nil,
                last30Days: nil,
                last30DaysDaily: [],
                meteredCostUSD: nil,
                isComplete: isComplete
            ))
        }

        var dayTotals: [Date: (tokens: Int64, costUSD: Double, hasCost: Bool, missingCost: Bool)] = [:]
        var totalTokens: Int64 = 0
        var totalCostUSD: Double = 0
        var hasAnyCost = false
        var hasMissingCost = false

        for row in deduped {
            let date = Date(timeIntervalSince1970: Double(row.timestampMS) / 1000)
            let day = calendar.startOfDay(for: date)
            let tokens = row.totalTokens
            totalTokens += tokens
            var bucket = dayTotals[day] ?? (0, 0, false, false)
            bucket.tokens += tokens
            if let cents = row.costCents {
                let usd = cents / 100
                totalCostUSD += usd
                hasAnyCost = true
                bucket.costUSD += usd
                bucket.hasCost = true
            } else {
                hasMissingCost = true
                bucket.missingCost = true
            }
            dayTotals[day] = bucket
        }

        let dailyPoints = dayTotals.keys.sorted().map { day -> DailyTokenUsagePoint in
            let bucket = dayTotals[day]!
            let usage = DailyTokenUsage(
                tokens: bucket.tokens,
                valueUSD: bucket.hasCost && !bucket.missingCost ? bucket.costUSD : nil,
                partialValueUSD: bucket.hasCost && bucket.missingCost ? bucket.costUSD : nil
            )
            return DailyTokenUsagePoint(date: day, usage: usage)
        }
        let todayBucket = dayTotals[todayStart]
        let todayUsage = todayBucket.map { bucket in
            DailyTokenUsage(
                tokens: bucket.tokens,
                valueUSD: bucket.hasCost && !bucket.missingCost ? bucket.costUSD : nil,
                partialValueUSD: bucket.hasCost && bucket.missingCost ? bucket.costUSD : nil
            )
        }
        let last30Usage = DailyTokenUsage(
            tokens: totalTokens,
            valueUSD: hasAnyCost && !hasMissingCost ? totalCostUSD : nil,
            partialValueUSD: hasAnyCost && hasMissingCost ? totalCostUSD : nil
        )
        return .report(Report(
            today: todayUsage,
            last30Days: last30Usage,
            last30DaysDaily: dailyPoints,
            meteredCostUSD: isComplete && hasAnyCost && !hasMissingCost ? totalCostUSD : nil,
            isComplete: isComplete
        ))
    }

    private static func deduplicated(_ rows: [Row]) -> [Row] {
        var identified: [Row.Identity: String] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            identified[row.identity] = min(identified[row.identity] ?? id, id)
        }
        var winners: [String: Int] = [:]
        var keep = Array(repeating: true, count: rows.count)
        for (index, row) in rows.enumerated() {
            guard let id = row.id ?? identified[row.identity] else { continue }
            if let previous = winners[id] {
                let old = rows[previous]
                if row.totalTokens > old.totalTokens
                    || (row.totalTokens == old.totalTokens && row.rankCost > old.rankCost) {
                    keep[previous] = false
                    winners[id] = index
                } else {
                    keep[index] = false
                }
            } else {
                winners[id] = index
            }
        }
        return rows.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private enum InvalidCache: Error {
        case metadata
        case row
    }

    private struct Document: Decodable {
        let rows: [LossyRow]

        enum CodingKeys: String, CodingKey {
            case rows = "usageEventsDisplay"
            case owner = "_owner"
            case legacy = "_tokscale"
            case footer = "zzTokscaleOwner"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let hasEnvelope = container.contains(.owner) || container.contains(.footer)
            if container.contains(.legacy) || hasEnvelope {
                let legacy = try container.decode(LegacyOwner.self, forKey: .legacy)
                guard legacy.version == 1, !legacy.accountId.isEmpty else { throw InvalidCache.metadata }
                if hasEnvelope {
                    let owner = try container.decode(Owner.self, forKey: .owner)
                    let footer = try container.decode(Footer.self, forKey: .footer)
                    let hash = SHA256.hash(data: Data(legacy.accountId.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    guard owner.version == 1, footer.version == 1,
                          UUID(uuidString: owner.generation) != nil,
                          owner.generation == footer.generation,
                          owner.ownerHash == hash else {
                        throw InvalidCache.metadata
                    }
                }
            }
            rows = try container.decode([LossyRow].self, forKey: .rows)
        }
    }

    private struct Owner: Decodable {
        let version: Int
        let ownerHash: String
        let generation: String
    }

    private struct Footer: Decodable {
        let version: Int
        let generation: String
    }

    private struct LegacyOwner: Decodable {
        let version: Int
        let accountId: String
    }

    private struct LossyRow: Decodable {
        let value: Row?

        init(from decoder: Decoder) {
            value = try? Row(from: decoder)
        }
    }

    private struct Row: Decodable {
        struct Identity: Hashable {
            let conversation: String?
            let model: String
            let timestamp: Int64
        }

        let id: String?
        let identity: Identity
        let timestampMS: Int64
        let model: String
        let totalTokens: Int64
        let costCents: Double?

        var rankCost: Double { costCents ?? 0 }

        enum CodingKeys: String, CodingKey {
            case usageEventId, conversationId, timestamp, model, chargedCents, tokenUsage
        }

        init(from decoder: Decoder) throws {
            let conversation: String?
            let timestamp: Timestamp?
            let model: String?
            let charged: Amount?
            let usage: Tokens?
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                id = Self.nonempty(try? container.decode(String.self, forKey: .usageEventId))
                conversation = Self.nonempty(try? container.decode(String.self, forKey: .conversationId))
                timestamp = try container.decodeIfPresent(Timestamp.self, forKey: .timestamp)
                model = Self.nonempty(try? container.decode(String.self, forKey: .model))
                charged = try container.decodeIfPresent(Amount.self, forKey: .chargedCents)
                usage = try container.decodeIfPresent(Tokens.self, forKey: .tokenUsage)
            } else {
                var container = try decoder.unkeyedContainer()
                id = nil
                conversation = try Self.nonempty(container.decodeIfPresent(String.self))
                timestamp = container.isAtEnd ? nil : try container.decodeIfPresent(Timestamp.self)
                model = try Self.nonempty(container.isAtEnd ? nil : container.decodeIfPresent(String.self))
                charged = container.isAtEnd ? nil : try container.decodeIfPresent(Amount.self)
                usage = container.isAtEnd ? nil : try container.decodeIfPresent(Tokens.self)
                guard container.isAtEnd else { throw InvalidCache.row }
            }
            guard let timestamp, let model else { throw InvalidCache.row }
            self.timestampMS = timestamp.milliseconds
            self.model = model
            self.identity = Identity(conversation: conversation, model: model, timestamp: timestamp.milliseconds)
            self.totalTokens = usage?.totalTokens ?? 0
            self.costCents = usage?.totalCents ?? charged?.value
        }

        private static func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }

    private struct Timestamp: Decodable {
        let milliseconds: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let milliseconds: Int64?
            if let value = try? container.decode(String.self) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let numeric = Int64(trimmed) ?? Double(trimmed).flatMap(Int64.init(exactly:)) {
                    milliseconds = numeric
                } else {
                    let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
                        ?? (try? Date.ISO8601FormatStyle().parse(trimmed))
                    milliseconds = parsed.flatMap {
                        Int64(exactly: ($0.timeIntervalSince1970 * 1000).rounded(.towardZero))
                    }
                }
            } else {
                milliseconds = (try? container.decode(Double.self)).flatMap(Int64.init(exactly:))
            }
            guard let milliseconds, milliseconds > 0, milliseconds <= 253_402_300_799_999 else {
                throw InvalidCache.row
            }
            self.milliseconds = milliseconds
        }
    }

    private struct Count: Decodable {
        let value: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value: Int64? = if let integer = try? container.decode(Int64.self) {
                integer
            } else if let text = try? container.decode(String.self) {
                Int64(text) ?? Double(text).flatMap(Int64.init(exactly:))
            } else {
                (try? container.decode(Double.self)).flatMap(Int64.init(exactly:))
            }
            guard let value, value >= 0 else { throw InvalidCache.row }
            self.value = value
        }
    }

    private struct Amount: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
                return
            }
            let parsed: Double? = if let text = try? container.decode(String.self) {
                Double(text)
            } else {
                try? container.decode(Double.self)
            }
            if let parsed, parsed.isFinite, parsed >= 0 {
                value = parsed
            } else {
                value = nil
            }
        }
    }

    private struct Tokens: Decodable {
        let totalTokens: Int64
        let totalCents: Double?

        enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalCents
        }

        init(from decoder: Decoder) throws {
            let input: Int64
            let output: Int64
            let read: Int64
            let write: Int64
            let cost: Double?
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                input = try container.decodeIfPresent(Count.self, forKey: .inputTokens)?.value ?? 0
                output = try container.decodeIfPresent(Count.self, forKey: .outputTokens)?.value ?? 0
                read = try container.decodeIfPresent(Count.self, forKey: .cacheReadTokens)?.value ?? 0
                write = try container.decodeIfPresent(Count.self, forKey: .cacheWriteTokens)?.value ?? 0
                cost = try container.decodeIfPresent(Amount.self, forKey: .totalCents)?.value
            } else {
                var container = try decoder.unkeyedContainer()
                input = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                output = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                read = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                write = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                cost = container.isAtEnd ? nil : try container.decodeIfPresent(Amount.self)?.value
                guard container.isAtEnd else { throw InvalidCache.row }
            }
            var total: Int64 = 0
            for part in [input, output, read, write] {
                let (sum, overflow) = total.addingReportingOverflow(part)
                guard !overflow else { throw InvalidCache.row }
                total = sum
            }
            totalTokens = total
            totalCents = cost
        }
    }
}
