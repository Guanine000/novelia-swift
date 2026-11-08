// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// 升级时只删除已退役朗读服务的旧密钥，不读取凭据、不接入网络。
/// 仅由生产 App 组装调用；独立验证 App 不触碰真实 Keychain。
enum RetiredSpeechServiceCleanup {
    static func removeStoredKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cc.novelia.speech.apiKey",
            kSecAttrAccount as String: "openai",
        ] as CFDictionary)
    }
}
