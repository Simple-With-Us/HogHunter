import Foundation
import Security

/// The phone's pairing token, in the Keychain instead of UserDefaults.
///
/// A UserDefaults plist survives in backups and is readable to anything the
/// backup is restored to.  The token is a credential: it quits apps, tames
/// processes and runs the disk cleaner on the Mac.  It lives here under the
/// Mac's peer ID, with `AfterFirstUnlockThisDeviceOnly` so background
/// refresh can read it after the first unlock but it never leaves the
/// device in a backup.  A restored phone therefore re-pairs, by design.
///
/// The `service` parameter exists for tests, so the suite never touches the
/// real entry.  Production always uses the default.
enum CompanionKeychain {
    static let service = "com.simplewithus.hoghunter.companion.token"

    static func readToken(peerID: String, service: String = CompanionKeychain.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func writeToken(_ token: String, peerID: String, service: String = CompanionKeychain.service) -> Bool {
        guard let data = token.data(using: .utf8), !token.isEmpty else {
            deleteToken(peerID: peerID, service: service)
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func deleteToken(peerID: String, service: String = CompanionKeychain.service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
