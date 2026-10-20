import Foundation
import Security

/// Keychain storage for the OWUI token, one item per server origin.
/// Readable after first unlock so a call started from the Action button on a locked phone can use it.
enum TokenStore {
    private static let service = "owui.token"

    static func load(for server: URL) -> String? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for server: URL) {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(for: server) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = baseQuery(for: server).merging(attributes) { $1 }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(for server: URL) {
        SecItemDelete(baseQuery(for: server) as CFDictionary)
    }

    private static func baseQuery(for server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin(of: server),
        ]
    }

    private static func origin(of url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "https")://\(url.host ?? "")\(port)"
    }
}
