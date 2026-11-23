import CoreFoundation
import Foundation

nonisolated enum TrustedRouterUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable
    case apiFailure(Int)
    case networkError(String)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("请在设置中填写 TrustedRouter API Key", "Check your TrustedRouter API key in Settings.")
        case .authenticationExpired, .permissionDenied:
            AppLocalization.text("TrustedRouter API Key 无效或无权限，请在设置中检查", "Check your TrustedRouter API key in Settings.")
        case .rateLimited:
            AppLocalization.text("TrustedRouter 请求过于频繁，请稍后重试", "TrustedRouter is rate limiting requests. Try again later.")
        case .providerUnavailable:
            AppLocalization.text("TrustedRouter 服务暂不可用，请稍后刷新", "TrustedRouter request failed. Try refreshing later.")
        case let .apiFailure(status):
            AppLocalization.text("TrustedRouter 请求失败（HTTP \(status)）", "TrustedRouter request failed (HTTP \(status)).")
        case let .networkError(message):
            AppLocalization.text("TrustedRouter 网络错误：\(message)", "TrustedRouter network error: \(message)")
        case .parseFailure:
            AppLocalization.text("无法识别 TrustedRouter 返回的数据", "TrustedRouter returned an unrecognized response.")
        }
    }
}

nonisolated struct TrustedRouterUsageSnapshot: Sendable, Equatable {
    let totalUsageUSD: Double
    let dailyUsageUSD: Double
    let weeklyUsageUSD: Double
    let monthlyUsageUSD: Double
    let limitUSD: Double?
    let remainingUSD: Double?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        var details: [UsageDetail] = []
        let balance: String?
        if let limit = limitUSD, let remaining = remainingUSD {
            // remaining 已扣除在途预留额度，不能用总消费反推。
            let spent = max(0, limit - remaining)
            if limit > 0 {
                windows.append(UsageWindow(
                    id: "trustedrouter-limit",
                    label: AppLocalization.text("额度上限", "Limit"),
                    usedFraction: spent / limit,
                    resetsAt: nil,
                    detail: "\(Self.usd(spent)) / \(Self.usd(limit))"
                ))
            }
            balance = Self.usd(remaining)
            details.append(UsageDetail(
                id: "trustedrouter-remaining",
                label: AppLocalization.text("剩余额度", "Remaining"),
                value: Self.usd(remaining)
            ))
            details.append(UsageDetail(
                id: "trustedrouter-limit-value",
                label: AppLocalization.text("额度上限", "Limit"),
                value: Self.usd(limit)
            ))
        } else {
            balance = nil
        }

        details.append(contentsOf: [
            UsageDetail(id: "trustedrouter-today", label: AppLocalization.text("今日", "Today"), value: Self.usd(dailyUsageUSD)),
            UsageDetail(id: "trustedrouter-week", label: AppLocalization.text("本周", "This week"), value: Self.usd(weeklyUsageUSD)),
            UsageDetail(id: "trustedrouter-month", label: AppLocalization.text("本月", "This month"), value: Self.usd(monthlyUsageUSD)),
            UsageDetail(id: "trustedrouter-total", label: AppLocalization.text("累计用量", "Total usage"), value: Self.usd(totalUsageUSD)),
        ])

        return ProviderUsage(
            id: ProviderID(rawValue: "trustedrouter"),
            state: .ready,
            windows: windows,
            balance: balance,
            plan: nil,
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func usd(_ value: Double) -> String {
        value < 0 ? String(format: "-$%.2f", -value) : String(format: "$%.2f", value)
    }
}

nonisolated enum TrustedRouterUsageFetcher {
    static let endpoint = URL(string: "https://api.trustedrouter.com/v1/key")!
    static let environmentKeys = ["TRUSTEDROUTER_API_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["TRUSTEDROUTER_API_KEY"]] {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw TrustedRouterUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TrustedRouterUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw TrustedRouterUsageError.parseFailure }
        switch http.statusCode {
        case 200:
            return try parse(data, now: now).toProviderUsage()
        case 401:
            throw TrustedRouterUsageError.authenticationExpired
        case 403:
            throw TrustedRouterUsageError.permissionDenied
        case 429:
            throw TrustedRouterUsageError.rateLimited
        case 500...599:
            throw TrustedRouterUsageError.providerUnavailable
        default:
            throw TrustedRouterUsageError.apiFailure(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> TrustedRouterUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw TrustedRouterUsageError.parseFailure
        }
        let total = try microdollars(payload["usage_microdollars"])
        let daily = try microdollars(payload["usage_daily_microdollars"])
        let weekly = try microdollars(payload["usage_weekly_microdollars"])
        let monthly = try microdollars(payload["usage_monthly_microdollars"])
        let limit = try optionalMicrodollars(payload["limit_microdollars"])
        let remaining = try optionalMicrodollars(payload["limit_remaining_microdollars"])
        guard (limit == nil) == (remaining == nil) else {
            throw TrustedRouterUsageError.parseFailure
        }
        return TrustedRouterUsageSnapshot(
            totalUsageUSD: total,
            dailyUsageUSD: daily,
            weeklyUsageUSD: weekly,
            monthlyUsageUSD: monthly,
            limitUSD: limit,
            remainingUSD: remaining,
            updatedAt: now
        )
    }

    private static func microdollars(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw TrustedRouterUsageError.parseFailure
        }
        let amount = number.doubleValue
        guard amount.isFinite, amount >= 0, amount <= 9_007_199_254_740_991, amount.rounded() == amount else {
            throw TrustedRouterUsageError.parseFailure
        }
        return amount / 1_000_000.0
    }

    private static func optionalMicrodollars(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        return try microdollars(value)
    }
}
