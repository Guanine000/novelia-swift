// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 账号状态、API 请求和续期共用的凭据入口；实例由 App 认证组装提供。
/// 生产实现使用原 Keychain 存储，开发验证使用隔离内存，不能混用或静默回退。
protocol SessionTokenStore: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func clear()
}
