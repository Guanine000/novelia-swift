// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// 专用服务名与接口作用域隔离，绝不复用 Novelia 登录或朗读的旧密钥身份。
@MainActor
final class ReadingAIKeychain: ReadingAIKeyStoring {
    private let service = "cc.novelia.ios.reading-ai.v1"
    private func query(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: FileContentHash.sha256(Data(scope.utf8)), kSecAttrSynchronizable as String: false]
    }
    func read(scope: String) throws -> String? {
        var query = self.query(scope)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ReadingAIError.credentialStorage
        }
        return key
    }
    func write(_ key: String?, scope: String) throws {
        let query = self.query(scope)
        guard let key else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ReadingAIError.credentialStorage }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = query
            added[kSecValueData as String] = data
            added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw ReadingAIError.credentialStorage }
        } else if status != errSecSuccess { throw ReadingAIError.credentialStorage }
    }
}
