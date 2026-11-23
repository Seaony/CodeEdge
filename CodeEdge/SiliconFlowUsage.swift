import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum SiliconFlowUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingWebSession
    case cookieImportDeferred
    case invalidOrigin
    case webRequiresChinaOrigin
    case authenticationExpired
    case webSessionExpired
    case webPermissionDenied
    case balanceQueryRefused
    case chinaBalanceAPIRetired
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 SiliconFlow API Key，请在设置中填写或设置 SILICONFLOW_API_KEY",
                "Missing SiliconFlow API key. Add one in Settings or set SILICONFLOW_API_KEY"
            )
        case .missingWebSession:
            AppLocalization.text(
                "未找到 SiliconFlow 浏览器会话，请先在浏览器登录 cloud.siliconflow.cn 或粘贴 Cookie 标头",
                "Sign in to cloud.siliconflow.cn in your browser, then refresh CodeEdge."
            )
        case .cookieImportDeferred:
            AppLocalization.text(
                "请手动刷新一次以读取 SiliconFlow 浏览器 Cookie",
                "Refresh manually to import SiliconFlow browser cookies."
            )
        case .invalidOrigin:
            AppLocalization.text(
                "SiliconFlow API 地址只能是 https://api.siliconflow.cn 或 https://api.siliconflow.com",
                "SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com."
            )
        case .webRequiresChinaOrigin:
            AppLocalization.text(
                "Web 控制台余额仅支持中国区（api.siliconflow.cn）",
                "Web console balance is only supported for China (api.siliconflow.cn)."
            )
        case .authenticationExpired:
            AppLocalization.text("SiliconFlow API Key 无效，请在设置中检查", "Check your SiliconFlow API key in Settings.")
        case .webSessionExpired:
            AppLocalization.text(
                "SiliconFlow 网页会话已过期，请在浏览器重新登录 cloud.siliconflow.cn 后刷新",
                "Sign in to cloud.siliconflow.cn in your browser, then refresh CodeEdge."
            )
        case .webPermissionDenied:
            AppLocalization.text(
                "SiliconFlow 拒绝访问控制台余额（HTTP 403），请打开 cloud.siliconflow.cn 确认该账号可查看账单后再刷新",
                "SiliconFlow denied access to the console balance (HTTP 403). Open cloud.siliconflow.cn, check that this account can view billing, then refresh."
            )
        case .balanceQueryRefused:
            AppLocalization.text(
                "SiliconFlow 拒绝了余额查询，请在 SiliconFlow 控制台查看余额",
                "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console."
            )
        case .chinaBalanceAPIRetired:
            AppLocalization.text(
                "SiliconFlow 中国区余额 API 已下线，请将读取方式切换为 Web 并在浏览器登录 cloud.siliconflow.cn",
                "The SiliconFlow China balance API was retired. Switch SiliconFlow to Web and sign in to cloud.siliconflow.cn."
            )
        case .rateLimited:
            AppLocalization.text("SiliconFlow 请求频率受限，请稍后再试", "SiliconFlow is rate limiting requests. Try again later.")
        case let .providerUnavailable(status):
            AppLocalization.text("SiliconFlow 服务暂时不可用（HTTP \(status)）", "SiliconFlow is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("SiliconFlow 请求失败（HTTP \(status)）", "SiliconFlow request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("SiliconFlow 返回了无法识别的内容", "SiliconFlow returned an unrecognized response")
        }
    }
}

