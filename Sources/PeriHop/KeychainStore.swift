import Foundation
import Security

struct KeychainError: Error, LocalizedError, Equatable {
    var message: String
    var status: OSStatus

    var errorDescription: String? { "\(message) (\(status))." }
}

enum KeychainStore {
    private static let service = "com.posadskiy.perihop.peer-code"

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    static func readCode() -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored code in place, so a failed write keeps the old one.
    /// An empty code removes it.
    static func saveCode(_ code: String) throws {
        guard !code.isEmpty else {
            let status = SecItemDelete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(message: "Couldn't remove the pairing code", status: status)
            }
            return
        }
        let data = Data(code.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(itemQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(message: "Couldn't save the pairing code", status: status)
        }
        var add = itemQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainError(message: "Couldn't save the pairing code", status: added)
        }
    }
}
