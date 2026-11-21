import Foundation
import Security

/// 云端服务的密钥存在系统钥匙串里，不放 UserDefaults（那是明文的 plist）。
enum Keychain {
    private static let service = "com.ffan008.badgepod"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty { return SecItemDelete(base as CFDictionary) == errSecSuccess }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// 以前存在 UserDefaults 里的密钥搬进钥匙串，搬成功才删掉旧的。
    static func migrate(_ key: String) -> String {
        let d = UserDefaults.standard
        if let old = d.string(forKey: key), !old.isEmpty {
            if set(old, for: key) { d.removeObject(forKey: key) }
            return old
        }
        return get(key)
    }
}