nonisolated enum SiliconFlowUsageFetcher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let apiKeyEnvironmentKey = "SILICONFLOW_API_KEY"
    static let baseURLEnvironmentKey = "SILICONFLOW_BASE_URL"
    static let chinaOrigin = URL(string: "https://api.siliconflow.cn")!
    static let internationalOrigin = URL(string: "https://api.siliconflow.com")!
    static let chinaConsoleOrigin = "https://cloud.siliconflow.cn"
    static let chinaBillingPage = URL(string: "https://cloud.siliconflow.cn/me/expensebill")!
    static let chinaWalletEndpoint = URL(string: "https://cloud.siliconflow.cn/walletd-server/api/v1/subject/profile/peek")!
    private static let cookieDomains = ["cloud.siliconflow.cn", "siliconflow.cn"]
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        apiKey configuredAPIKey: String?,
        origin configuredOrigin: String?,
        source: ProviderSource = .automatic,
        cookieHeader configuredCookie: String? = nil,
        allowBrowserImport: Bool = false,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: Transport? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        // 地址不合法时直接报错，不把凭据发到其他主机。
        guard let origin = resolvedOrigin(configured: configuredOrigin, environment: environment) else {
            throw SiliconFlowUsageError.invalidOrigin
        }

        // Auto 坚持以 API Key 为准；只有用户显式选择 Web (.cookie) 才读取中国区控制台会话。
        if source == .cookie {
            guard origin == chinaOrigin else { throw SiliconFlowUsageError.webRequiresChinaOrigin }
            return try await fetchChinaWebBalance(
                manualCookie: configuredCookie,
                allowBrowserImport: allowBrowserImport,
                session: session,
                transport: transport,
                now: now
            )
        }

        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment[apiKeyEnvironmentKey]) else {
            throw SiliconFlowUsageError.missingCredentials
        }
        var request = URLRequest(url: origin.appendingPathComponent("v1/user/info"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http): (Data, HTTPURLResponse)
        if let transport {
            (data, http) = try await transport(request)
        } else {
            let (rawData, response) = try await session.data(for: request)
            guard let responseHTTP = response as? HTTPURLResponse else { throw SiliconFlowUsageError.parseFailure }
            (data, http) = (rawData, responseHTTP)
        }
        let currency = origin == chinaOrigin ? "CNY" : "USD"
        switch http.statusCode {
        case 200: break
        case 410:
            throw currency == "CNY"
                ? SiliconFlowUsageError.chinaBalanceAPIRetired
                : SiliconFlowUsageError.balanceQueryRefused
        case 401, 403: throw SiliconFlowUsageError.authenticationExpired
        case 429: throw SiliconFlowUsageError.rateLimited
        case 500...: throw SiliconFlowUsageError.providerUnavailable(http.statusCode)
        default: throw SiliconFlowUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, currency: currency, now: now)
    }

    static func fetchChinaWebBalance(
        manualCookie: String?,
        allowBrowserImport: Bool,
        session: URLSession,
        transport: Transport? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let ephemeral: URLSession?
        let perform: Transport
        if let transport {
            ephemeral = nil
            perform = transport
        } else {
            let configuration = (session.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let requestSession = URLSession(
                configuration: configuration,
                delegate: SiliconFlowRedirectGuard(),
                delegateQueue: nil
            )
            ephemeral = requestSession
            perform = { request in
                let (data, response) = try await FetchDiagnostics.data(for: request, session: requestSession)
                guard let http = response as? HTTPURLResponse else { throw SiliconFlowUsageError.parseFailure }
                return (data, http)
            }
        }
        defer { ephemeral?.invalidateAndCancel() }

        if let manual = normalizedCookie(manualCookie) {
            return try await fetchChinaWebBalance(cookie: manual, perform: perform, now: now)
        }
        guard allowBrowserImport else { throw SiliconFlowUsageError.cookieImportDeferred }

        let client = BrowserCookieClient()
        var rejected = false
        for browser in Browser.defaultImportOrder {
            try Task.checkCancellation()
            for cookie in automaticCookies(in: browser, client: client) {
                try Task.checkCancellation()
                do {
                    return try await fetchChinaWebBalance(cookie: cookie, perform: perform, now: now)
                } catch SiliconFlowUsageError.webSessionExpired {
                    rejected = true
                }
            }
        }
        throw rejected ? SiliconFlowUsageError.webSessionExpired : SiliconFlowUsageError.missingWebSession
    }

    static func fetchChinaWebBalance(
        cookie: String,
        perform: Transport,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var pageRequest = URLRequest(url: chinaBillingPage)
        pageRequest.httpMethod = "GET"
        pageRequest.timeoutInterval = 15
        pageRequest.httpShouldHandleCookies = false
        pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        pageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, pageHTTP) = try await perform(pageRequest)
        try classifyWebResponse(pageHTTP)
        guard let subject = pageHTTP.value(forHTTPHeaderField: "x-subject-id"),
              subject.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw SiliconFlowUsageError.parseFailure
        }

        var walletRequest = URLRequest(url: chinaWalletEndpoint)
        walletRequest.httpMethod = "GET"
        walletRequest.timeoutInterval = 15
        walletRequest.httpShouldHandleCookies = false
        walletRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        walletRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        walletRequest.setValue(chinaBillingPage.absoluteString, forHTTPHeaderField: "Referer")
        walletRequest.setValue(subject, forHTTPHeaderField: "x-subject-id")
        walletRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (walletData, walletHTTP) = try await perform(walletRequest)
        try classifyWebResponse(walletHTTP)
        return try parseChinaWallet(walletData, now: now)
    }

    static func parseChinaWallet(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"]), code == 20000,
              let body = root["data"] as? [String: Any],
              let financial = body["financialInfo"] as? [String: Any],
              let rawBalance = financial["balance"] as? String,
              let yuan = parsePicoYuan(rawBalance) else {
            throw SiliconFlowUsageError.parseFailure
        }
        let balanceText = format(yuan, currency: "CNY")
        return ProviderUsage(
            id: ProviderID(rawValue: "siliconflow"),
            state: .ready,
            windows: [],
            balance: balanceText,
            details: [
                UsageDetail(id: "siliconflow-balance", label: AppLocalization.text("余额", "Balance"), value: balanceText),
            ],
            updatedAt: now,
            message: nil
        )
    }

    // 控制台钱包接口金额是以 10^-12 元表示的整数字符串，按位切分避免大整数浮点精度损失。
    static func parsePicoYuan(_ raw: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"^(-?)(\d{1,30})$"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let signRange = Range(match.range(at: 1), in: raw),
              let digitsRange = Range(match.range(at: 2), in: raw) else {
            return nil
        }
        let sign = String(raw[signRange])
        var digits = String(raw[digitsRange])
        if digits.count < 13 {
            digits = String(repeating: "0", count: 13 - digits.count) + digits
        }
        let splitIndex = digits.index(digits.endIndex, offsetBy: -12)
        let decimal = "\(sign)\(digits[..<splitIndex]).\(digits[splitIndex...])"
        guard let amount = Double(decimal), amount.isFinite else { return nil }
        return amount
    }

    private static func classifyWebResponse(_ response: HTTPURLResponse) throws {
        let status = response.statusCode
        if status == 200 { return }
        if status == 401 { throw SiliconFlowUsageError.webSessionExpired }
        if (300..<400).contains(status) {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            if location.range(of: #"^https://account\.siliconflow\.cn/login(?:[/?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw SiliconFlowUsageError.webSessionExpired
            }
        }
        if status == 403 { throw SiliconFlowUsageError.webPermissionDenied }
        if status == 429 { throw SiliconFlowUsageError.rateLimited }
        if status == 408 || status >= 500 { throw SiliconFlowUsageError.providerUnavailable(status) }
        throw SiliconFlowUsageError.apiFailure(status)
    }

    private static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n"),
              value.split(separator: ";").allSatisfy({ $0.contains("=") }) else {
            return nil
        }
        return value
    }

    private static func automaticCookies(in browser: Browser, client: BrowserCookieClient) -> [String] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: client) else {
            return []
        }
        var headers: [String] = []
        for source in sources where !source.records.isEmpty {
            let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
            let header = HTTPCookie.requestHeaderFields(with: httpCookies)["Cookie"] ?? ""
            if let normalized = normalizedCookie(header), !headers.contains(normalized) {
                headers.append(normalized)
            }
        }
        return headers
    }

    // 设置里的地址优先，其次是环境变量，都没有时默认中国区。
    static func resolvedOrigin(configured: String?, environment: [String: String]) -> URL? {
        guard let raw = cleaned(configured) ?? cleaned(environment[baseURLEnvironmentKey]) else {
            return chinaOrigin
        }
        return normalizedOrigin(raw)
    }

    // 只认两个官方地址，允许末尾带 /v1；端口、路径、查询参数和账号信息一律拒绝。
    static func normalizedOrigin(_ raw: String) -> URL? {
        let value = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "v1" else { return nil }
        switch host {
        case "api.siliconflow.cn": return chinaOrigin
        case "api.siliconflow.com": return internationalOrigin
        default: return nil
        }
    }

    static func parse(_ data: Data, currency: String, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"])
        else { throw SiliconFlowUsageError.parseFailure }
        if code == 20092 {
            throw currency == "CNY"
                ? SiliconFlowUsageError.chinaBalanceAPIRetired
                : SiliconFlowUsageError.balanceQueryRefused
        }
        if code == 30014 { throw SiliconFlowUsageError.authenticationExpired }
        guard code == 20000,
              root["status"] as? Bool == true,
              let body = root["data"] as? [String: Any],
              let total = money(body["totalBalance"])
        else { throw SiliconFlowUsageError.parseFailure }

        let totalText = format(total, currency: currency)
        var details = [
            UsageDetail(id: "siliconflow-balance", label: AppLocalization.text("余额", "Balance"), value: totalText),
        ]
        if let raw = present(body["chargeBalance"]) {
            guard let charged = money(raw) else { throw SiliconFlowUsageError.parseFailure }
            details.append(UsageDetail(
                id: "siliconflow-purchased",
                label: AppLocalization.text("充值余额", "Purchased"),
                value: format(charged, currency: currency)
            ))
        }
        if let raw = present(body["balance"]) {
            guard let bonus = money(raw) else { throw SiliconFlowUsageError.parseFailure }
            details.append(UsageDetail(
                id: "siliconflow-bonus",
                label: AppLocalization.text("赠送余额", "Bonus"),
                value: format(bonus, currency: currency)
            ))
        }
        // 账号状态不是 normal 时才显示，比如欠费。
        if let raw = present(body["status"]) {
            guard let status = raw as? String,
                  status.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil
            else { throw SiliconFlowUsageError.parseFailure }
            if status != "normal" {
                details.append(UsageDetail(
                    id: "siliconflow-status",
                    label: AppLocalization.text("账号状态", "Status"),
                    value: status
                ))
            }
        }
        // 接口没有额度上限，只显示余额，负数表示欠费，保留原值。
        return ProviderUsage(
            id: ProviderID(rawValue: "siliconflow"),
            state: .ready,
            windows: [],
            balance: totalText,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func present(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    // JSON 里的布尔值也会被当成数字，这里只接受真正的整数。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), let int = Int(exactly: double) else { return nil }
        return int
    }

    // 金额可能是数字，也可能是 "88.88" 这样的字符串；科学计数法等其他写法视为异常。
    private static func money(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard let text = value as? String,
              text.range(of: #"^-?(?:\d+|\d+\.\d+)$"#, options: .regularExpression) != nil,
              let amount = Double(text), amount.isFinite
        else { return nil }
        return amount
    }

    private static func format(_ value: Double, currency: String) -> String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private nonisolated final class SiliconFlowRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
