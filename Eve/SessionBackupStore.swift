import Foundation
import Security

/// Keychain item holding the backup of the session cookie (see `SessionBackup` for the record and the rules).
///
/// - Own item (service `eve.shell.session-backup`), separate from the pending-revoke item.
/// - `ThisDeviceOnly`: never synced to iCloud Keychain; it can be in an encrypted backup of THIS device but is never
///   restored onto another device;
///   `kSecAttrSynchronizable` is explicitly false.
/// - Accessible only while the device is unlocked, like the pending-revoke item (the shell never needs it in the
///   background). Change `accessible` in this one place to loosen it.
/// - Only this app can read it: the default access group is "<team prefix>.<bundle id>".
/// - It survives deleting the app (that is the point) but only for the same team + bundle ID.
/// Uses SecItemUpdate then SecItemAdd, never delete-then-add. The value never goes to logs, UserDefaults or the bridge.
enum SessionBackupStore {
    private static let service = "eve.shell.session-backup"
    private static let account = "session"
    private static let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func load() -> SessionBackup.Stored {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess else { return .unavailable }
        guard let data = out as? Data, let record = SessionBackup.decode(data) else { return .corrupt }
        return .record(record)
    }

    /// Returns false if the Keychain refused the write.
    @discardableResult
    static func save(_ record: SessionBackup.Record) -> Bool {
        guard let data = SessionBackup.encode(record) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// True if the item is gone afterwards (including "was never there").
    @discardableResult
    static func delete() -> Bool {
        let s = SecItemDelete(query as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
