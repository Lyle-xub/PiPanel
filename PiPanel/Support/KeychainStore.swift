import Foundation
import Security

/// Minimal generic-password Keychain wrapper for license state and the stable trial installation
/// id. Keychain normally survives app deletion, which makes the server's one-trial-per-id record
/// more resistant to casual reinstall resets than UserDefaults.
enum KeychainStore {
    #if DEBUG
    /// Debug builds are normally signed with an Apple Development identity while distributed
    /// builds use Developer ID (or PiPanel's stable local release identity). Sharing one service
    /// between those identities makes macOS ask the release app to access items created by Xcode
    /// and vice versa. Keep development state isolated so running from Xcode cannot disturb the
    /// access control lists of a user's production membership data.
    private static let service = "com.pipanel.mac.membership.debug"
    #else
    private static let service = "com.pipanel.mac.membership"
    #endif

    static func set(_ value: String, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let valueData = Data(value.utf8)

        // Updating in place preserves the item's Keychain access-control list. The previous
        // delete-then-add implementation discarded any "Always Allow" decision whenever a value
        // changed, which could make authorization prompts return after a later launch.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: valueData] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }

        var attributes = query
        attributes[kSecValueData as String] = valueData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
