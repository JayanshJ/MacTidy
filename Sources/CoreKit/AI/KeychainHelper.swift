import Foundation

/// Stores the user's AI API key in the macOS Keychain — never in UserDefaults
/// or a plaintext plist. The key is scoped to the app's bundle id so it's
/// isolated from other apps' credentials.
public enum KeychainHelper {
    public static let serviceName = "com.jayansh.mactidy.ai"

    public enum KeychainError: Error {
        case storeFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
    }

    /// Saves (or replaces) the API key for a provider.
    @discardableResult
    public static func save(_ key: String, for provider: AIProvider) throws -> Bool {
        let account = provider.rawValue
        let data = Data(key.utf8)
        // Delete any existing item first so `add` doesn't fail with
        // errSecDuplicateItem when replacing.
        try? delete(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.storeFailed(status) }
        return true
    }

    /// Loads the API key for a provider, or nil if none is stored.
    public static func load(for provider: AIProvider) -> String? {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    /// Deletes the stored key for a provider (no-op if none).
    @discardableResult
    public static func delete(for provider: AIProvider) throws -> Bool {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
        return true
    }
}