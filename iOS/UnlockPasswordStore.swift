import Foundation
import LocalAuthentication
import Security

/// Each paired Mac's login password, kept in the Keychain on this device only and readable
/// only after Face ID / Touch ID, so the Mac's lock screen can be unlocked from here.
///
/// The item uses `.biometryCurrentSet`: enrolling a new face or finger removes it, and it
/// needs a device passcode. It never syncs or goes into backups.
enum UnlockPasswordStore {
    private static let service = "localdesktop.unlockpassword"

    enum ReadError: Error {
        /// The user cancelled Face ID, or it failed.
        case cancelled
        /// No password saved, or it was removed when the biometric set changed.
        case missing
    }

    /// Face ID, Touch ID or Optic ID, or nil when this device has none set up.
    static var biometryType: LABiometryType? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.biometryType == .none ? nil : context.biometryType
    }

    static var biometryName: String {
        switch biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    static var biometrySymbol: String {
        switch biometryType {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    /// Whether a password is saved for this Mac, checked without showing Face ID.
    static func hasPassword(serverId: String) -> Bool {
        guard !serverId.isEmpty else { return false }
        let context = LAContext()
        context.interactionNotAllowed = true
        var q = baseQuery(serverId: serverId)
        q[kSecUseAuthenticationContext as String] = context
        q[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        // A protected item answers "interaction not allowed" when it exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    @discardableResult
    static func save(_ password: String, serverId: String) -> Bool {
        guard !serverId.isEmpty, !password.isEmpty,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return false }
        delete(serverId: serverId)
        var add = baseQuery(serverId: serverId)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessControl as String] = access
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(serverId: String) {
        SecItemDelete(baseQuery(serverId: serverId) as CFDictionary)
    }

    /// Shows Face ID / Touch ID, then returns the saved password.
    static func read(serverId: String, macName: String) async -> Result<String, ReadError> {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      localizedReason: "Unlock \(macName)")
            guard ok else { return .failure(.cancelled) }
        } catch {
            return .failure(.cancelled)
        }
        // The context is already authenticated, so the Keychain read shows no second prompt.
        return await Task.detached(priority: .userInitiated) { () -> Result<String, ReadError> in
            var q = baseQuery(serverId: serverId)
            q[kSecUseAuthenticationContext as String] = context
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let password = String(data: data, encoding: .utf8),
                  !password.isEmpty else { return .failure(.missing) }
            return .success(password)
        }.value
    }

    private static func baseQuery(serverId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: serverId]
    }
}
