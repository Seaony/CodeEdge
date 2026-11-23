import CoreFoundation
import Darwin
import Foundation
import LocalAuthentication
import Security
import SweetCookieKit

nonisolated enum BrowserCookieAccess {
    nonisolated enum KeychainPreflightOutcome: Equatable, Sendable {
        case allowed
        case interactionRequired
        case temporarilyUnavailable
        case notFound
        case failure(OSStatus)
    }

    nonisolated enum KeychainPartitionMatch: Equatable, Sendable {
        case allowed
        case rejected
        case indeterminate
    }

    nonisolated final class Scope: @unchecked Sendable {
        private nonisolated final class Allowance: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false

            func claim() -> Bool {
                lock.withLock {
                    guard !claimed else { return false }
                    claimed = true
                    return true
                }
            }
        }

        let allowInteraction: Bool
        private let allowance: Allowance
        private let lock = NSLock()
        private var failure: (priority: Int, message: String)?

        init(allowInteraction: Bool, sharingAllowanceFrom parent: Scope? = nil) {
            self.allowInteraction = allowInteraction && (parent?.allowInteraction ?? true)
            allowance = parent?.allowance ?? Allowance()
        }

        var failureMessage: String? {
            lock.withLock { failure?.message }
        }

        fileprivate func claimInteraction() -> Bool {
            allowInteraction && allowance.claim()
        }

        fileprivate func record(_ message: String, priority: Int) {
            lock.withLock {
                guard priority >= (failure?.priority ?? -1) else { return }
                failure = (priority, message)
            }
        }
    }

    @TaskLocal static var scope: Scope?
    private static let denialLock = NSLock()
    private static let denialKey = "browser-cookie-keychain-denied-until"

    static func records(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        client: BrowserCookieClient = BrowserCookieClient()
    ) throws -> [BrowserCookieStoreRecords] {
        try Task.checkCancellation()
        FetchDiagnostics.current?.note("Cookie")
        do {
            return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                try client.records(matching: query, in: browser)
            }
        } catch {
            try Task.checkCancellation()
            guard let cookieError = error as? BrowserCookieError,
                  case .accessDenied = cookieError,
                  browser.usesChromiumProfileStore,
                  !BrowserCookieKeychainAccessGate.isUserInteractionDisallowed,
                  !isCoolingDown,
                  scope?.claimInteraction() == true else {
                recordFailure(error, browser: browser, client: client)
                throw error
            }
            do {
                return try client.records(matching: query, in: browser)
            } catch {
                if let cookieError = error as? BrowserCookieError, case .accessDenied = cookieError {
                    denialLock.withLock {
                        UserDefaults.standard.set(Date().addingTimeInterval(6 * 60 * 60), forKey: denialKey)
                    }
                }
                recordFailure(error, browser: browser, client: client)
                throw error
            }
        }
    }

    // 便于单元测试在不直接依赖 SweetCookieKit 的测试 Target 中校验取消行为。
    static func verifyRecordsCancellation(domains: [String] = ["example.com"]) throws {
        _ = try records(matching: BrowserCookieQuery(domains: domains), in: .safari)
    }

    // 读取其他应用的钥匙串条目：后台只在预检允许或之前授权成功过时静默读取，
    // 需要授权时只在手动刷新时弹一次，拒绝后 6 小时内不再弹。
    /// grantKey 只区分授权记录；拒绝后的冷却按服务名共用，同一服务下换账户也不会再弹框。
    static func readForeignKeychainItem(
        service: String,
        account: String? = nil,
        grantKey: String? = nil,
        requirePartition: Bool = false,
        preflight: (() -> KeychainPreflightOutcome)? = nil,
        read: (_ allowPrompt: Bool) -> (OSStatus, Data?),
        exists: (() -> Bool)? = nil
    ) -> (OSStatus, Data?) {
        let manual = scope?.allowInteraction == true
        let grantService = grantKey ?? service

        if requirePartition || preflight != nil {
            let outcome = preflight?() ?? keychainPreflight(
                service: service,
                account: account,
                requirePartition: requirePartition
            )
            switch outcome {
            case .notFound:
                return (errSecItemNotFound, nil)
            case .temporarilyUnavailable:
                return (errSecInteractionNotAllowed, nil)
            case let .failure(status):
                return (status, nil)
            case .interactionRequired:
                setCredentialGrant(false, service: grantService)
                guard manual, claimCredentialPrompt(service: service) else {
                    return (errSecInteractionNotAllowed, nil)
                }
                let (status, data) = read(true)
                if [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem, errSecInteractionNotAllowed].contains(status) {
                    recordCredentialDenial(service: service)
                }
                if status == errSecSuccess { setCredentialGrant(true, service: grantService) }
                DiagnosticLog.shared.write("Foreign keychain read status=\(status)", category: .credentials)
                return (status, data)
            case .allowed:
                var (status, data) = read(false)
                if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                    setCredentialGrant(false, service: grantService)
                    guard manual, claimCredentialPrompt(service: service) else { return (status, nil) }
                    (status, data) = read(true)
                    if [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem, errSecInteractionNotAllowed].contains(status) {
                        recordCredentialDenial(service: service)
                    }
                }
                if status == errSecSuccess { setCredentialGrant(true, service: grantService) }
                DiagnosticLog.shared.write("Foreign keychain read status=\(status)", category: .credentials)
                return (status, data)
            }
        }

        let granted = denialLock.withLock { UserDefaults.standard.bool(forKey: credentialGrantKey(grantService)) }
        // 旧式 ACL 的条目即使设置了不弹窗也可能弹，后台没授权记录时不碰密码，只查条目是否存在。
        if !manual, !granted {
            let itemExists = exists?() ?? foreignKeychainItemExists(service: service, account: account)
            return (itemExists ? errSecInteractionNotAllowed : errSecItemNotFound, nil)
        }
        var (status, data) = read(false)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            setCredentialGrant(false, service: grantService)
            guard claimCredentialPrompt(service: service) else { return (status, nil) }
            (status, data) = read(true)
            if [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem].contains(status) {
                recordCredentialDenial(service: service)
            }
        }
        if status == errSecSuccess { setCredentialGrant(true, service: grantService) }
        DiagnosticLog.shared.write("Foreign keychain read status=\(status)", category: .credentials)
        return (status, data)
    }

    // 预检钥匙串条目的解密 ACL 与签名团队分区列表，不读取密码本身，不触发系统弹窗。
    static func keychainPreflight(
        service: String,
        account: String? = nil,
        requirePartition: Bool = false
    ) -> KeychainPreflightOutcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        applyNoUI(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let rawItem = result else { return .temporarilyUnavailable }
            return evaluateKeychainItemACL(rawItem, requirePartition: requirePartition)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .temporarilyUnavailable
        default:
            return .failure(status)
        }
    }

    static func evaluatePartitionList(descriptions: [String], callerTeam: String?) -> KeychainPartitionMatch {
        guard !descriptions.isEmpty else { return .allowed }
        var partitions: [String] = []
        for description in descriptions {
            guard let ids = partitionIDs(fromACLDescription: description) else { return .indeterminate }
            partitions.append(contentsOf: ids)
        }
        guard let callerTeam, !callerTeam.isEmpty else { return .indeterminate }
        return partitions.contains("teamid:\(callerTeam)") ? .allowed : .rejected
    }

    static func partitionIDs(fromACLDescription description: String) -> [String]? {
        let hex = Array(description.utf8)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let pair = String(bytes: hex[index..<(index + 2)], encoding: .ascii),
                  let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["Partitions"] as? [String]
    }

    static func currentCallerTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private typealias SecKeychainItemGetTypeIDFn = @convention(c) () -> CFTypeID
    private typealias SecKeychainItemCopyAccessFn = @convention(c) (
        CFTypeRef, UnsafeMutablePointer<Unmanaged<SecAccess>?>
    ) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFn = @convention(c) (
        SecAccess, CFTypeRef
    ) -> Unmanaged<CFArray>?
    private typealias SecAccessCopyACLListFn = @convention(c) (
        SecAccess, UnsafeMutablePointer<Unmanaged<CFArray>?>
    ) -> OSStatus
    private typealias SecACLCopyAuthorizationsFn = @convention(c) (SecACL) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFn = @convention(c) (
        SecACL,
        UnsafeMutablePointer<Unmanaged<CFArray>?>,
        UnsafeMutablePointer<Unmanaged<CFString>?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>
    ) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFn = @convention(c) (
        SecTrustedApplication, UnsafePointer<CChar>
    ) -> OSStatus

    private static let securityHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW
    )

    private static func securitySymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = securityHandle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func evaluateKeychainItemACL(
        _ rawItem: AnyObject,
        requirePartition: Bool
    ) -> KeychainPreflightOutcome {
        guard let getTypeID = securitySymbol("SecKeychainItemGetTypeID", as: SecKeychainItemGetTypeIDFn.self),
              CFGetTypeID(rawItem) == getTypeID(),
              let copyAccess = securitySymbol("SecKeychainItemCopyAccess", as: SecKeychainItemCopyAccessFn.self),
              let copyMatchingACLs = securitySymbol("SecAccessCopyMatchingACLList", as: SecAccessCopyMatchingACLListFn.self),
              let copyContents = securitySymbol("SecACLCopyContents", as: SecACLCopyContentsFn.self),
              let validatePath = securitySymbol("SecTrustedApplicationValidateWithPath", as: SecTrustedApplicationValidateWithPathFn.self),
              let executablePath = Bundle.main.executablePath else {
            return .temporarilyUnavailable
        }
        var rawAccess: Unmanaged<SecAccess>?
        guard copyAccess(rawItem, &rawAccess) == errSecSuccess,
              let access = rawAccess?.takeRetainedValue(),
              let acls = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue() as? [SecACL],
              !acls.isEmpty else {
            return .temporarilyUnavailable
        }

        var inspectionIncomplete = false
        for acl in acls {
            var rawApps: Unmanaged<CFArray>?
            var rawDescription: Unmanaged<CFString>?
            var selector = SecKeychainPromptSelector()
            guard copyContents(acl, &rawApps, &rawDescription, &selector) == errSecSuccess else {
                inspectionIncomplete = true
                continue
            }
            let apps = rawApps?.takeRetainedValue()
            _ = rawDescription?.takeRetainedValue()
            guard selector.rawValue == 0 else { continue }
            let decryptAllowed: Bool
            if apps == nil {
                decryptAllowed = true
            } else if let trustedApps = apps as? [SecTrustedApplication] {
                decryptAllowed = executablePath.withCString { cPath in
                    trustedApps.contains { validatePath($0, cPath) == errSecSuccess }
                }
            } else {
                inspectionIncomplete = true
                continue
            }
            if decryptAllowed {
                guard requirePartition else { return .allowed }
                switch evaluatePartitionACL(access: access, copyContents: copyContents) {
                case .allowed: return .allowed
                case .rejected: return .interactionRequired
                case .indeterminate: return .temporarilyUnavailable
                }
            }
        }
        return inspectionIncomplete ? .temporarilyUnavailable : .interactionRequired
    }

    private static func evaluatePartitionACL(
        access: SecAccess,
        copyContents: SecACLCopyContentsFn
    ) -> KeychainPartitionMatch {
        guard let copyACLs = securitySymbol("SecAccessCopyACLList", as: SecAccessCopyACLListFn.self),
              let copyAuths = securitySymbol("SecACLCopyAuthorizations", as: SecACLCopyAuthorizationsFn.self) else {
            return .indeterminate
        }
        var rawACLs: Unmanaged<CFArray>?
        guard copyACLs(access, &rawACLs) == errSecSuccess,
              let acls = rawACLs?.takeRetainedValue() as? [SecACL] else {
            return .indeterminate
        }
        var descriptions: [String] = []
        for acl in acls {
            guard let auths = copyAuths(acl)?.takeRetainedValue() as? [String] else { return .indeterminate }
            guard auths.contains(kSecACLAuthorizationPartitionID as String) else { continue }
            var rawApps: Unmanaged<CFArray>?
            var rawDescription: Unmanaged<CFString>?
            var selector = SecKeychainPromptSelector()
            guard copyContents(acl, &rawApps, &rawDescription, &selector) == errSecSuccess else {
                return .indeterminate
            }
            _ = rawApps?.takeRetainedValue()
            guard let description = rawDescription?.takeRetainedValue() as String? else { return .indeterminate }
            descriptions.append(description)
        }
        return evaluatePartitionList(descriptions: descriptions, callerTeam: currentCallerTeamIdentifier())
    }

    private static func recordCredentialDenial(service: String) {
        denialLock.withLock {
            UserDefaults.standard.set(Date().addingTimeInterval(6 * 60 * 60), forKey: credentialDenialKey(service))
        }
    }

    // 不弹窗的钥匙串查询：同时设置 LAContext 和旧式钥匙串的 UI-fail 标志。
    // 只设 interactionNotAllowed 时 macOS 仍可能弹“允许/拒绝”，所以旧标志必须保留。
    static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = authenticationUIFailPolicy as CFString
    }

    // 与 CodexBar 一致，运行时读取 kSecUseAuthenticationUIFail 的值，避免编译时引用已弃用的常量。
    static let authenticationUIFailPolicy: String = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail"),
              let value = symbol.assumingMemoryBound(to: CFString?.self).pointee else { return "u_AuthUIF" }
        return value as String
    }()

    // 只查条目是否存在，不读取密码，不会触发授权弹窗。
    static func foreignKeychainItemExists(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        applyNoUI(to: &query)
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    private static func claimCredentialPrompt(service: String) -> Bool {
        guard !Task.isCancelled else { return false }
        let coolingDown = denialLock.withLock {
            (UserDefaults.standard.object(forKey: credentialDenialKey(service)) as? Date).map { $0 > Date() } ?? false
        }
        return !coolingDown && scope?.claimInteraction() == true
    }

    private static func setCredentialGrant(_ granted: Bool, service: String) {
        denialLock.withLock { UserDefaults.standard.set(granted, forKey: credentialGrantKey(service)) }
    }

    private static func credentialDenialKey(_ service: String) -> String {
        "credential-keychain-denied-until.\(service)"
    }

    private static func credentialGrantKey(_ service: String) -> String {
        "credential-keychain-granted.\(service)"
    }

    private static var isCoolingDown: Bool {
        denialLock.withLock {
            (UserDefaults.standard.object(forKey: denialKey) as? Date).map { $0 > Date() } ?? false
        }
    }

    private static func recordFailure(_ error: Error, browser: Browser, client: BrowserCookieClient) {
        guard let error = error as? BrowserCookieError, scope != nil else { return }
        DiagnosticLog.shared.write("Browser cookie access failed", category: .credentials)
        switch error {
        case .accessDenied where browser.usesChromiumProfileStore:
            scope?.record(AppLocalization.text(
                "无法读取 \(browser.displayName) 的钥匙串 Cookie。请在钥匙串访问中检查权限或解锁钥匙串，再手动刷新。",
                "Cannot read \(browser.displayName)'s Keychain cookies. Check access or unlock Keychain in Keychain Access, then refresh manually."
            ), priority: 2)
        case .accessDenied:
            recordProfileFailure(browser)
        case .notFound, .loadFailed:
            if profileAccessDenied(browser, client: client) { recordProfileFailure(browser) }
        }
    }

    private static func recordProfileFailure(_ browser: Browser) {
        scope?.record(AppLocalization.text(
            "无法读取 \(browser.displayName) 的浏览器资料。请在系统设置 → 隐私与安全性 → 文件与文件夹中检查 CodeEdge 的访问权限。",
            "Cannot read \(browser.displayName)'s profile. Check CodeEdge's access in System Settings → Privacy & Security → Files & Folders."
        ), priority: 1)
    }

    private static func profileAccessDenied(_ browser: Browser, client: BrowserCookieClient) -> Bool {
        for store in client.stores(for: browser) {
            if let file = store.databaseURL,
               FileManager.default.fileExists(atPath: file.path),
               !FileManager.default.isReadableFile(atPath: file.path) {
                return true
            }
        }
        let relative = browser.chromiumProfileRelativePath ?? browser.geckoProfilesFolder.map { "\($0)/Profiles" }
        guard let relative else { return false }
        for home in client.configuration.homeDirectories {
            let root = home.appendingPathComponent("Library/Application Support").appendingPathComponent(relative)
            do {
                _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue
                    || error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code)) {
                    return true
                }
            }
        }
        return false
    }
}
