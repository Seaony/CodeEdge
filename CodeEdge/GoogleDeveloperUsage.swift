import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum GoogleDeveloperUsageError: LocalizedError, Equatable {
    case missingCookies
    case cookieImportDeferred
    case invalidCookie
    case sessionExpired
    case noCloudCredit
    case rateLimited
    case unavailable
    case requestFailed(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            AppLocalization.text(
                "未找到 Google Developer Program 浏览器会话，请登录 me.developers.google.com/benefits 或粘贴 Cookie 标头",
                "No Google Developer Program session cookies found. Sign in at me.developers.google.com/benefits or paste a Cookie header."
            )
        case .cookieImportDeferred:
            AppLocalization.text(
                "请手动刷新一次以读取 Google Developer Program Cookie",
                "Refresh manually to import Google Developer Program cookies."
            )
        case .invalidCookie:
            AppLocalization.text(
                "Google Developer Program 需要来自 me.developers.google.com 的有效 Cookie 标头",
                "Google Developer Program requires a valid Cookie header from me.developers.google.com."
            )
        case .sessionExpired:
            AppLocalization.text(
                "Google 会话已过期或无效，请在浏览器登录 me.developers.google.com/benefits 后刷新",
                "Google session expired or invalid. Sign in at me.developers.google.com/benefits, then refresh."
            )
        case .noCloudCredit:
            AppLocalization.text(
                "未找到月度 Cloud 额度，请检查 Google Developer Program 权益页面",
                "No Cloud credit found. Check your Google Developer Program benefits."
            )
        case .rateLimited:
            AppLocalization.text(
                "Google Developer Program 请求过于频繁，请稍后重试",
                "Google Developer Program is rate limiting requests. Try again later."
            )
        case .unavailable:
            AppLocalization.text(
                "Google Developer Program 暂不可用，请稍后刷新",
                "Google Developer Program request failed. Try refreshing later."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Google Developer Program 请求失败（HTTP \(status)）",
                "Google Developer Program request failed (HTTP \(status))."
            )
        case .parseFailed:
            AppLocalization.text(
                "无法识别 Google Developer Program 返回的数据",
                "Google Developer Program returned an unrecognized response."
            )
        }
    }
}

