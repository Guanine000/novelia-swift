// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Auth state and API requests use the same credential store. Implementations
/// may be Keychain-backed or isolated in memory for development validation.
protocol SessionTokenStore: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func clear()
}
