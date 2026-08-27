import Foundation
import Security

/// Keychain-backed identity and per-Mac trust tokens.
enum TrustStore {
    private static let service = "localdesktop.tokens"
    private static let deviceKey = "rd.deviceId"

    /// Stable device identifier sent during the handshake.
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    static func token(serverId: String) -> Data? {
        var query = baseQuery(serverId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    static func setToken(_ token: Data, serverId: String) {
        removeToken(serverId: serverId)
        var add = baseQuery(serverId)
        add[kSecValueData as String] = token
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removeToken(serverId: String) {
        SecItemDelete(baseQuery(serverId) as CFDictionary)
    }

    private static func baseQuery(_ serverId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: serverId]
    }
}
