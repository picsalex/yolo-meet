import Foundation
import Security

/// The app's secrets, in the keychain: they stay on this iPad, and can be read once it has been unlocked.
enum Keychain {
    private static func item(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Bundle.main.bundleIdentifier ?? "yolo-meet pen", kSecAttrAccount: name]
    }

    static func read(_ name: String) -> String? {
        var found: CFTypeRef?
        let query = item(name).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, as name: String) {
        SecItemDelete(item(name) as CFDictionary)
        let added = item(name).merging([
            kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        SecItemAdd(added as CFDictionary, nil)
    }
}