nonisolated enum GoogleDeveloperUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let domain = "me.developers.google.com"
    private static let origin = "https://me.developers.google.com"
    private static let cookieDomains = ["me.developers.google.com", "google.com"]
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession? = nil,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        allowBrowserImport: Bool = false,
        transport: Transport? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let ephemeral: URLSession?
        let perform: Transport
        if let transport {
            ephemeral = nil
            perform = transport
        } else {
            let configuration = (session?.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 60
            let requestSession = URLSession(
                configuration: configuration,
                delegate: GoogleDeveloperRedirectGuard(),
                delegateQueue: nil
            )
            ephemeral = requestSession
            perform = { request in
                let (data, response) = try await FetchDiagnostics.data(for: request, session: requestSession)
                guard let http = response as? HTTPURLResponse else { throw GoogleDeveloperUsageError.parseFailed }
                return (data, http)
            }
        }
        defer { ephemeral?.invalidateAndCancel() }

        let manual = normalizedCookie(credential)
        if source == .cookie || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let manual else {
                throw credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? GoogleDeveloperUsageError.missingCookies
                    : .invalidCookie
            }
            return try await fetchSessions([manual], perform: perform, now: now)
        }
        guard source == .automatic else { throw GoogleDeveloperUsageError.missingCookies }

        var rejected = false
        if let cached = normalizedCookie(cachedCookieHeader ?? "") {
            do {
                return try await fetchSessions([cached], perform: perform, now: now)
            } catch GoogleDeveloperUsageError.sessionExpired {
                rejected = true
                await cacheUpdate(nil)
            }
        }
        guard allowBrowserImport else {
            throw rejected ? GoogleDeveloperUsageError.sessionExpired : GoogleDeveloperUsageError.cookieImportDeferred
        }

        let client = BrowserCookieClient()
        var unappliedEmail: String?
        var anySignedIn = false
        for browser in Browser.defaultImportOrder {
            try Task.checkCancellation()
            let cookies = automaticCookies(in: browser, client: client)
            for cookie in cookies {
                try Task.checkCancellation()
                switch try await probeSession(cookie: cookie, perform: perform, now: now) {
                case let .usage(usage):
                    await cacheUpdate(cookie)
                    return usage
                case let .unapplied(email):
                    await cacheUpdate(cookie)
                    unappliedEmail = unappliedEmail ?? email
                    anySignedIn = true
                case .signedInNoCredit:
                    await cacheUpdate(cookie)
                    anySignedIn = true
                case .denied:
                    rejected = true
                }
                if anySignedIn { break }
            }
            if anySignedIn { break }
        }

        if let unappliedEmail {
            return makeUnappliedUsage(email: unappliedEmail, now: now)
        }
        if anySignedIn { throw GoogleDeveloperUsageError.noCloudCredit }
        throw rejected ? GoogleDeveloperUsageError.sessionExpired : GoogleDeveloperUsageError.missingCookies
    }

    private enum SessionProbeResult {
        case usage(ProviderUsage)
        case unapplied(String)
        case signedInNoCredit
        case denied
    }

    static func fetchSessions(
        _ cookies: [String],
        perform: Transport,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var unappliedEmail: String?
        var signedIn = false
        var rejected = false
        for cookie in cookies {
            try Task.checkCancellation()
            switch try await probeSession(cookie: cookie, perform: perform, now: now) {
            case let .usage(usage):
                return usage
            case let .unapplied(email):
                unappliedEmail = unappliedEmail ?? email
                signedIn = true
            case .signedInNoCredit:
                signedIn = true
            case .denied:
                rejected = true
            }
            if signedIn { break }
        }
        if let unappliedEmail {
            return makeUnappliedUsage(email: unappliedEmail, now: now)
        }
        if signedIn { throw GoogleDeveloperUsageError.noCloudCredit }
        throw rejected ? GoogleDeveloperUsageError.sessionExpired : GoogleDeveloperUsageError.missingCookies
    }

    private static func probeSession(
        cookie: String,
        perform: Transport,
        now: Date
    ) async throws -> SessionProbeResult {
        var emails: [String] = []
        var unapplied: String?
        var signedIn = false
        for account in 0..<8 {
            try Task.checkCancellation()
            var pageRequest = URLRequest(url: URL(string: "\(origin)/benefits?authuser=\(account)")!)
            pageRequest.httpMethod = "GET"
            pageRequest.timeoutInterval = 15
            pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
            pageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (pageData, pageResponse) = try await perform(pageRequest)
            if try isDenied(pageResponse) { break }
            let html = String(decoding: pageData, as: UTF8.self)
            guard let token = pageValue(in: html, key: "SNlM0e"),
                  let email = pageValue(in: html, key: "oPEP7c"),
                  !emails.contains(email) else {
                break
            }

            let rpcURL = URL(
                string: "\(origin)/_/GoogleDeveloperProfile/data/batchexecute"
                    + "?rpcids=Ro0AYc&source-path=%2Fbenefits&hl=en&authuser=\(account)&rt=c"
            )!
            var rpcRequest = URLRequest(url: rpcURL)
            rpcRequest.httpMethod = "POST"
            rpcRequest.timeoutInterval = 15
            rpcRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            rpcRequest.setValue(origin, forHTTPHeaderField: "Origin")
            rpcRequest.setValue("\(origin)/benefits", forHTTPHeaderField: "Referer")
            rpcRequest.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            rpcRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let formBody = "f.req=\(formEncode("[[[\"Ro0AYc\",\"[]\",null,\"generic\"]]]"))&at=\(formEncode(token))"
            rpcRequest.httpBody = Data(formBody.utf8)

            let (rpcData, rpcResponse) = try await perform(rpcRequest)
            if try isDenied(rpcResponse) { break }
            emails.append(email)
            signedIn = true

            let bodyText = String(decoding: rpcData, as: UTF8.self)
            switch try parseBatchExecute(bodyText, email: email, now: now) {
            case let .usage(usage):
                return .usage(usage)
            case .unapplied:
                if unapplied == nil { unapplied = email }
            case .noCredit:
                continue
            }
        }
        if let unapplied { return .unapplied(unapplied) }
        return signedIn ? .signedInNoCredit : .denied
    }

    enum BatchParseResult: Equatable {
        case usage(ProviderUsage)
        case unapplied
        case noCredit
    }

    static func parseBatchExecute(_ bodyText: String, email: String, now: Date = Date()) throws -> BatchParseResult {
        var matchedEntry: [Any]?
        for line in bodyText.components(separatedBy: .newlines) where line.hasPrefix("[") {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw GoogleDeveloperUsageError.parseFailed
            }
            for item in parsed {
                if let entry = item as? [Any], entry.count >= 2,
                   (entry[0] as? String) == "wrb.fr",
                   (entry[1] as? String) == "Ro0AYc" {
                    matchedEntry = entry
                    break
                }
            }
            if matchedEntry != nil { break }
        }
        guard let result = matchedEntry else { throw GoogleDeveloperUsageError.parseFailed }
        guard result.count > 2, let payloadString = result[2] as? String else {
            return .noCredit
        }
        guard let payloadData = payloadString.data(using: .utf8),
              let payloadArray = try? JSONSerialization.jsonObject(with: payloadData) as? [Any] else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        let rawList = payloadArray.first
        let benefits: [Any]
        if rawList == nil || rawList is NSNull {
            benefits = []
        } else if let list = rawList as? [Any] {
            benefits = list
        } else {
            throw GoogleDeveloperUsageError.parseFailed
        }

        // 权益类型 19 对应 Google AI Pro / Ultra 的月度 Gen AI & Cloud Credit。
        var matchedBenefit: [Any]?
        for rawBenefit in benefits {
            guard let benefit = rawBenefit as? [Any] else { throw GoogleDeveloperUsageError.parseFailed }
            if let typeNum = benefit.first as? NSNumber,
               CFGetTypeID(typeNum) != CFBooleanGetTypeID(),
               typeNum.intValue == 19 {
                matchedBenefit = benefit
                break
            }
        }
        guard let credit = matchedBenefit else { return .noCredit }
        let rawOffer = credit.count > 9 ? credit[9] : nil
        let offer: [Any]
        if rawOffer == nil || rawOffer is NSNull {
            offer = []
        } else if let array = rawOffer as? [Any] {
            offer = array
        } else {
            throw GoogleDeveloperUsageError.parseFailed
        }

        if offer.count <= 6 || offer[6] is NSNull {
            return .unapplied
        }
        guard let billing = offer[6] as? [Any], billing.count >= 2 else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        let granted = try parseMoney(billing[0])
        let remaining = try parseMoney(billing[1])
        guard granted.amount > 0, remaining.currency == granted.currency else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        let currency = granted.currency
        let left = max(0, remaining.amount)
        let expiresAt = offer.count > 1 ? parseUnixDate(offer[1]) : nil
        let grantedAt = offer.count > 16 ? parseUnixDate(offer[16]) : nil

        let leftText = formatCurrency(left, currency: currency)
        let grantedText = formatCurrency(granted.amount, currency: currency)
        let amounts = AppLocalization.text(
            "剩余 \(leftText) / \(grantedText)",
            "\(leftText) of \(grantedText) left"
        )
        let detailText: String
        if let expiresAt {
            let expiryText = dayString(expiresAt)
            detailText = amounts + AppLocalization.text(" · \(expiryText) 到期", " · Expires \(expiryText)")
        } else {
            detailText = amounts
        }

        var details: [UsageDetail] = []
        if billing.count > 2, let accountRef = billing[2] as? String {
            let billingAccount = accountRef.replacingOccurrences(of: "^billingAccounts/", with: "", options: .regularExpression)
            if !billingAccount.isEmpty {
                details.append(UsageDetail(
                    id: "googledeveloper-billing-account",
                    label: AppLocalization.text("结算账号", "Billing account"),
                    value: billingAccount
                ))
            }
        }
        if let grantedAt {
            details.append(UsageDetail(
                id: "googledeveloper-granted",
                label: AppLocalization.text("发放日期", "Granted"),
                value: dayString(grantedAt)
            ))
        }
        details.append(UsageDetail(
            id: "googledeveloper-account",
            label: AppLocalization.text("账号", "Account"),
            value: email
        ))

        let usedFraction = min(1, max(0, (granted.amount - left) / granted.amount))
        return .usage(ProviderUsage(
            id: ProviderID(rawValue: "googledeveloper"),
            state: .ready,
            windows: [UsageWindow(
                id: "googledeveloper-cloud-credits",
                label: AppLocalization.text("云额度", "Cloud credits"),
                usedFraction: usedFraction,
                resetsAt: nil,
                detail: detailText
            )],
            balance: leftText,
            plan: AppLocalization.text("浏览器会话", "Browser session"),
            providerCost: ProviderCostSummary(
                used: left,
                limit: granted.amount,
                currencyCode: currency,
                period: AppLocalization.text("月度额度", "Monthly credits"),
                balance: left
            ),
            details: details,
            updatedAt: now,
            message: nil
        ))
    }

    static func pageValue(in html: String, key: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\":(\"(?:[^\"\\\\]|\\\\.)*\")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = String(html[range]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    private static func makeUnappliedUsage(email: String, now: Date) -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "googledeveloper"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: AppLocalization.text("浏览器会话", "Browser session"),
            details: [
                UsageDetail(
                    id: "googledeveloper-status",
                    label: AppLocalization.text("状态", "Status"),
                    value: AppLocalization.text("未应用（me.developers.google.com/benefits）", "Not applied (me.developers.google.com/benefits)")
                ),
                UsageDetail(
                    id: "googledeveloper-account",
                    label: AppLocalization.text("账号", "Account"),
                    value: email
                ),
            ],
            updatedAt: now,
            message: nil
        )
    }

    private static func isDenied(_ response: HTTPURLResponse) throws -> Bool {
        let status = response.statusCode
        if (300..<400).contains(status) || status == 401 || status == 403 { return true }
        if status == 429 { throw GoogleDeveloperUsageError.rateLimited }
        if status >= 500 { throw GoogleDeveloperUsageError.unavailable }
        if status != 200 { throw GoogleDeveloperUsageError.requestFailed(status) }
        return false
    }

    private static func parseMoney(_ value: Any) throws -> (currency: String, amount: Double) {
        guard let array = value as? [Any], !array.isEmpty,
              let currency = array[0] as? String,
              currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        let units = try optionalInteger(array.count > 1 ? array[1] : nil)
        let nanos = try optionalInteger(array.count > 2 ? array[2] : nil)
        return (currency, Double(units) + Double(nanos) / 1e9)
    }

    private static func optionalInteger(_ value: Any?) throws -> Int64 {
        guard let value, !(value is NSNull) else { return 0 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        let d = number.doubleValue
        guard d.isFinite, d.rounded() == d, abs(d) <= 9_007_199_254_740_991 else {
            throw GoogleDeveloperUsageError.parseFailed
        }
        return Int64(d)
    }

    private static func parseUnixDate(_ value: Any) -> Date? {
        guard let array = value as? [Any],
              let number = array.first as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds.rounded() == seconds else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatCurrency(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = AppLocalization.currentLanguage.locale
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(String(format: "%.2f", amount))"
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }

    private static func automaticCookies(in browser: Browser, client: BrowserCookieClient) -> [String] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: client) else {
            return []
        }
        let requestURL = URL(string: "\(origin)/benefits")!
        var headers: [String] = []
        for source in sources where !source.records.isEmpty {
            let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                .filter { cookie in
                    let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard let host = requestURL.host?.lowercased(),
                          host == cookieDomain || host.hasSuffix(".\(cookieDomain)") else { return false }
                    let path = cookie.path.isEmpty ? "/" : cookie.path
                    return requestURL.path.hasPrefix(path)
                }
            let header = HTTPCookie.requestHeaderFields(with: httpCookies)["Cookie"] ?? ""
            if let normalized = normalizedCookie(header), !headers.contains(normalized) {
                headers.append(normalized)
            }
        }
        return headers
    }
}

private final class GoogleDeveloperRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
